#!/usr/bin/perl

use strict;

use Carp;
use Client;
use DBI;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util qw(min max sum first);
use File::Path;
use POSIX qw(strftime);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $db_file = "stars.db";
my $max_build_time = 86400;
my $max_distance = 3000;
my $recheck_distance = 100;
my $recheck_frequency = 30 * 24 * 60 * 60;
my $keep_distance = 15;
my $debug = 0;
my $noaction = 0;
my $quiet = 0;

GetOptions(
  "config=s"  => \$config_name,
  "body|b=s"  => \@body_names,
  "db=s"      => \$db_file,
  "max_build_time|build|fill=s"   => \$max_build_time,
  "max_distance|distance=i"       => \$max_distance,
  "recheck_distance|recheck=i"    => \$recheck_distance,
  "recheck_frequency|frequency=s" => \$recheck_frequency,
  "keep_distance=i"               => \$keep_distance,
  "debug+"    => \$debug,
  "noaction"  => \$noaction,
  "quiet"     => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};

$max_build_time = $1         if $max_build_time =~ /^(\d+) ?s(econds?)?$/;
$max_build_time = $1 * 60    if $max_build_time =~ /^(\d+) ?m(inutes?)?$/;
$max_build_time = $1 * 3600  if $max_build_time =~ /^(\d+) ?h(ours?)?$/;
$max_build_time = $1 * 86400 if $max_build_time =~ /^(\d+) ?d(ays?)?$/;

$recheck_frequency = $1         if $recheck_frequency =~ /^(\d+) ?s(econds?)?$/;
$recheck_frequency = $1 * 60    if $recheck_frequency =~ /^(\d+) ?m(inutes?)?$/;
$recheck_frequency = $1 * 3600  if $recheck_frequency =~ /^(\d+) ?h(ours?)?$/;
$recheck_frequency = $1 * 86400 if $recheck_frequency =~ /^(\d+) ?d(ays?)?$/;

-f $db_file or die "Database does not exist, please specify star_db_util.pl --create to continue\n";
my $star_db = DBI->connect("dbi:SQLite:$db_file");
$star_db or die "Can't open star database $db_file: $DBI::errstr\n";
$star_db->{RaiseError} = 1;
$star_db->{PrintError} = 0;

# Check if db is current, if not, suggest upgrade
eval {
  $star_db->do('select excavated_by from orbitals limit 1');
  1;
} or do {
  die "Database is outdated, please specify star_db_util.pl --upgrade to continue\n";
};

my $planets = $client->empire_status->{planets};

@body_names = values(%$planets) unless @body_names;
my @body_ids = map { $client->match_planet($_) } @body_names;
if ((@body_ids != @body_names)) {
  emit("Aborting due to identification errors", $empire_name);
  exit 1;
}
@body_names = map { $planets->{$_} } @body_ids;

my %obs   = map { ($_, scalar(eval { $client->find_building($_, "Observatory") } )) } @body_ids;
my %ports = map { ($_, scalar(eval { $client->find_building($_, "Space Port" ) } )) } @body_ids;
my %yards = map { ($_, [      eval { $client->find_building($_, "Shipyard"   ) } ]) } @body_ids;

@body_ids = grep { $obs{$_} && $ports{$_} && @{$yards{$_}} } @body_ids;

my %ships = map { ($_, $client->port_all_ships($_)) } @body_ids;
my %stars = map { ($_, $client->get_probed_stars($obs{$_}{id})) } @body_ids;

my %claimed = map  { ($_->{to}{id}, $_) }
              grep { $_->{type} eq "probe" && $_->{task} eq "Travelling" }
              map  { @{$ships{$_}{ships}} }
              @body_ids;
# for my $body_id (@body_ids) {
#   my @travelling = grep { $_->{type} eq "probe" && $_->{task} eq "Travelling" } @{$ships{$body_id}{ships}};
#   $claimed{$_->{to}{id}} = $_ for @travelling;
# }

for my $body_id (@body_ids) {
  my $stars = $stars{$body_id};
  $debug > 2 and emit_json("Probes for $body_id", $stars);
  for my $star (@{$stars->{stars}}) {
    db_update_star($star, $stars->{status}{_time});
    if (!check_keeper($star)) {
      $noaction or $client->call(observatory => abandon_probe => $obs{$body_id}{id}, $star->{id});
      emit("Abandoning proble at $star->{name} ($star->{x},$star->{y})", $body_id);
      $stars->{star_count}--;
    }
  }
}

