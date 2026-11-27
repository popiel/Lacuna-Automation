# missionary.pl

## Purpose

Farm Lost City of Tyleon (LCOT) plans from the Mission Command missions system,
and liquidate the surplus:

- Vend the mission lists of every Mission Command building every run.
- Record every mission instance ever seen under `missions/` as JSON.
- Classify each vended mission by the items in its **rewards** (live vended
  data only; the local `../lacuna_server` mission files are background, never
  authoritative - the live server may have additional missions).
- Complete LCOT missions and missions whose rewards are usable for LCOT
  missions: send ships to the exact named star/body targets, haul resources
  and plans between colonies, redistribute docked ships, report blockers.
- Skip only missions that are completely useless.
- Accumulate at least 9 copies of each LCOT plan letter (A-I); offer copies
  beyond 6 for sale on the Subspace Transporter (SST) market at 20 essentia
  each.

## Key decisions

- Classification is by parsed **reward items**, never by mission title. An
  LCOT mission is any vended instance whose rewards include a plan whose
  class name starts with `Lost City of Tyleon` (the letter comes from the
  plan class, e.g. `Lost City of Tyleon (A)` / plan_type `LCOTa`).
- The "needed set" for the broad usefulness test is seeded from the known
  LCOT mission definitions in `../lacuna_server/mission/missions`
  (`*.mission` and `*.partN` files whose `mission_reward` grants a
  `Building::LCOTx` plan - their `mission_objective` sections, with plan
  classnames matched against reward display names through a normalized
  class key), and extended live by the parsed **objective** items of all
  LCOT instances currently vended plus LCOT instances recorded on disk
  within the last 30 days. The files are a baseline, not an authority:
  live vended LCOT missions add to the set (the server may have
  additional missions), and classification of a vended mission is always
  by its own parsed rewards. Missions rewarding an item appearing in that
  set (resources and happiness included) are useful.
- Missions are never presumed gone. An instance's status changes only on
  direct evidence: our own `complete_mission`/`skip_mission` outcome, or a
  fresh `get_missions` list for that Mission Command building in which a
  previously vended instance no longer appears. Completing one instance never
  marks sibling instances - they stay `active` until each building's own
  fresh list proves otherwise. A `complete_mission` 1002 is also evidence
  (another empire completed it, or the posting expired).
- `complete_mission` is only attempted for instances present in the issuing
  building's current fresh list.
- Skipping is heavyweight (the mission file is suppressed empire-wide for 30
  days), so only missions that are completely useless are skipped: rewards
  match nothing in the needed set AND provide nothing of standalone value,
  or consume more than they provide. A mission with net positive value that
  could plausibly be completed within a day or two is never skipped, even if
  not fulfillable today.
- Fleet-movement objectives name their exact targets in the objective string
  (`Send Probe to Star Name (123,-456).`). Ships are sent by coordinates:
  `send_ship(ship_id, { x, y })` - the server resolves x,y to a body or star.
  No `stars.db` access.
- The fleet-movement arrival requirement is per-empire, keyed on exact ship
  type plus exact target, valid 30 days, and never consumed - probe_hunter
  traffic often satisfies star objectives already. The client cannot query
  the counter; it sends, records the ETA, and lets `complete_mission` rule.
- Cross-colony hauling uses Trade Ministry ships (`trade/push_items`).
  `transporter/push_items` is unusable for hauling (2 essentia and requires
  a transporter at both ends; only Confidence has one). Confidence's
  transporter is used only for frugal 1:1 resource transmutation
  (`transporter/trade_one_for_one`, 3 essentia) when trade ships cannot
  deliver before the mission posting's optimistic expiry, capped per run and
  gated by an essentia floor.
- Ship handling is move-and-report only: qualifying docked ships are
  transferred between colonies; shortages are reported (with a suggested
  `shipbuild` queue line when the type is buildable, checked live via
  `shipyard/get_buildable`). The script never writes to shipyards.
