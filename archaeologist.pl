#!/usr/bin/perl

# For simple usage, you don't need to pass any arguments to the script,
# and run it once per day.  (You should have your empire's connection
# info in a file named "config.json", with contents similar to the
# "config.json.template" file.)
#
# I personally run the script once per hour, with the arguments
# "-build=1hour".  This makes it respond a bit quicker to excavators
# that disappear, and also not block up your shipyards quite as much when
# replacing excavators.
#
# The script checks each of your planets, to see if any are below their
# excavator limits.  If there is a shortfall, it sends any available
# excavators to selected bodies, and then builds additional excavators
# if there aren't enough on hand.
#
# Body selection for excavation is greedy based on current knowledge.
# The script looks at all the planet types you have near you (within the
# specified max_distance), uses whichever types best balance the ore
# distribution (possibly modified by the bias command-line argument).
#
# If you want to have the script try to balance glyph production for a
# small group of planets instead of your entire empire, then you can use
# the "-body=ColonyN" argument (possibly multiple times) to specify which
# planet(s) you want it to consider.  If you do that, you'll probably
# want multiple invocations of the script with different planet lists,
# to cover all your planets.
#
# If you've named your star database something other than "stars.db",
# then you can use the "-db=foo.db" argument to specify a different name.

use strict;

use Carp;
use Client;
use DBI;
use Getopt::Long;
use IO::Handle;
use Data::Dumper;
use JSON::XS;
use List::Util qw(min max sum first reduce);
use File::Path;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $db_file = "stars.db";
my $max_build_time = 86400;
my $max_distance = 100;
my @bias;
my $greedy = 0;
my $optimize = 1;
my $avoid_populated = 0;
my $noaction = 0;
my $purge = 0;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"                    => \$config_name,
  "body|planet|b=s"             => \@body_names,
  "db=s"                        => \$db_file,
  "max_build_time|build|fill=s" => \$max_build_time,
  "max_distance|distance=i"     => \$max_distance,
  "bias=s"                      => \@bias,
  "greedy!"                     => \$greedy,
  "optimize!"                   => \$optimize,
  "avoid_populated!"            => \$avoid_populated,
  "noaction|dryrun|n!"          => \$noaction,
  "purge!"                      => \$purge,
  "debug|d+"                    => \$debug,
  "quiet"                       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};

$max_build_time = $1         if $max_build_time =~ /^(\d+) ?s(econds?)?$/;
$max_build_time = $1 * 60    if $max_build_time =~ /^(\d+) ?m(inutes?)?$/;
$max_build_time = $1 * 3600  if $max_build_time =~ /^(\d+) ?h(ours?)?$/;
$max_build_time = $1 * 86400 if $max_build_time =~ /^(\d+) ?d(ays?)?$/;

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
my %arches = map { ($_, scalar(eval { $client->find_building($_, "Archaeology Ministry") } )) } @body_ids;
my %ports  = map { ($_, scalar(eval { $client->find_building($_, "Space Port"          ) } )) } @body_ids;
my %yards  = map { ($_, scalar(eval { $client->find_building($_, "Shipyard"            ) } )) } @body_ids;

# Filter down to just those bodies with archaeology ministries, spaceports, and shipyards
my @body_ids = grep { ref($arches{$_}) eq 'HASH' && ref($ports{$_}) eq 'HASH' && ref($yards{$_}) eq 'HASH' } @body_ids;
$debug > 1 && emit_json("Pruned body_ids", \@body_ids);
$debug > 1 && emit_json("Archaeology Ministries", \%arches);
my %excavators = map { ($_, $client->call(archaeology => view_excavators => $arches{$_}{id})) } @body_ids;
$debug > 1 && emit_json("Excavators", \%excavators);

my $possible = 0;
my $active = 0;
my %ores;
my @ores;
my %active;
for my $body_id (@body_ids) {
  db_clear_excavated_by($body_id);
  $possible += $excavators{$body_id}{max_excavators};
  $active--;
  $active{$body_id}--;
  for my $excavator (@{$excavators{$body_id}{excavators}}) {
    db_set_excavated_by($body_id, $excavator->{body}{id});
    $active++;
    $active{$body_id}++;
    for my $ore (keys(%{$excavator->{body}{ore}})) {
      $ores{$ore} += $excavator->{body}{ore}{$ore};
    }
  }
  @ores = sort keys %ores;
  my $port = $client->find_building($body_id, "Space Port");
  my $ships = $client->port_all_ships($body_id);
  my @excavators = grep { $_->{type} eq "excavator" } @{$ships->{ships}};
  my @travelling = grep { $_->{task} eq "Travelling" } @excavators;
  for my $excavator (@travelling) {
    db_set_excavated_by($body_id, $excavator->{to}{id});
    $excavator->{body}{ore} = db_lookup_ores($excavator->{to}{id});
    $active++;
    $active{$body_id}++;
    for my $ore (keys(%{$excavator->{body}{ore}})) {
      $ores{$ore} += $excavator->{body}{ore}{$ore};
    }
  }
}