for my $body_id (@body_ids) {
  my $stars = $stars{$body_id};
  my $wanted = $obs{$body_id}{level} * 3 - $stars->{star_count};

  $debug > 1 and emit_json("All ships for $body_id", $ships{$body_id}{ships});
  my @probes = grep { $_->{type} eq "probe" } @{$ships{$body_id}{ships}};
  my @ready = grep { $_->{task} eq "Docked" } @probes;
  $debug > 1 and emit_json("Ready probes for $body_id", \@probes);

  my $delta = $wanted - @probes;
  ship_build($body_id, "probe", $delta, $max_build_time);

  for my $probe (@ready) {
    my $target = db_find_target($body_id);
    $claimed{$target->{id}} = $probe; # Do this immediately to prevent duplicate scans
    eval {
      my $result;
      $noaction or ($result = $client->send_ship($probe->{id}, { star_id => $target->{id} }));
      my $arrives = Client::format_time(Client::parse_time($result->{ship}{date_arrives}));
      my $body = $client->body_status($body_id);
      emit("Sent probe ".int(sqrt(dist2($body, $target)))." units".
           " to $target->{name} at ($target->{x},$target->{y}),".
           " arriving at $arrives", $body_id);
      1;
    } or emit("Couldn't send probe to $target->{name} at ($target->{x},$target->{y}): $@", $body_id);
  }
}

sub dist2 {
  my ($a, $b) = @_;
  return ($a->{x} - $b->{x}) * ($a->{x} - $b->{x}) + ($a->{y} - $b->{y}) * ($a->{y} - $b->{y});
}

sub db_update_star {
  my $star = shift;
  my $when = shift;

  my @ores = qw(anthracite bauxite beryl     chalcopyrite chromite
                fluorite   galena  goethite  gold         gypsum
                halite     kerogen magnetite methane      monazite
                rutile     sulfur  trona     uraninite    zircon);
  my @attrs = qw(body_id star_id orbit x y type subtype name size water);

  my $now = strftime "%Y-%m-%d %T", gmtime($when);

  eval {
    for my $body (@{$star->{bodies}}) {
      $body->{body_id} = $body->{id};
      $body->{subtype} = $body->{image};
      $body->{subtype} =~ s/-\d+$//;
      $body->{empire}  ||= {};
      $body->{station} ||= {};
      $body->{empire_id}  = $body->{empire}{id};
      $body->{station_id} = $body->{station}{id};
      $debug > 1 && emit("Considering body $body->{name} at ($body->{x},$body->{y})");
      my $existing = $star_db->selectrow_arrayref("select body_id, strftime(\"%s\", last_checked) as last_epoch from orbitals where star_id = ? and x = ? and y = ?", {}, $star->{id}, $body->{x}, $body->{y});
      $debug > 1 && emit_json("checked", $existing);
      if ($existing && $existing->[1] < $when) {
        my $existing = $star_db->selectrow_hashref("select ".join(",", @ores, @attrs, "empire_id", "station_id")." from orbitals where x = ? and y = ?", {}, $body->{x}, $body->{y});
        if (grep { $existing->{$_} ne $body->{$_} && $existing->{$_} ne $body->{ore}{$_} } (@ores, @attrs, "empire_id", "station_id")) {
          emit("Updating body $body->{name} at ($body->{x},$body->{y})");
        }
        $debug > 2 and emit_json("Updating body $body->{name} at ($body->{x},$body->{y})", $body);
        eval {
          $star_db->do("update orbitals set ".join(", ", map { "$_ = ?" } (@ores, @attrs)).", empire_id = ?, station_id = ?, last_checked = ? where x = ? and y = ? and last_checked < ?", {},
                       (map { $body->{ore}{$_} } @ores), (map { $body->{$_} } @attrs), $body->{empire}{id}, $body->{station}{id}, $now, $body->{x}, $body->{y}, $now);
          1;
        } or emit($star_db->errstr);
      } elsif (!$existing) {
        emit("Inserting body $body->{name} at ($body->{x},$body->{y})");
        eval {
          $star_db->do("insert into orbitals (".join(", ", @ores, @attrs, qw(empire_id station_id last_checked)).") values (".join(", ", map { "?" } (@ores, @attrs), qw(? ? ?)).")", {},
                       (map { $body->{ore}{$_} } @ores), (map { $body->{$_} } @attrs), $body->{empire}{id}, $body->{station}{id}, $now);
          1;
        } or emit($star_db->err);
      }
    }
    my $existing = $star_db->selectrow_hashref("select id, name, color, zone from stars where x = ? and y = ?", {}, $star->{x}, $star->{y});
    if (grep { $existing->{$_} ne $star->{$_} } qw(id name color zone)) {
      emit("Updating star $star->{name} at ($star->{x},$star->{y})");
    }
    eval {
      $star_db->do("update stars set id = ?, name = ?, color = ?, zone = ?, last_checked = ? where x = ? and y = ? and last_checked < ?", {},
                   $star->{id}, $star->{name}, $star->{color}, $star->{zone}, $now, $star->{x}, $star->{y}, $now);
    } or emit($star_db->err);
    1;
  } or emit("SQL error: ".$star_db->errstr);
}

