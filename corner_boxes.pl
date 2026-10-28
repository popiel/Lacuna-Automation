#!/usr/bin/perl

use strict;

BEGIN {
  @INC = (@INC, ".", "local/lib/perl5");
}

use warnings;

use DBI;
use Getopt::Long;
use POSIX qw(strftime);

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
    'corner=s@',
    'max-per-minute=i',
    'dry-run',
    'verbose',
) or usage();
usage() if $opts{h};

my $config_name = $opts{config} || "config.json";
my $db_file     = $opts{db} || "./stars.db";
my $rate        = ($opts{'max-per-minute'} || 10) + 0;
$rate = 1 if $rate < 1;

@{ $opts{corner} } or usage();

-f $db_file or die "No star database found at $db_file (run star_db_util.pl --create-db first)\n";
my $db = DBI->connect("dbi:SQLite:$db_file") or die "Can't open $db_file: $DBI::errstr\n";
$db->{RaiseError} = 1;
$db->{PrintError} = 0;
eval { $db->do('select id from stars limit 1') }
    or die "Table 'stars' not found in $db_file (run star_db_util.pl --create-db)\n";
$db->{AutoCommit} = 0;

my $boxes_half = 30;  # side boxes are 30x30, contiguous with the center box
my @bands = (
    [ -( $scan_back + $boxes_half ), -( $scan_back + 1 ) ], # left/below: cx-44..cx-15
    [ -$scan_back, $scan_fwd ],                             # center box:  cx-14..cx+15
    [  $scan_fwd + 1, $scan_fwd + $boxes_half ],            # right/above: cx+16..cx+45
);

my @boxes;
for my $corner (@{ $opts{corner} }) {
    my ($cx, $cy) = $corner =~ /^(-?\d+)\|(-?\d+)$/
        or die "Bad --corner '$corner' (expected X|Y)\n";
    my ($n) = $db->selectrow_array(
        'select count(*) from stars where x >= ? and x <= ? and y >= ? and y <= ?',
        {}, $cx - $scan_back, $cx + $scan_fwd, $cy - $scan_back, $cy + $scan_fwd,
    );
    unless ($n) {
        verbose(sprintf("corner %d|%d: center empty (%d <= x,y in DB), fetching center box too",
            $cx, $cy, $n));
        push @boxes, [$cx, $cy, $cx - $scan_back, $cy - $scan_back, $cx + $scan_fwd, $cy + $scan_fwd];
    }
    for my $xb (@bands) {
        for my $yb (@bands) {
            next if $xb->[0] == -$scan_back && $yb->[0] == -$scan_back;
            push @boxes, [$cx, $cy,
                $cx + $xb->[0], $cy + $yb->[0], $cx + $xb->[1], $cy + $yb->[1]];
        }
    }
}

my $rpc_est = scalar(@boxes);
my $time_est = sprintf("%.1f", $rpc_est / $rate);
printf("boxes=%d rpc=%d est_time=%s min rate=%d/min\n",
    scalar(@boxes), $rpc_est, $time_est, $rate);

my @rpc_log;
my $rpc_count = 0;
my $stars_before = count_stars();

if ($opts{'dry-run'}) {
    for my $box (@boxes) {
        my ($cx, $cy, $x1, $y1, $x2, $y2) = @$box;
        my ($n) = $db->selectrow_array(
            'select count(*) from stars where x >= ? and x <= ? and y >= ? and y <= ?',
            {}, $x1, $x2, $y1, $y2);
        printf("%s box %d,%d -> %d,%d : %d existing star(s)\n",
            $opts{verbose} ? sprintf("corner %d|%d", $cx, $cy) : "scan",
            $x1, $y1, $x2, $y2, $n);
    }
    print "dry run: no RPC calls issued\n";
    exit 0;
}

my $client = Client->new(config => $config_name);

my $stars_after;
for my $box (@boxes) {
    my (undef, undef, $x1, $y1, $x2, $y2) = @$box;
    throttle();
    my $result = $client->map_get_stars($x1, $y1, $x2, $y2);
    verbose(sprintf("box %d,%d -> %d,%d : %d star(s)",
        $x1, $y1, $x2, $y2, scalar @{$result->{stars}}));
    for my $star (@{$result->{stars}}) {
        upsert_star($star);
    }
    $db->commit;
    $rpc_count++;
}

$stars_after = count_stars();
$db->commit;
$db->disconnect;

printf("done: scanned %d boxes, %d RPC, stars %d -> %d\n",
    scalar(@boxes), $rpc_count, $stars_before, $stars_after);

exit 0;

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
usage: corner_boxes.pl [options]

Fetches the 8 surrounding 30x30 boxes of stars for one or more zone
corners (the center box itself is fetched only if the database has no
stars within the center window for that corner).

options:
  --config=s          API config (default config.json)
  --db=s              star database (default ./stars.db)
  --corner=X|Y        corner to ring-scan, repeatable
  --max-per-minute=i  RPC pacing cap (default 10)
  --dry-run           enumerate boxes and report plan without RPC
  --verbose           extra output
EOT
    exit 0;
}
