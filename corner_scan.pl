#!/usr/bin/perl

use strict;

BEGIN {
  @INC = (@INC, ".", "local/lib/perl5");
}

use warnings;

use DBI;
use Getopt::Long;
use POSIX qw(strftime);
use List::Util qw(first);

use Client;

my $zone_size   = 250;
my $scan_back   = 14;
my $scan_fwd    = 15;
my $skip_radius = 15;

my %opts;
GetOptions(\%opts,
    'h|help',
    'config=s',
    'db=s',
    'center-zone=s',
    'ring=i',
    'corner=s@',
    'max-corners=i',
    'max-per-minute=i',
    'dry-run',
    'verbose',
) or usage();
usage() if $opts{h};

my $config_name  = $opts{config} || "config.json";
my $db_file      = $opts{db} || "./stars.db";
my $center_label = $opts{'center-zone'} || "0|0";
my $ring         = defined $opts{ring} ? $opts{ring} + 0 : 3;
my $rate         = ($opts{'max-per-minute'} || 10) + 0;
$rate = 1 if $rate < 1;

my ($center_x, $center_y) = $center_label =~ /^(-?\d+)\|(-?\d+)$/
    or die "Bad --center-zone '$center_label' (expected X|Y)\n";

my @wanted;
if ($opts{corner}) {
    for my $c (@{$opts{corner}}) {
        my ($x, $y) = $c =~ /^(-?\d+)\|(-?\d+)$/
            or die "Bad --corner '$c' (expected X|Y)\n";
        push @wanted, [$x, $y];
    }
} else {
    @wanted = corners();
}
@wanted = splice(@wanted, 0, $opts{"max-corners"}) if $opts{"max-corners"};

-f $db_file or die "No star database found at $db_file (run star_db_util.pl --create-db first)\n";
my $db = DBI->connect("dbi:SQLite:$db_file") or die "Can't open $db_file: $DBI::errstr\n";
$db->{RaiseError} = 1;
$db->{PrintError} = 0;
eval { $db->do('select id from stars limit 1') }
    or die "Table 'stars' not found in $db_file (run star_db_util.pl --create-db)\n";
$db->{AutoCommit} = 0;

my ($total, @todo);
for my $corner (@wanted) {
    my ($cx, $cy) = @$corner;
    $total++;
    my ($n) = $db->selectrow_array(
        'select count(*) from stars where x >= ? and x <= ? and y >= ? and y <= ?',
        {}, $cx - $skip_radius, $cx + $skip_radius, $cy - $skip_radius, $cy + $skip_radius,
    );
    if ($n) {
        verbose(sprintf("skip %d|%d: %d existing star(s) within %d", $cx, $cy, $n, $skip_radius));
        next;
    }
    push @todo, $corner;
}

my $rpc_est = scalar(@todo);
my $time_est = sprintf("%.1f", $rpc_est / $rate);
printf("corners=%d skip=%d scan=%d rpc=%d est_time=%s min rate=%d/min\n",
    scalar(@wanted), scalar(@wanted) - scalar(@todo), scalar(@todo), $rpc_est, $time_est, $rate);

my $client;
my @rpc_log;
my $rpc_count = 0;
my $stars_before = count_stars();

if ($opts{'dry-run'}) {
    print "dry run: no RPC calls issued\n";
    exit 0;
}

$client = Client->new(config => $config_name);

my $stars_after;
for my $corner (@todo) {
    my ($cx, $cy) = @$corner;
    throttle();
    my $result = $client->map_get_stars($cx - $scan_back, $cy - $scan_back, $cx + $scan_fwd, $cy + $scan_fwd);
    verbose(sprintf("scan %d|%d -> %d star(s)", $cx, $cy, scalar @{$result->{stars}}));
    for my $star (@{$result->{stars}}) {
        upsert_star($star);
    }
    record_corner($cx, $cy);
    $db->commit;
    $rpc_count++;
}

$stars_after = count_stars();
$db->commit;
$db->disconnect;

