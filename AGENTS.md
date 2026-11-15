# Lacuna-Automation

## Zone coordinates

Zones are 250x250 squares of the game map. Zone labels are formed by
TRUNCATION (Perl `int()`), not floor: `zone = int(x/250) . '|' . int(y/250)`.
`int()` truncates toward zero, which matters for negative coordinates:

- Zone column 0 is double-width in each axis (x -249..249, y -249..249),
  making zone 0|0 four times the area of every other zone.
- Zone |-1 spans y -499..-250, NOT y -250..-1.
- The corner shared by zones `A|B` and `(A+1)|(B-1)` is at
  (x = (A+1)*250, y = B*250). Example: zones 2|-1 and 3|-2 meet at
  (750, -500) -- NOT (750, -250), which is the corner of 2|-1, 3|-1, 2|0, 3|0.

When picking a zone corner to scan, verify against data already in the
star database (`stars.db`, e.g. the `corner_scan` table or the stars'
y-coordinates) rather than recomputing from the zone label alone.

## Server/mission source

A local clone of the `tlecommunity/v2` repo lives in `../lacuna_server`
(sibling of this repo). Use it instead of fetching from the web. Mission
definitions are in `../lacuna_server/mission/missions/*.mission`; each file's
`max_university_level` is the highest university level at which the mission is
still offered (see `bin/mission_check.pl`).

## Logging

NEVER modify, clean, rewrite, or delete anything in existing log files (e.g.
`logs/*.log`) without EXPLICIT consent given specifically for editing logs.
Requests like "remove the `build_queue started` lines" mean only *stop adding*
those lines in the future — never treat them as permission to retroactively
edit or purge past log content.

## Scheduled Task: Lacuna Build Queue

The `build_queue_job.cmd` script runs every 5 minutes via a Windows Scheduled
Task named `Lacuna Build Queue`, registered by `FILBERT\tapop` on
2026-10-24. It runs as the current user with `LogonType=S4U` (runs without
user logged on) and `MultipleInstancesPolicy=IgnoreNew`.

### Querying the task

`schtasks.exe` from Git Bash's `cmd.exe` wrapper is broken: it rewrites
`/query` as `C:/Program Files/Git/query` and fails with
`ERROR: Invalid argument/option - 'C:/Program Files/Git/query'`. Do **not**
use `cmd /c "schtasks ..."` from Bash; the path translation breaks it.

Use PowerShell instead:

```powershell
# Basic task info
Get-ScheduledTask -TaskName 'Lacuna Build Queue' | Select-Object TaskName, State, Triggers, Actions

# Trigger details
$t = Get-ScheduledTask -TaskName 'Lacuna Build Queue'
foreach ($tr in $t.Triggers) { $tr | Format-List * }

# Full XML export (COM approach, most reliable)
$service = New-Object -ComObject Schedule.Service
$service.Connect()
$task = $service.GetFolder('\').GetTask('Lacuna Build Queue')
$task.Xml | Out-File "task.xml" -Encoding UTF8
```

Task properties as of last check:
- StartBoundary: `2026-10-24T13:00:00` (local system time, no `<TimeZone>` element)
- RepetitionInterval: `PT5M` (every 5 minutes)
- MultipleInstancesPolicy: `IgnoreNew`
- ExecutionTimeLimit: `PT72H`
- Command: `C:\Users\tapop\Documents\src\Lacuna-Automation\build_queue_job.cmd`

### Time parsing bug in build_queue_job.cmd

The batch file uses `%time%` (local system time) for scheduling decisions.
Two pitfalls:

1. **Single-digit hour parsing**: `1%HH% %% 100` wraps hour `5` into `15`
   (`15 %% 100 = 15`), causing `HHN EQU 15` to match at 05:xx as well as 15:xx.
   Fix: use `100%HH% %% 100` instead (hour `5` → `105 %% 100 = 5`, hour `15`
   → `10015 %% 100 = 15`).

2. **`%time%` vs GMT log timestamps**: Perl's `Client::log_call` uses `gmtime()`
   (`format_time($time, 1)`), so `logs/` filenames are GMT. Windows `%time%`
   is local PST (UTC-8). Midnight GMT reset = 16:00 PST same day; 10 minutes
   before = 15:50 PST = 23:50 GMT. The `star_scan` invocation in
   `build_queue_job.cmd` checks `HHN EQU 15` and `MMN GEQ 50`, firing at
   15:50–15:59 PST (23:50–23:59 GMT), 10 minutes before the midnight GMT RPC
   reset.

3. **Delayed expansion required**: `%time%` is parsed at parse time, so
   `set HH=%%a` inside a `for` loop inside an `if` block needs `setlocal
   EnableDelayedExpansion` and `!VAR!` syntax to read updated values within
   the same block.

4. **star_scan.pl GMT hour guardrail**: `star_scan.pl` checks the current GMT
   time before every `map/get_stars` RPC call and aborts the row loop if the
   time is not within the last 10 minutes of the GMT day (23:50-23:59).  The
   RPC count resets at midnight GMT; running right after the reset burns the
   day's calls before the user can play.  This check is performed per-row in
   the main scan loop, not just once at startup.
