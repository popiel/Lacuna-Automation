sqlite3 -readonly stars.db -header -column <<SQL
SELECT o.x, o.y, s.zone, o.subtype, o.orbit, o.size, o.name,
  floor(sqrt((o.x-k.ox)*(o.x-k.ox)+(o.y-k.oy)*(o.y-k.oy))) as dist
FROM orbitals o
JOIN stars s ON s.id = o.star_id
JOIN (SELECT x AS ox, y AS oy FROM orbitals WHERE name='Confidence') k
WHERE o.subtype IN ('p11','p12','p35')
AND o.orbit between 2 and 5 AND dist < 150
ORDER BY o.subtype, dist, o.size, s.zone, o.name;
SQL