printf("done: scanned %d corners, %d RPC, stars %d -> %d\n",
    scalar(@todo), $rpc_count, $stars_before, $stars_after);

exit 0;

sub corners {
    my %xs;
    for my $i ($center_x - $ring .. $center_x + $ring) {
        $xs{ $i * $zone_size }        = 1;
        $xs{ ($i + 1) * $zone_size }  = 1;
    }
    my %ys;
    for my $j ($center_y - $ring .. $center_y + $ring) {
        $ys{ $j * $zone_size }        = 1;
        $ys{ ($j + 1) * $zone_size }  = 1;
    }
    my @x = sort { $a <=> $b } keys %xs;
    my @y = sort { $a <=> $b } keys %ys;
    printf("ring %d around %d|%d -> %d x-lines x %d y-lines = %d corners\n",
        $ring, $center_x, $center_y, scalar(@x), scalar(@y), scalar(@x) * scalar(@y))
        if $opts{'verbose'};
    return map { my $yy = $_; map { [ $_, $yy ] } @x } @y;
}

sub upsert_star {
    my $star = shift;
    my $zone = $star->{zone};
    unless (defined $zone) {
        $zone = join '|', int($star->{x} / $zone_size), int($star->{y} / $zone_size);
    }
    my $station_id;
    if (my $station = $star->{station}) {
        $station_id = ref($station) eq 'HASH' ? $station->{id} : $station;
    }
    my $now = strftime('%Y-%m-%d %H:%M:%S', gmtime());
    if (my $row = $db->selectrow_hashref('select id from stars where id = ?', {}, $star->{id})) {
        $db->do('update stars set name = ?, x = ?, y = ?, color = ?, zone = ?, station_id = ?, last_checked = ? where id = ?',
            {}, $star->{name}, $star->{x}, $star->{y}, $star->{color}, $zone, $station_id, $now, $star->{id});
    } else {
        $db->do('insert into stars (id, name, x, y, color, zone, station_id, last_checked) values (?,?,?,?,?,?,?,?)',
            {}, $star->{id}, $star->{name}, $star->{x}, $star->{y}, $star->{color}, $zone, $station_id, $now);
    }
}

sub record_corner {
    my ($cx, $cy) = @_;
    $db->do('create table if not exists corner_scan (x int, y int, scanned datetime, stars int, primary key (x, y))');
    $db->do('insert or replace into corner_scan (x, y, scanned, stars) values (?,?,?,?)', {},
        $cx, $cy, strftime('%Y-%m-%d %H:%M:%S', gmtime()),
        $db->selectrow_array('select count(*) from stars where x >= ? and x <= ? and y >= ? and y <= ?',
            {}, $cx - $skip_radius, $cx + $skip_radius, $cy - $skip_radius, $cy + $skip_radius));
}

sub throttle {
    while (1) {
        my $now = time();
        @rpc_log = grep { $_ > $now - 60 } @rpc_log;
        last if @rpc_log < $rate;
        my $wait = $rpc_log[0] + 60 - $now + 1;
        print "rate limit: sleeping $wait sec\n" if $opts{verbose};
        sleep($wait);
    }
    push @rpc_log, time();
}

sub count_stars {
    my $n = $db->selectrow_array('select count(*) from stars');
    return $n;
}

sub verbose {
    return unless $opts{verbose};
    print "@_\n";
}

sub usage {
    print <<EOT;
usage: corner_scan.pl [options]

options:
  --config=s          API config (default config.json)
  --db=s              star database (default ./stars.db)
  --center-zone=X|Y   ring center zone (default 0|0)
  --ring=i            ring distance in zone labels (default 3)
  --corner=X|Y        restrict scan to specific corner(s), repeat for several
  --max-corners=i     cap how many corners are scanned this run
  --max-per-minute=i  RPC pacing cap (default 10)
  --dry-run           enumerate and report plan without RPC
  --verbose           extra output
EOT
    exit 0;
}