- Ships consumed by a mission are **server-chosen** (alphabetically by ship
  name), so a ship with higher stats than needed can be eaten while a lesser
  qualifying ship survives. Protective renaming (step 7a) reconciles the
  server's alphabetical pick with the desired least-stat-first pick using
  the **fewest renames**: either the overqualified keepers get stable names
  sorting late, or - when fewer renames suffice - the lesser ships to be
  consumed get stable names sorting early so the server picks them. Names
  are derived from **absolute stats** (never relative position or rank), so
  alphabetical order becomes increasing-stat order and a ship never needs
  renaming twice.
- Happiness cannot be hauled; happiness objectives that exceed the anchor
  body's realistic accumulation are reported as long-term blockers and the
  mission is kept.
- SST sales: copies beyond 6 per letter may be listed at 20 essentia. The
  transporter's level caps concurrent listings (Confidence is L1: one at a
  time), so at most one listing is created per run and sold copies are
  relisted on later runs. Listing debits the plan copies from the body at
  offer time; listed-but-unsold copies still count as ours.
- 9/6/20 are defaults, overridable by `--goal`, `--keep`, `--list-at`.

## Server-side facts this design depends on

(Verified in `../lacuna_server`; behavior is identical on the live server.)

- `missioncommand/get_missions(session, building_id)` returns
  `{ missions => [ { id, name, description, objectives, rewards,
  max_university_level, date_posted } ] }`. The list is zone-scoped to the
  building's body, capped at the building's effective level, filtered to
  `max_university_level >= empire university level`, and excludes files the
  empire completed or skipped in the last 30 days. Postings are seeded a few
  per zone per hour and die at 72h or when any empire completes them.
- `objectives` and `rewards` are arrays of pre-rendered strings (see
  "Payload formats" below). Quantities are commified; multi-count lines are
  prefixed by `sprintf("%5s %s", commify(qty), item)`.
- `complete_mission(session, building_id, mission_id)` re-validates
  everything live against the Mission Command's body: university level,
  essentia (empire-wide), happiness (body), stored resources (body), glyphs
  (body), docked ships meeting `>=` stat minimums (body, non-overlapping
  assignment), fleet-movement arrival counters, plans with `level >=` and
  `extra_build_level >=` (lowest-sufficient consumed first). Shortfalls
  throw 1013/1002 with a human-readable message naming the missing item -
  these messages are the authoritative feedback loop. On success it
  consumes the objectives, grants rewards to that body, marks the file done
  for the empire for 30 days, and deletes the posting zone-wide.
- `skip_mission(session, building_id, mission_id)`: free; marks the file
  done for 30 days; the posting stays for other empires.
- Ship consumption at completion is server-chosen: `complete_mission` accepts
  no ship ids. For each ship objective the server selects from the anchor
  body's ships with `task => 'Docked'` and every stat `>=` the minimums,
  ordered by `name ASC, id ASC`, with the candidate rows capped at the total
  needed across all specs (`Mission::get_ship_list`); a greedy pass then
  assigns the tightest-slack spec first and never uses one ship for two
  specs. The selected ids are deleted. The client's only lever over which
  qualifying ships get eaten is ship names (`spaceport/name_ship`).
- `trade/get_plan_summary` returns `{ plans => [ { name, plan_type, level,
  extra_build_level, quantity } ] }`; `name` is the class display name
  (`Lost City of Tyleon (A)`), `plan_type` is the class tail (`LCOTa`).
- Trader payload items for plans and glyphs:
  `{ type => 'plan', plan_type => 'LCOTa', quantity => 1 }` and
  `{ type => 'glyph', name => $type, quantity => N }`. A `plan_id` is not
  required.
- `transporter/add_to_market(session, building_id, offer, ask)`: 1 essentia
  listing fee; ask must be 0.1..100; concurrent listings capped at the
  transporter's effective_level; the offered payload is debited from the body
  immediately. `transporter/view_my_market(session, building_id, [page])`
  returns `{ trades => [ { id, date_offered, ask, offer } ], trade_count }`.
  Buyers pay ask+1; the seller receives the ask.