my %bias = map { ($_, 1) } @ores;
if (@bias) {
  @bias = map { split(",", $_) } @bias;
  for my $b (@bias) {
    my ($ore,$amount) = split("=", $b);
    $bias{$ore} or die "Unrecognized ore '$ore' in bias list\n";
    $amount = 0.0001 if $amount == 0;
    $bias{$ore} = $amount;
  }
  my %backup = %ores;
  %ores = %bias;
  dump_densities("Bias");
  %ores = %backup;
}

dump_densities("Starting");

sub find_value {
  my ($addition) = shift;
  my %weighted = map { ($_, ($ores{$_} + $addition->{$_}) / $bias{$_}) } @ores;
  return min(values %weighted);
}

for my $body_id (@body_ids) {
  my $wanted = $excavators{$body_id}{max_excavators} - $active{$body_id};
  next if $wanted < 1;

  my $ships = $client->port_all_ships($body_id);
  my @excavators = grep { $_->{type} eq "excavator" } @{$ships->{ships}};
  my @ready = grep { $_->{task} eq "Docked" } @excavators;

  my $status = $client->body_status($body_id);
  while (@ready && $wanted) {
    my @planet_types = map {
      my @density = @$_;
      my %density = map { ($ores[$_], $density[$_]) } (0..$#ores);
      $density{subtype} = $density[$#density];
      \%density
    } db_find_body_types($status->{x}, $status->{y}, $max_distance * $max_distance);
    emit_json("Types:", [ @planet_types ]);
    my %values = map { ($_, find_value($_)) } @planet_types;
    my $best_type = reduce { $values{$a} < $values{$b} ? $b : $a } @planet_types;
    emit_json("Values for types:", [ map { ($_->{subtype}, $values{$_}) } @planet_types ]);
    my $target = db_find_body($best_type->{subtype}, $status->{x}, $status->{y});

    if ($target) {
      if (($target->{x} - $status->{x}) * ($target->{x} - $status->{x}) +
          ($target->{y} - $status->{y}) * ($target->{y} - $status->{y}) > $max_distance * $max_distance) {
        emit("Closest $best_type->{subtype} body $target->{name} at ($target->{x},$target->{y}) is too far away: ".
             sqrt(($target->{x} - $status->{x}) * ($target->{x} - $status->{x}) + 
                  ($target->{y} - $status->{y}) * ($target->{y} - $status->{y})),
             $body_id);
        last;
      } else {
        db_set_excavated_by($body_id, $target->{body_id});
        eval {
          $noaction or $client->send_ship($ready[0]{id}, { body_id => $target->{body_id} });
          emit("Sending excavator to $best_type->{subtype}: $target->{name} at ($target->{x},$target->{y})", $body_id);
          1;
        } or emit("Couldn't send excavator to $target->{name}: $@", $body_id);
        $ores{$_} += $best_type->{$_} for @ores;
        shift(@ready);
      }
    } else {
      last;
    }
  }

  if ($wanted) {
    my @yards = $client->find_building($body_id, "Shipyard");
    $_->{buildable} = $client->yard_buildable($_->{id}) for @yards;
    for my $yard (@yards) {
      $yard->{work}{seconds_remaining} = Client::parse_time($yard->{work}{end}) - time() if $yard->{work}{end};
      $debug && emit("Shipyard $yard->{id} working for $yard->{work}{seconds_remaining} seconds", $body_id);
    }
    for (1..$wanted) {
      my $yard = (sort { ($a->{work}{seconds_remaining} + $a->{buildable}{buildable}{excavator}{cost}{seconds}) <=>
                         ($b->{work}{seconds_remaining} + $b->{buildable}{buildable}{excavator}{cost}{seconds}) } @yards)[0];
      if ($yard->{work}{seconds_remaining} < $max_build_time) {
        $yard->{additional}++;
        $yard->{work}{seconds_remaining} += $yard->{buildable}{buildable}{excavator}{cost}{seconds};
      }
    }
    for my $yard (@yards) {
      if ($yard->{additional}) {
        eval {
          $noaction or $client->yard_build($yard->{id}, "excavator", $yard->{additional});
          emit("Building $yard->{additional} excavators", $body_id);
          1;
        } or eval {
          $noaction or $client->yard_build($yard->{id}, "excavator", 1);
          emit("Building 1 excavator", $body_id);
          1;
        } or emit("Couldn't build excavators: $@", $body_id);
      }
    }
  }
}

dump_densities("Finished");

sub dump_densities {
  my $label = shift;

  emit(join("\n", "$label ore densities:",
            map { sprintf("%6d %-13s%6d %-13s%6d %-13s%6d %-13s",
                          $ores{$ores[$_]}, $ores[$_],
                          $ores{$ores[$_ + 5]}, $ores[$_ + 5],
                          $ores{$ores[$_ + 10]}, $ores[$_ + 10],
                          $ores{$ores[$_ + 15]}, $ores[$_ + 15]) } (0..4)));
  my $min = min(values %ores);
  my $median = (sort { $a <=> $b } values %ores)[@ores / 2];
  my $sum = sum(values %ores);
  emit("Minimum $min, median $median, total $sum");
}

sub db_find_body_types {
  my ($x, $y, $max) = @_;
  my @result;
  my $ores = join(",", map { "o.$_" } @ores);
  my $query = $star_db->prepare(qq(
    select $ores, o.subtype from orbitals o
    left join (
      select star_id from orbitals
      where empire_id is not null and empire_id <> ?
    ) s on (o.star_id = s.star_id)
    where o.empire_id is null and o.excavated_by is null and s.star_id is null
      and (o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?) < ?
    group by $ores, o.subtype
  ));
  my $rv = $query->execute($client->empire_status->{id}, $x, $x, $y, $y, $max);
  for (;;) {
    my $row = $query->fetchrow_arrayref;
    last unless $row;
    push(@result, [ @$row ]);
  }
  return @result;
}

sub db_find_bodies {
  my ($x, $y, $max) = @_;
  my @result;
  my $ores = join(",", map { "o.$_" } @ores);
  my $query = $star_db->prepare(qq(
    select o.body_id, o.name, o.x, o.y, o.subtype, $ores from orbitals o
    left join (
      select star_id from orbitals
      where empire_id is not null and empire_id <> ?
    ) s on (o.star_id = s.star_id)
    where o.empire_id is null and o.excavated_by is null and s.star_id is null
      and (o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?) < ?
    order by (o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?)
  ));
  my $rv = $query->execute($client->empire_status->{id}, $x, $x, $y, $y, $max, $x, $x, $y, $y);
  for (;;) {
    my $row = $query->fetchrow_hashref;
    last unless $row;
    push(@result, $row);
  }
  return @result;
}

sub db_find_body {
  my ($subtype, $x, $y) = @_;
  my $result;
  if ($avoid_populated) {
    $result = $star_db->selectrow_hashref(qq(
      select o.body_id, o.name, o.x, o.y from orbitals o
      left join (
        select star_id from orbitals
        where empire_id is not null and empire_id <> ?
      ) s on (o.star_id = s.star_id)
      where o.subtype = ? and o.empire_id is null and o.excavated_by is null and s.star_id is null
      order by (o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?)
      limit 1
    ), {}, $client->empire_status->{id}, $subtype, $x, $x, $y, $y);
  } else {
    $result = $star_db->selectrow_hashref(qq(
      select body_id, name, x, y from orbitals
      where subtype = ? and empire_id is null and excavated_by is null
      order by (x - ?) * (x - ?) + (y - ?) * (y - ?)
      limit 1
    ), {}, $subtype, $x, $x, $y, $y);
    if ($debug > 1) {
      emit_json("Find body: select body_id, name, x, y from orbitals where subtype = '$subtype' and empire_id is null and excavated_by is null order by (x - $x) * (x - $x) + (y - $y) * (y - $y) limit 3", $result);
    }
  }
  return $result;
}

sub db_lookup_ores {
  my ($body_id) = @_;
  my $result = $star_db->selectrow_hashref("select ".join(",", @ores)." from orbitals where body_id = ?", {}, $body_id);
  if ($debug > 1) {
    emit_json("Lookup ores: select ".join(",", @ores)." from orbitals where body_id = $body_id", $result);
  }
  return $result;
}

sub db_clear_excavated_by {
  my ($body_id) = @_;
  my $result = $star_db->do('update orbitals set excavated_by = null where excavated_by = ?', {}, $body_id);
  if ($debug > 1) {
    emit_json("Clear excavated_by: update orbitals set excavated_by = null where excavated_by = $body_id", $result);
  }
  return $result;
}

sub db_set_excavated_by {
  my ($body_id, $target_id) = @_;
  my $result = $star_db->do('update orbitals set excavated_by = ? where body_id = ?', {}, $body_id, $target_id);
  if ($debug > 1) {
    emit_json("Set excavated_by: update orbitals set excavated_by = $body_id where body_id = $target_id", $result);
  }
  return $result;
}

sub type_string {
  my %density = (ref($_[0]) ? %{$_[0]} : @_);
  return $density{subtype}." ".join(':', map { $density{$_} } @ores);
}

sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." archaeologist: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
