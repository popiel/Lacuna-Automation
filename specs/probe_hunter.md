# probe_hunter.pl

## Purpose

Find unprobed stars in the requested zones and use the supplied bases to:

- Abandon probes sitting at stars that have already been explored and have no
  reason to keep watching.
- Send docked probes to the nearest unexplored stars.
- Build additional probes when dock space and observatory capacity allow it.

## Key decisions

- Zones and bases are supplied with repeatable options; there are no positional
  arguments.
- Stars where probes are already sitting are excluded from target selection,
  in addition to stars that already have probes en route.
- The number of probes to build is the minimum of the number needed to reach
  three docked probes and the number of free space-port slots.
- If a sitting probe is at a star with no orbitals in `stars.db`, the script
  closes the DB, invokes `star_db_util.pl`, reopens the DB, and rechecks before
  abandoning.
- `stars.station_id` only indicates that the star is under the protection or
  control of a station. It does not indicate that a station is physically
  present at the star, and it must not be used to preserve sitting probes.

## CLI

Usage: `./run_perl.sh probe_hunter.pl --zone X|Y --body Name [--config file] [--db file] [--noaction] [--debug] [--quiet]`

- `--zone` / `-z`: repeatable, required. Validate zone syntax as `X|Y` with
  integer components.
- `--body` / `-b`: repeatable, required. Resolve with `Client::match_planet`;
  abort on invalid or ambiguous names.
- `--noaction` / `--dryrun` / `-n`: simulate without RPC mutations or DB
  writes.
- `--debug` / `-d`: print JSON snapshots and the `star_db_util.pl` command.
- `--quiet`: suppress routine output; errors still print.
- `--config`, `--db`: forwarded to the client and DB connection setup.

## Flow

### 1. Startup

- Set up `@INC` with the repo root and the local Perl library path.
- Connect `Client`.
- Invalidate `empire_status`, then fetch a fresh `empire_status`.
- Resolve body names to ids and sort by name.

### 2. Validate bases

- Invalidate the `buildings` cache for each body.
- Require at least one Observatory, one Space Port, and one Shipyard via
  `find_building` (list context for Space Ports and Shipyards).
- Reject and report bodies missing any of the three. Exit 1 if none remain.

### 3. Fetch per-body data

- Invalidate the observatory, space-port, and shipyard caches.
- Fetch and store body status, probed stars, docked and travelling ships, yard
  queues, and buildable data.
- If observatory or port data cannot be fetched, skip that body's probe
  operations.

### 4. Open the DB and check schema

- Connect to `stars.db`; this script only runs reads against it.
- Die with an upgrade hint if `stars.zone`, `orbitals.subtype`, or
  `orbitals.station_id` are missing.

### 5. Build global sets

- `%sitting`: star ids from every valid body's observatory stars list.
- `%en_route`: star ids from every valid body's travelling probes that have a
  destination.

### 6. Capture missing star data

- Check every `%sitting` star for orbitals in `stars.db`.
- If any are missing and the script is not in `--noaction` mode:
  - Close the DB handle.
  - Invoke `star_db_util.pl` with `--planet` for the affected bases.
  - Reopen the DB and recheck condition 1.
- On failure, report and continue with the existing DB contents.
- In `--noaction`, skip the update and report that orbitals are missing.

### 7. Abandon probes

For each star in each valid body's observatory stars list, abandon the probe
only if all of the following hold:

- **C1 explored:** orbitals exist for the star.
- **C2 no colony or station:** no orbital for the star has a colony or a
  station. `stars.station_id` is not consulted.
- **C3 no desirable orbits:** no orbital on orbits 2 through 5 has subtype
  `p11`, `p12`, `p33`, or `p35`.

Call `abandon_probe`. On success, decrement the local `star_count`. On RPC
failure, keep the probe.

### 8. Send probes

- `room = max_probes - star_count - travelling` after abandons.
- Docked probes are those with type `probe` and task `Docked`.
- For each docked probe while `room > 0`:
  - Find the nearest unprobed stars in the requested zones, ordered by squared
    distance from the body.
  - Skip stars in `%claimed`, `%en_route`, and `%sitting`.
  - Mark the target in `%claimed`, then call `send_ship`.
  - On success: decrement `room`, add the target to `%en_route`, and report the
    arrival time.
  - On failure: unclaim the target, report the error, and continue.

### 9. Build probes

- `docked = docked probes - successful sends`.
- `building = sum of probe ships in yard queues`.
- `slots = 2 * sum of Space Port levels`.
- `used = all ships returned by view_all_ships`, including travelling ships.
- `room = max(0, slots - used)`.
- `need = 3 - docked - building`.
- If `need > 0` and `room > 0`, build `min(need, room)` probes.
- Prefer shipyards where probes are buildable; pick the shortest queue; call
  `yard_build`. On failure, retry with one probe, then try the next shipyard.
- `--noaction` simulates the count changes without calling `yard_build`.

### 10. Summary

Report totals for probes abandoned, sent, and built, plus any bodies skipped
and why.

## Cache notes

- Invalidate before reading: `buildings`, `observatory_get_probed_stars`,
  `spaceport_view_all_ships`, `shipyard_view_build_queue`,
  `shipyard_buildable`.
- `yard_build` invalidates the yard queue, body buildings, and space-port ship
  list itself.
- `send_ship` and `abandon_probe` do not invalidate their caches; the next run
  invalidates them.

## Edge cases

- Invalid or missing zones or bodies, no valid bases, missing or outdated DB:
  usage error or fatal message.
- API failure for a body's observatory or ships: skip that body's probe
  operations.
- Yard queue or buildable failure: skip building for that yard.
- No unprobed stars in the requested zones: send nothing, but still consider
  building.
- Sitting-probe stars are excluded from targets even if `stars.db` does not
  yet know about their orbitals.
- `--noaction` performs no RPC mutations and does not invoke
  `star_db_util.pl`.

## Files

- Create `probe_hunter.pl` in the repo root.
- Optionally add a short `README` section.

## Verification

1. `./run_perl.sh probe_hunter.pl --help` prints usage.
2. Run with `--noaction` on a small zone and base; inspect the planned
   abandons, sends, and builds.
3. Cross-check target selection against `hunt_stars.sh`.
4. Run without `--noaction` on one test body and verify observatory and
   space-port state afterward.
5. Confirm `star_db_util.pl` is invoked only when a sitting-probe star lacks
   orbitals.