- `transporter/trade_one_for_one(session, building_id, have, want, qty)`
  swaps resources 1:1 (3 essentia).
- RPC limits: ~2500/day, 1010 on exceed. `Client::call` short-circuits on the
  cached `rpc_limit` flag; missionary treats a thrown 1010 as a clean exit.

## Payload formats

Objectives (suffix-less lines may carry a padded count prefix):

| Kind | Format |
| --- | --- |
| essentia | `10,000 essentia.` |
| happiness | `50,000,000 happiness.` |
| resource | `5,000 gold` |
| glyph | `1 anthracite glyph` / `2 gold glyphs` |
| ship (objective) | `3 Dory (speed >= 1, stealth >= 0, hold size >= 100, combat >= 0, berth >= 1)` |
| ship (reward) | `1 Snark (speed: 500, stealth: 250, hold size: 0, combat: 100, berth: 1)` |
| fleet movement | `Send Surveyor to Body Name (123,-456).` |
| plan (objective) | `2 Halls of Vrbansk (>= 1) plans` (level may be `1+1`) |
| plan (reward) | `1 Lost City of Tyleon (A) level 1 plan` |

Parsing rules:

- Strip the leading count: `^\s*(\d[\d,]*)\s+`, then de-commify.
- Ship display names map to types via `lc($display) =~ s/\s+/_/g`
  (server `type_human` is the inverse).
- Plan display names map to `plan_type` by exact string match against
  `get_plan_summary`'s `name` field; the LCOT letter is taken from
  `plan_type =~ /^LCOT([a-i])$/i` or the `(A)`..`(I)` suffix of the name.
- Fleet movement targets: `Send <Type> to <Name> \((-?\d+),(-?\d+)\)\.$`
  with its own count prefix (e.g. two identical movements consolidate to
  `    2 Send Probe to Star (x,y).`).

## CLI

Usage: `./run_perl.sh missionary.pl [--body Name] [--config file]
[--noaction|-n] [--debug] [--quiet] [--transmute N] [--essentia-floor N]
[--goal N] [--keep N] [--list-at F]`

- `--body` / `-b`: repeatable. Restrict to named colonies (resolved with
  `Client::match_planet`). Default: all colonies.
- `--noaction` / `-n`: repeatable, counted.
  - Level 1 (single `-n`): simulate mutations; reads still happen (vend,
    record, classify, print the plan), no RPC mutations, records still
    written.
  - Level >= 2 (repeated `-n -n`): **fully offline - no RPC calls at all,
    including reads**. No login (the login itself is an RPC), no vend, no
    status fetches. Print a report from local state only (`missions/**/*.json`
    - statuses, classifications, recorded fleet ETAs and blockers,
    holdings as of the last online run) and exit.
- `--debug` / `-d`: repeatable; print parsed needs, decisions, JSON
  snapshots.
- `--quiet`: suppress routine output; errors still print.
- `--config`: client config file, default `config.json`.
- `--transmute`: max `trade_one_for_one` uses per run. Default 1.
- `--essentia-floor`: never transmute below this essentia. Default: 20,
  raised automatically to `max_objective_essentia + 10` over LCOT instances
  seen in the last 30 days (e.g. the 100-essentia LCOT mission keeps the
  floor at 110 while it may appear).
- `--goal`: copies per LCOT letter to accumulate. Default 9.
- `--keep`: copies per letter retained before selling surplus. Default 6.
- `--list-at`: SST ask price per surplus plan copy. Default 20.

## Flow

### 1. Startup

- Set up `@INC` with the repo root and the local Perl library path.
- If `--noaction` was given twice or more (level >= 2): print the
  disk-only report (statuses, classifications, recorded fleet-movement
  ETAs, open blockers, and holdings as of the last online run, all from
  `missions/**/*.json`) and exit **before constructing the client** - the
  login handshake is itself an RPC, so nothing is called.
- Connect `Client`; fetch `empire_status` (university level, essentia,
  colonies with coordinates).
- Resolve `--body` names; default to all colonies.

### 2. Locate buildings