sub check_keeper {
  my $star = shift;

  my @colonies = map { $client->body_status($_) } keys %$planets;
  my @excavators = db_get_excavators();

  for my $body (@colonies) {
    return 1 if dist2($body, $star) <= $keep_distance * $keep_distance;
  }
  for my $body (@excavators) {
    return 1 if $body->{star_id} eq $star->{id};
  }
  return 0;
}

sub db_get_excavators {
  my $search = $star_db->selectall_arrayref(q(
    select star_id, body_id, name, x, y
    from orbitals
    where excavated_by is not null
  ), { Slice => {} });
  return @$search;
}

sub db_find_target {
  my $body_id = shift;

  my $sth = $star_db->prepare(q(
    select (stars.x - ?) * (stars.x - ?) + (stars.y - ?) * (stars.y - ?) as dist2, id, stars.name, stars.x, stars.y
    from stars left join orbitals on id = star_id
    where body_id is null or stars.last_checked < ?
    order by 1
  ));
  my $body = $client->body_status($body_id);
  my $recheck_time = strftime "%Y-%m-%d %T", gmtime(time() - $recheck_frequency);
  $sth->execute($body->{x}, $body->{x}, $body->{y}, $body->{y}, $recheck_time);
  my $target;
  while ($target = $sth->fetchrow_hashref) {
    last unless $claimed{$target->{id}};
  }
  $sth->finish;
  return $target;
}

sub ship_build {
  my ($body_id, $type, $quantity, $max_time) = @_;
  $max_time ||= 30 * 24 * 60 * 60;

  my @yards = $client->find_building($body_id, "Shipyard");
  $_->{buildable} = $client->yard_buildable($_->{id}) for @yards;
  for my $yard (@yards) {
    $yard->{work}{seconds_remaining} = Client::parse_time($yard->{work}{end}) - time() if $yard->{work}{end};
    $debug && emit("Shipyard $yard->{id} working for $yard->{work}{seconds_remaining} seconds", $body_id);
  }
  for (1..$quantity) {
    my $yard = (sort { ($a->{work}{seconds_remaining} + $a->{buildable}{buildable}{$type}{cost}{seconds}) <=>
                       ($b->{work}{seconds_remaining} + $b->{buildable}{buildable}{$type}{cost}{seconds}) } @yards)[0];
    if ($yard->{work}{seconds_remaining} < $max_time) {
      $yard->{additional}++;
      $yard->{work}{seconds_remaining} += $yard->{buildable}{buildable}{$type}{cost}{seconds};
    }
  }
  for my $yard (@yards) {
    if ($yard->{additional}) {
      eval {
        $noaction or $client->yard_build($yard->{id}, $type, $yard->{additional});
        emit("Building $yard->{additional} ${type}s in yard at ($yard->{x},$yard->{y})", $body_id);
        1;
      } or eval {
        $noaction or $client->yard_build($yard->{id}, $type, 1);
        emit("Building 1 ${type} in yard at ($yard->{x},$yard->{y})", $body_id);
        1;
      } or emit("Couldn't build ${type}s: $@", $body_id);
    }
  }
}

sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." explorer: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
