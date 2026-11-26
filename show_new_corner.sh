sqlite3 -readonly stars.db -header -column <<SQL
select
  sqrt((s.x - ok.x)*(s.x - ok.x) + (s.y - ok.y)*(s.y - ok.y)) as dist,
  s.x, s.y, s.zone, o.size, o.orbit, o.subtype, o.name
from stars s
join orbitals ok on ok.name = 'Confidence'
join orbitals o on o.star_id = s.id
where o.subtype in ('p11', 'p12')
  and o.size >= 50
  and s.zone in ('2|-3', '3|-3')
  and o.orbit in (2, 3, 4, 5)
order by dist limit 10;
SQL