- For each colony: `body_buildings`, then find the Mission Command (skip and
  report bodies without one). Record per body: Mission Command (id, level),
  Trade Ministry, Subspace Transporter (id, level), Space Ports, Shipyards.
- The body whose transporter exists is the SST anchor (currently
  Confidence). Bodies without a Trade Ministry cannot be hauling sources.

### 3. Vend and record

- For each Mission Command: `mission_list(building_id)` (fresh: the 600 s
  cache expires well before the 30-minute cadence).
- Dedupe instances by id across buildings (the same zone posting can be
  vended by two bodies in one zone); track which buildings vend it.
- Record every instance under `missions/<title>/<id>.json`, where `<title>`
  is the mission name sanitized with `s/[^A-Za-z0-9\-.]/_/g` (keep
  alphanumerics, `-`, `.`; everything else, including spaces, parentheses,
  apostrophes, and UTF-8 punctuation, becomes `_`; e.g.
  `Tyleon Dig (part 1)` -> `Tyleon_Dig__part_1_`).
- File content: the raw mission payload plus metadata:

      first_seen, last_seen,
      seen_on: [ { body_id, building_id, last_vended_at } ],
      status: active | completed | skipped | no_longer_listed,
      status_at, status_evidence (e.g. "rpc:complete_mission:ok" or
                                  "list_diff:<building_id>"),
      status_hint (clearly-labeled inference: title_completed_by_us_recently
                   | likely_72h_expiry | likely_sniped | unknown),
      classification: lcot | useful | useless,
      classification_reason, lcot_letter (lcot only),
      actions: [ { time, action, params, result, eta } ]

- Writes merge into existing files: `first_seen` and `actions` are
  preserved; `last_seen`, `seen_on`, classification refresh. Timestamps use
  `Client::format_time` (GMT).

### 4. Status transitions from fresh lists

- An active instance is retired (`no_longer_listed`, evidence
  `list_diff:all_vending_buildings`, plus the inferred `status_hint`) only
  when every building that previously vended it produced a fresh list this
  run and none of those lists still contains it. Absence from a single
  building is not evidence: `get_missions` caps the list at the building's
  effective level, so a shorter Mission Command can omit a posting that a
  taller one in the same zone still vends. Nothing is ever marked
  preemptively; completing a title never touches sibling instances.

### 5. Compute holdings and needed set

- Per LCOT letter (a-i): holdings = sum of `quantity` over every colony's
  `get_plan_summary` entries with `plan_type` matching `^LCOT<letter>$`,
  plus copies inside the SST anchor's active `view_my_market` listings.
- Letters with holdings < `--goal` are outstanding.
- Needed set = union of parsed objective items (resource names and
  quantities, happiness, essentia, glyph types, ship types with their stat
  minimums, plan class/level/extra) over three sources: the known LCOT
  mission files in `../lacuna_server/mission/missions` (parsed from their
  structured `mission_objective` sections), all LCOT instances currently
  vended, and LCOT instances on disk with `last_seen` within 30 days.

### 6. Classify

- lcot: rewards include a `Lost City of Tyleon` plan. Never skipped. Record
  the letter. Priority: letters outstanding first, then surplus-building
  LCOT missions.
- useful: rewards contain any item in the needed set (broad: resources and
  happiness count; ship stats must meet or exceed some needed minimum; plan
  levels likewise). Kept and scheduled for fulfillment by nearness to
  completion.
- useless: nothing in the rewards matches the needed set and the mission
  provides nothing of standalone value, or it consumes more than it
  provides. -> `mission_skip` (unless `--noaction`), recorded as an action
  and status change. On RPC failure, report and leave `active`.

### 7. Fulfill

Process lcot missions first (outstanding letters first), then useful
missions, each against the body whose Mission Command vended it. Parse the
objectives into structured needs and satisfy what can be satisfied:

