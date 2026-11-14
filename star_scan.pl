#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
BEGIN {
  @INC = (@INC, $FindBin::RealBin, "$FindBin::RealBin/local/lib/perl5");
}

use Client;
use DBI;
use Getopt::Long;
use List::Util qw(min max);
use POSIX qw(strftime);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name   = "config.json";
my $db_file       = "stars.db";
my $keep_rpc      = 5;
my $max_row_stars = 15;
my $debug         = 0;
my $noaction      = 0;
my $quiet         = 0;
my $help          = 0;

GetOptions(
  "config=s"   => \$config_name,
  "db=s"       => \$db_file,
  "keep=i"     => \$keep_rpc,
  "max-row-stars=i" => \$max_row_stars,
  "debug+"     => \$debug,
  "noaction"   => \$noaction,
  "quiet"      => \$quiet,
  "help"       => \$help,
) or die "Try '$0 --help' for usage.\n";

usage() and exit 0 if $help;

sub usage {
  print <<"END";
Usage: $0 [options]
  Fetch stars one map row at a time and record them in the star database.

  Rows are ordered so that rows closest to a multiple of 500 (in y) are
  fetched first.  Rows already holding more than --max-row-stars stars in the
  database are skipped.  Fetching stops once only --keep RPC calls remain
  available.

  Intended to be run by scheduler 10 minutes before the daily RPC count reset,
  burning down the day's remaining RPC calls to --keep (default 5).

Options:
  --config <file>        Client config file (default config.json)
  --db <file>            Star database file (default stars.db)
  --keep <n>             Stop when n RPC calls remain (default 5)
  --max-row-stars <n>    Skip rows already holding more than n stars (default 15)
  --debug / -d           Print debug information (repeatable for more)
  --noaction / -n        Simulate: no DB writes (still fetches)
  --quiet                Suppress routine output; errors still print
  --help                 Show this help
END
}

sub emit {
  return if $quiet;
  my $message = shift;
  print POSIX::strftime("%Y-%m-%d %H:%M:%S", gmtime) . " star_scan: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash    = shift;
  require JSON::XS;
  print POSIX::strftime("%Y-%m-%d %H:%M:%S", gmtime) . " $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash), "\n";
}

# Distance from y to the nearest multiple of 500.
sub dist_to_500 {
  my $y = shift;
  my $m = 500;
  my $q = int($y / $m);            # truncate toward zero
  my $c1 = $q * $m;
  my $c2 = $c1 + ($y >= 0 ? $m : -$m);
  return min(abs($y - $c1), abs($y - $c2));
}

sub rpc_remaining {
  my $client = shift;
  my $limit  = $client->{rpc_limit} // 0;
  my $count  = $client->{rpc_count} // 0;
  return max(0, $limit - $count);
}

sub open_star_db {
  my $file = shift;
  -f $file or die "Database does not exist ($file), run star_db_util.pl --create-db\n";
  my $dbh = DBI->connect("dbi:SQLite:$file");
  die "Can't open star database $file: $DBI::errstr\n" unless $dbh;
  $dbh->{RaiseError} = 1;
  $dbh->{PrintError} = 0;
  return $dbh;
}

sub check_schema {
  my $dbh = shift;
  eval { $dbh->do('select id from stars limit 1'); 1 }
    or die "Database is outdated: stars table is missing; run star_db_util.pl --create-db\n";
  return;
}

sub upsert_star {
  my ($dbh, $star, $now) = @_;
  my $exists = $dbh->selectrow_array('select id from stars where x = ? and y = ?', {},
    $star->{x}, $star->{y});
  if ($exists) {
    $dbh->do('update stars set name = ?, color = ?, zone = ?, last_checked = ? where x = ? and y = ?', {},
      $star->{name}, $star->{color}, $star->{zone}, $now, $star->{x}, $star->{y});
  } else {
    $dbh->do('insert into stars (id, name, x, y, color, zone, last_checked, station_id) '
             . 'values (?, ?, ?, ?, ?, ?, ?, ?)', {},
      $star->{id}, $star->{name}, $star->{x}, $star->{y},
      $star->{color}, $star->{zone}, $now, undef);
  }
  return;
}

# --- main ------------------------------------------------------------------

my $client = Client->new(config => $config_name);
my $dbh = open_star_db($db_file);
check_schema($dbh);

# Map bounds from server status, with a sane fallback.
my $ymin = -2000;
my $ymax = 2000;
my $xmin = -2000;
my $xmax = 2000;
if (my $sms = $client->{server_status}{star_map_size}) {
  $xmin = $sms->{x}[0] // -2000;
  $xmax = $sms->{x}[1] // 2000;
  $ymin = $sms->{y}[0] // -2000;
  $ymax = $sms->{y}[1] // 2000;
}
emit("Map y range: $ymin .. $ymax; x range: $xmin .. $xmax");

# Rows ordered by distance to nearest multiple of 500 (closest first).
# Exclude the extreme rows y=2000 and y=-2000 (height-0 corner cases).
my @rows = sort {
  my $da = dist_to_500($a);
  my $db_ = dist_to_500($b);
  $da <=> $db_ || $a <=> $b;
} grep { $_ != 2000 && $_ != -2000 } ($ymin .. $ymax);

my $fetched_rows = 0;
my $inserted     = 0;
my $skipped_rows = 0;
my $fetched_any  = 0;
my $stop_reason  = "no more rows";

my $now = POSIX::strftime("%Y-%m-%d %H:%M:%S", gmtime);

ROW:
for my $y (@rows) {
  my $count = $dbh->selectrow_array('select count(*) from stars where y = ?', {}, $y);
  if ($count > $max_row_stars) {
    $skipped_rows++;
    next ROW;
  }

  emit("Fetching row y=$y")
    if $debug || !$quiet;

  my $result;
  unless ($noaction) {
    $result = eval { $client->map_get_stars($xmin, $y, $xmax, $y); };
    if (!$result) {
      emit("RPC error for row y=$y: $@");
      next ROW;
    }
  } else {
    $result = { stars => [] };
  }

  my $row_count = scalar(@{$result->{stars}});
  $fetched_rows++;
  $fetched_any = 1;
  for my $star (@{$result->{stars}}) {
    upsert_star($dbh, $star, $now);
    $inserted++;
  }
  $dbh->commit unless $noaction;

  emit("Fetched $row_count stars from row y=$y")
    if $debug || !$quiet;

  emit_json("Row y=$y stars", $result) if $debug > 1;

  # In --noaction we never consume RPC, so never stop for budget.
  next ROW if $noaction;
  # Re-read remaining after the call (call() updates rpc_count/rpc_limit).
  last ROW if rpc_remaining($client) <= $keep_rpc;
}

if (!$noaction && $fetched_any && rpc_remaining($client) <= $keep_rpc) {
  $stop_reason = "only " . $keep_rpc . " RPC calls remain";
}

emit("Done: fetched_rows=$fetched_rows inserted=$inserted skipped_rows(>=$max_row_stars stars)="
     . $skipped_rows . " rpc_remaining=" . rpc_remaining($client) . " ($stop_reason)");
