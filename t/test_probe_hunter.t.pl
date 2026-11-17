use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use DBI;

our $script;

BEGIN {
  $script = abs_path(File::Spec->catfile(dirname(__FILE__), '..', 'probe_hunter.pl'));
  unshift @INC, dirname($script);
}
require $script;

our ($noaction, $quiet, $star_db, @zones, %claimed, %en_route, %sitting);

$noaction = 1;
$quiet    = 1;

# --- valid_zone ----------------------------------------------------------
subtest 'valid_zone' => sub {
  plan tests => 6;
  ok(valid_zone('2|-1'),     'positive zone');
  ok(valid_zone('-3|4'),     'negative zone');
  ok(valid_zone('0|0'),      'zero zone');
  ok(!valid_zone('2|'),      'missing y');
  ok(!valid_zone('|3'),      'missing x');
  ok(!valid_zone('abc|def'), 'non-numeric');
};

# --- compute_build_count -------------------------------------------------
subtest 'compute_build_count' => sub {
  plan tests => 7;
  is(compute_build_count(0, 0, 10, 5), 3, 'need 3, room 5 -> 3');
  is(compute_build_count(3, 0, 10, 5), 0, 'already 3 docked -> 0');
  is(compute_build_count(0, 0, 4, 8),   0, 'no room -> 0');
  is(compute_build_count(1, 1, 10, 2),  1, 'need 1 -> 1');
  is(compute_build_count(0, 3, 10, 5),  0, '3 building -> 0');
  is(compute_build_count(0, 0, 100, 0), 3, 'capped at 3');
  is(compute_build_count(2, 0, 10, 9),  1, '1 slot free -> 1');
};

# --- should_abandon ------------------------------------------------------
subtest 'should_abandon' => sub {
  plan tests => 6;
  ok(should_abandon(5, 0, 0),   'explored, nothing present -> abandon');
  ok(!should_abandon(0, 0, 0),  'not explored -> keep');
  ok(!should_abandon(5, 1, 0),  'colony/station present -> keep');
  ok(!should_abandon(5, 0, 1),  'desirable orbit present -> keep');
  ok(!should_abandon(0, 1, 1),  'not explored and threats -> keep');
  ok(should_abandon(1, 0, 0),   'single orbital, clean -> abandon');
};

# --- find_target against a temp SQLite DB --------------------------------
subtest 'find_target' => sub {
  plan tests => 6;
  my ($fh, $tmpfile) = tempfile();
  close $fh;
  my $dbh = DBI->connect("dbi:SQLite:$tmpfile", '', '', { RaiseError => 1, PrintError => 0 });
  $dbh->do('create table stars (id int primary key, name text, x int, y int, zone text)');
  $dbh->do('create table orbitals (body_id int, star_id int, orbit int, x int, y int, type text, subtype text, empire_id int, station_id int, primary key(star_id, orbit))');

  # star 1: (0,0) zone 0|0, unprobed
  $dbh->do("insert into stars values (1, 'Near', 0, 0, '0|0')");
  # star 2: (1000,0) zone 4|0, probed (has orbital)
  $dbh->do("insert into stars values (2, 'Probed', 1000, 0, '4|0')");
  $dbh->do("insert into orbitals values (1, 2, 1, 1000, 0, 'planet', 'p1', null, null)");
  # star 3: (1200,0) zone 4|0, unprobed
  $dbh->do("insert into stars values (3, 'Far', 1200, 0, '4|0')");

  $star_db = $dbh;
  @zones   = ('0|0', '4|0');
  %claimed = ();
  %en_route = ();
  %sitting = ();

  my $body = { x => 0, y => 0 };

  my $t = find_target('body1', $body);
  is($t->{id}, 1, 'nearest unprobed star in zone');

  # claim it; next call should skip it
  $claimed{1} = 1;
  $t = find_target('body1', $body);
  is($t->{id}, 3, 'next nearest unprobed star after claim');
  $claimed{3} = 1;

  # star 2 is probed (has orbital) so never returned; 1 and 3 now claimed
  $t = find_target('body1', $body);
  is($t, undef, 'no more unprobed stars');

  # sitting stars excluded even if unprobed
  $sitting{3} = 1;
  delete $claimed{1};
  $t = find_target('body1', $body);
  is($t->{id}, 1, 'unclaimed unprobed star returned');

  # both remaining stars unavailable (1 claimed+sitting, 3 sitting)
  $claimed{1} = 1;
  $sitting{1} = 1;
  $t = find_target('body1', $body);
  is($t, undef, 'sitting star excluded from targets');

  # only remaining candidate is en route -> nothing returned
  $claimed{1} = 1;
  $sitting{3} = 0;
  $en_route{3} = 1;
  $t = find_target('body1', $body);
  is($t, undef, 'en_route star skipped when it is the only candidate');
};

# --- affordable_count ------------------------------------------------------
subtest 'affordable_count' => sub {
  plan tests => 8;
  my $cost = { food => 1000, ore => 2000, water => 500, energy => 4000 };
  my $now = time();

  # all resources plentiful
  my $status = { food_stored => 5000, ore_stored => 9000, water_stored => 2500, energy_stored => 16000 };
  is(affordable_count($cost, $status), 4, 'plentiful stores -> min ratio');

  # energy is the binding constraint
  $status = { food_stored => 5000, ore_stored => 9000, water_stored => 2500, energy_stored => 9000 };
  is(affordable_count($cost, $status), 2, 'binding constraint -> 2');

  # a missing resource blocks everything
  $status = { food_stored => 5000, ore_stored => 9000, energy_stored => 16000 };
  is(affordable_count($cost, $status), 0, 'missing resource -> 0');

  # no _time: elapsed 0, no rate drift applied
  $status = { food_stored => 5000, ore_stored => 9000, water_stored => 2500, energy_stored => 9000 };
  is(affordable_count($cost, $status), 2, 'no _time -> no drift');

  # with a _time in the past, positive rates grow the estimate: energy is
  # the binding resource and the drift is what lifts it from 2 to 3
  $status = { _time => $now - 3600,
              food_stored => 5000,  food_hour  => 100,  food_capacity  => 20000,
              ore_stored  => 9000,  ore_hour   => 200,  ore_capacity   => 30000,
              water_stored => 2500, water_hour => 50,   water_capacity => 10000,
              energy_stored => 11900, energy_hour => 400, energy_capacity => 40000 };
  is(affordable_count($cost, $status), 3, 'drift lifts the binding constraint');

  # negative rates clamp at zero rather than going negative
  $status = { _time => $now - 3600,
              food_stored => 0, food_hour => -100, food_capacity => 20000,
              ore_stored  => 9000, ore_hour => 0, ore_capacity => 30000,
              water_stored => 2500, water_hour => 0, water_capacity => 10000,
              energy_stored => 9000, energy_hour => 0, energy_capacity => 40000 };
  is(affordable_count($cost, $status), 0, 'negative rate clamps at zero -> 0');

  # growth clamps at capacity: raw drift would allow 201, cap holds 200
  $status = { _time => $now - 7200,
              food_stored => 99900, food_hour => 500, food_capacity => 100000 };
  is(affordable_count({ food => 500 }, $status), 200, 'capacity clamp caps the estimate');

  # future _time (clock skew) is treated as no elapsed time
  $status = { _time => $now + 600,
              food_stored => 5000, ore_stored => 9000, water_stored => 2500, energy_stored => 9000 };
  is(affordable_count($cost, $status), 2, 'future _time -> no drift');
};

done_testing();
