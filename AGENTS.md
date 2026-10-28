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

## Logging

NEVER modify, clean, rewrite, or delete anything in existing log files (e.g.
`logs/*.log`) without EXPLICIT consent given specifically for editing logs.
Requests like "remove the `build_queue started` lines" mean only *stop adding*
those lines in the future — never treat them as permission to retroactively
edit or purge past log content.