- Fleet movements: find docked ships of the exact type across all colonies
  (`port_all_ships`); skip if one is already in transit to that target;
  otherwise `send_ship(id, { x, y })` from the nearest colony holding one.
  Record the ETA as an action. If no ship of the type exists anywhere:
  report a blocker - if `shipyard/get_buildable` (live) lists the type,
  emit a suggested `shipbuild <type>` queue line; otherwise note it as a
  mission/exchange-only type (e.g. snark, bleeder, placebo, seeker, supply
  pod classes).
- Essentia: compare `empire_status` essentia. Cannot be fabricated; report
  shortfalls as blockers (the floor protects mission-critical balances).
- Happiness: compare the anchor body's happiness (current or
  `estimated_body_status`). Cannot be hauled; report shortfalls, keep the
  mission.
- Resources: compare anchor body stores. For each shortfall, haul from the
  colony with the most surplus via `trade_push` (plan repeated trips as
  holds allow; compare the trade ship's arrival ETA against the posting's
  optimistic expiry `first_seen + 72h`, since `date_posted` is a game
  calendar string that is not parsed). If no trade ship can arrive in time
  and the anchor body holds a surplus of another resource: one
  `transporter/trade_one_for_one` on the SST anchor's transporter, within
  `--transmute` and the essentia floor. Otherwise report the shortfall.
- Docked-ship objectives: count anchor-body docked ships meeting the stat
  minimums (`port_all_ships`); check free port slots (2 x sum of port
  levels). Shortfall -> transfer qualifying docked ships from other
  colonies (`send_ship(id, { body_id => anchor_id })`), slot permitting;
  record ETAs (ships must be docked at completion). Still short -> report
  with buildability note as above. Once the count is satisfied, run the
  protective-renaming pass (7a) so the hand-in cannot consume better ships
  than the mission needs.
- Glyphs: `glyph_list(anchor)` per type; shortfall -> push glyph cargo from
  a colony holding them (`trade_push`); otherwise report (glyph assembly is
  out of scope).
- Plans: `body_plans(anchor)`; shortfall -> push plan cargo from a colony
  holding a sufficient plan (`trade_push`, plan payload item by
  `plan_type`); otherwise report.

### 7a. Protective ship renaming

Run before any completion attempt whose mission has ship objectives
(`ships` in the parsed objectives):

1. Mirror the server's selection exactly: per spec, the anchor body's
   docked ships of the type with every stat `>=` the minimums, ordered by
   `name, id` (case-insensitive collation), candidate rows capped at the
   total needed across all specs; then the greedy tightest-slack-first
   assignment with no ship used twice. The result is the would-consume
   set.
2. Candidates are totally ordered by stats (hold_size, speed, stealth,
   combat, berth_level). The **desired consume set** is the same greedy
   assignment run over the candidates in increasing-stat order: a mission
   should always eat the least-stat qualifying ships. If the would-consume
   set already equals it, no renames are needed.
3. Otherwise, simulate both repair plans against the mirror and count the
   renames each requires. Renaming re-orders the capped rows and the
   greedy windows, so each plan is iterated until it settles:
   - **Keep plan**: rename every consumed-but-undesired ship to its late
     scheme name (`zzm ...`), re-run the mirror, and repeat while any
     consumed ship is still undesired. Overqualified ships sorted ahead of
     the lesser ones can cascade - each rename may scroll another one
     into the window.
   - **Consume plan**: rename every desired-but-missed ship to its early
     scheme name (`aam ...`), re-run the mirror, and repeat until the
     would-consume set equals the desired set.
   Ships already carrying their scheme name cost nothing (skip them).
4. Execute the plan with fewer renames; on a tie, prefer the keep plan -
   keeper names persist and protect every future hand-in, while sacrifice
   names are destroyed with the consumed ship and would be paid again on
   the next hand-in. The consume plan is typically cheaper when many
   overqualified ships sort ahead of a few lesser ships (renaming the few
   settles it; renaming the many cascades).
5. Scheme names (both are pure functions of absolute stats, and ship
   stats are immutable, so a ship is never renamed twice):

       zzm h<hold:07d> s<speed:06d> t<stealth:05d> c<combat:04d> b<berth:02d>
       aam h<hold:07d> s<speed:06d> t<stealth:05d> c<combat:04d> b<berth:02d>
       e.g. `zzm h0150000 s000200 t00000 c0000 b01` (keep),
            `aam h0004000 s000200 t00000 c0000 b01` (consume)

   - `zzm` sorts after ordinary ship names (digits and letters `a`-`y`
     precede it in the server's case-insensitive collation), so keepers
     are consumed only when too few earlier ships qualify - and then in
     increasing-stat order among scheme names.
   - `aam` sorts before ordinary letter-leading names, so sacrifices are
     consumed first.
   - Fixed-width zero-padded fields make lexicographic order equal
     increasing-stat order for both prefixes; the field order is fixed
     globally: hold_size, speed, stealth, combat, berth_level (hold first
     because it is the binding minimum in the LCOT ship objectives; ties
     break deterministically down the list).
   - Names sorting outside the assumed ranges (a hand-named `zzzz
     Guardian`, a digit-leading `007`) are caught by the re-simulations:
     the offending ship is renamed by the same rule, or the plan switches
     direction. Identical-stat ties produce identical names; the server
     breaks ties by id, and either ship is equally qualified.
6. Renames are recorded as actions and cost one RPC each (a one-time cost
   per ship). `--noaction` simulates them in the local mirror only.

### 8. Completion attempts

- At most one `mission_complete` attempt per instance per run, only when
  the instance is in the issuing building's current fresh list, all local
  checks pass, every required fleet movement has an action record whose
  ETA has passed (or whose shortfall was previously reported as satisfied),
  and - for missions with ship objectives - the would-consume mirror
  matches the desired least-stat consume set after the step 7a renames.
- In `eval`: success -> status `completed`, record and emit. 1013 -> record
  the message as the authoritative shortfall and schedule the fix for the
  next run (a message naming a fleet movement whose send ETA has already
  passed triggers one replacement send). 1002 -> status
  `no_longer_listed` with RPC evidence.

### 9. SST sales

- Reconcile `view_my_market` on the SST anchor: count listed LCOT copies
  per letter. A listing that disappeared since last run was sold (or
  withdrawn); holdings are recounted fresh each run, so no tracking state
  is needed.
- For each letter with `holdings > keep`: sellable copies =
  `holdings - keep - listed_copies`. At most one new listing per run
  (transporter level cap; also skip if any listing is active):
  - If no sellable copy is on the SST anchor, haul one there via
    `trade_push` (plan cargo) and list it on the next run.
  - Else `add_to_market(transporter_id, [ { type => 'plan', plan_type =>
    "LCOT<letter>", quantity => 1 } ], list_at)` (1e fee), recorded as an
    action.
- No automatic withdrawal. List at most one listing per run even after a
  sale (relist next run).

### 10. Summary

Emit per-mission status (vended/classified/skipped/completed/retired),
sends with ETAs, hauls, renames, transmutations, listings, essentia spent,
and open blockers. Errors never abort the whole run; a 1010 (daily RPC
limit short-circuit from `Client::call`) exits cleanly.

## Cache notes

- Read via Client wrappers: `mission_list` (600 s, always stale at the 30-min
  cadence), `body_buildings`, `body_status`, `port_all_ships`, `body_plans`,
  `glyph_list`.
- `mission_complete`/`mission_skip` invalidate the building's mission list;
  `mission_complete` also invalidates the anchor's ship cache when ship-stat
  text appears.
- `send_ship` invalidates the sending body's ship list; `name_ship`
  invalidates the renamed body's ship list. `trade_push` changes the source
  body's stores (status cache) and the ship list; `add_to_market` changes
  the anchor's plan holdings (plans cache) and spends empire essentia.
- `estimated_body_status` advances stale snapshots at zero RPC cost for
  store/happiness checks.
- Direct raw calls used: `trade/get_stored_resources`, `trade/get_trade_ships`,
  `shipyard/get_buildable`, `transporter/trade_one_for_one`,
  `transporter/add_to_market`, `transporter/view_my_market`.

## Edge cases

- A mission vanishes from the list mid-run (completed elsewhere or
  expired): handled at step 4 next run, or via the 1002 at step 8.
- The same instance vended by two Mission Commands in one zone: one record,
  both bodies in `seen_on`; completion via either body.
- Non-ASCII titles (curly quotes, e.g. `The Va'lox of Tyleon`): the
  sanitizer turns every non-`[A-Za-z0-9\-.]` byte into `_`; matching is by
  instance id, never by title.
- University level rises above a vended mission's `max_university_level`:
  `complete_mission` 1013 names it; record, do not retry that day.
- Transporter missing, level 0, or market down: skip the sales phase (and
  transmutation) with a report.
- No Mission Command on any body: report and exit.
- Ships with identical stats produce identical scheme names; the server
  breaks the tie by id, and either ship is equally qualified - no rename
  contest occurs.
- Names sorting outside the assumed ranges (a hand-named `zzzz Guardian`,
  a digit-leading `007`) are caught by the step 7a re-simulations; the
  offending ship is renamed by the same rule or the plan switches
  direction.
- A hand-in that ultimately fails (1013/1002) after renames leaves scheme
  names in place; they remain correct (stats are immutable), keeper names
  keep protecting future hand-ins, and lingering sacrifice names just
  make those low-stat ships the preferred consumption next time.
- An alternative protection lever (never automated): a ship sent travelling
  before hand-in is not a consumption candidate, since only `Docked` ships
  qualify.
- `--noaction` level 1: performs no RPC mutations (send/push/rename/
  transmute/skip/complete/list); still vends, records, classifies, and
  prints the plan. Level >= 2: performs no RPC at all - including reads
  and the login - prints the disk-only report, and exits without writing
  records.

## Files

- Create `missionary.pl` in the repo root (testable layout: package `our`
  vars, subs, `run() unless caller;`).
- Create `t/test_missionary.t.pl`.
- Edit `build_queue_job.cmd`: run `missionary.pl >> logs\missionary.log 2>&1`
  inside both half-hour windows (minutes 0-4 and 30-34, next to the existing
  probe_hunter invocations). The log is append-only; existing log content is
  never modified.
- Edit `.gitignore`: add `missions/`.

## Verification

1. `./run_perl.sh t/test_missionary.t.pl` - unit tests pass.
2. `./run_perl.sh missionary.pl --help` prints usage.
3. `./run_perl.sh missionary.pl --noaction --debug`: vends, writes
   `missions/`, classifies, prints the plan with zero mutations. Inspect
   `missions/**/*.json` with `jq`.
4. Run again with no intervening changes: no duplicate actions, statuses
   stable (no spurious `no_longer_listed`), second completions attempted
   only where ETAs have passed.
5. Real run `./run_perl.sh missionary.pl`; then a follow-up run completes a
   mission whose ships arrived and lists one surplus plan copy at 20e
   (verify with `view_my_market`).
6. Confirm the scheduled task runs it at :00-:04 and :30-:34 and appends to
   `logs/missionary.log`.
7. Unit-test the consumption mirror and rename policy: with a fabricated
   docked fleet, the would-consume set reproduces the server's algorithm
   (alphabetical by name/id, tightest-slack greedy, no ship used twice);
   the desired set is the greedy assignment over increasing-stat order;
   both repair plans are counted cascade-aware and the cheaper executed
   with ties going to the keep plan (e.g. many overqualified ships ahead
   of two lesser ones with a need of two: keep plan costs 6 renames,
   consume plan costs 2 - consume plan wins); renames are idempotent
   (scheme-named ships are skipped); after renaming, the simulated
   consumption equals the desired set; `zzm` names sort after and `aam`
   names sort before ordinary names, and both sort in increasing-stat
   order among themselves.
8. `./run_perl.sh missionary.pl -n -n` makes zero RPC calls - no new
   entries under `log/` for that minute, no session created - and prints
   the disk-only report; a unit test asserts a FakeClient at level >= 2
   records no calls at all.
