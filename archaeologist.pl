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

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $db_file = "stars.db";
my $max_build_time = 86400;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"  => \$config_name,
  "body=s"    => \@body_names,
  "db=s"      => \$db_file,
  "max_build_time|fill=s" => \$max_build_time,
  "debug"     => \$debug,
  "quiet"     => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

$max_build_time = $1         if $max_build_time =~ /^(\d+) ?s(econds?)?$/;
$max_build_time = $1 * 60    if $max_build_time =~ /^(\d+) ?m(inutes?)?$/;
$max_build_time = $1 * 3600  if $max_build_time =~ /^(\d+) ?h(ours?)?$/;
$max_build_time = $1 * 86400 if $max_build_time =~ /^(\d+) ?d(ays?)?$/;

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

my $client = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};

my $planets = $client->empire_status->{planets};

@body_names = values(%$planets) unless @body_names;
my @body_ids = map { $client->match_planet($_) } @body_names;
if ((@body_ids != @body_names)) {
  emit("Aborting due to identification errors", $empire_name);
  exit 1;
}
@body_names = map { $planets->{$_} } @body_ids;

my %arches = map { ($_, $client->find_building($_, "Archaeology Ministry")) } @body_ids;
emit_json("Archaeology Ministries", \%arches);
my %excavators = map { ($_, $client->call(archaeology => view_excavators => $arches{$_}{id})) } @body_ids;
emit_json("Excavators", \%excavators);

my $possible = 0;
my $active = 0;
my %ores;
for my $body_id (@body_ids) {
  $star_db->do('update orbitals set excavated_by = null where excavated_by = ?', {}, $body_id);
  $possible += $excavators{$body_id}{max_excavators};
  $active--;
  for my $excavator (@{$excavators{$body_id}{excavators}}) {
    $star_db->do('update orbitals set excavated_by = ? where body_id = ?', {}, $body_id, $excavator->{body}{id});
    $active++;
    for my $ore (keys(%{$excavator->{body}{ore}})) {
      $ores{$ore} += $excavator->{body}{ore}{$ore};
    }
  }
}
my @ores = sort keys %ores;

emit(join("\n", "Total ore densities:",
          map { sprintf("%6d %-13s%6d %-13s%6d %-13s%6d %-13s",
                        $ores{$ores[$_]}, $ores[$_],
                        $ores{$ores[$_ + 5]}, $ores[$_ + 5],
                        $ores{$ores[$_ + 10]}, $ores[$_ + 10],
                        $ores{$ores[$_ + 15]}, $ores[$_ + 15]) } (0..4)));
emit("$active excavators active out of $possible excavators possible");

my @planet_types = map { my @density = split(/:/, $_); my %density = map { ($ores[$_], $density[$_]) } (0..$#ores); $density{subtype} = $density[$#density]; \%density } qw(
1000:1:1:1:1000:1000:1000:1000:1:1000:1:1000:1000:1:1:1:1:1:1000:1000:p11
1:1000:1000:1000:1:1:1:1:1000:1:1000:1:1:1000:1000:1000:1000:1000:1:1:p12
1:1:1000:1:1:9000:1:1:1:1:1:1:1:1:1:1:1:1:1:1:a1
1:1:4000:5000:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1000:a2
1:1:1:1:1:1:1:1:1:1:1:1:1:1:1000:1:1:1:1000:8000:a3
1:1:1:1:1:1:1:1:1000:1:1:1:1:1:9000:1:1:1:1:1:a4
1:1:1:1:1:1000:1:1:8500:1:1:1:1:1:1:1:1:1:1:1:a5
1:1:1:1:1:1:5790:1:1:1:1:40:1:1:1:1:1:1:1:1:a6
1:1:1:1:1:3291:1:1:1:1:1:1:1:1:1239:1:1:1:2377:1:a7
1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:7954:a8
6250:108:1:1:1:1:1:1:1:1:55:1:1:1:1:1:1:300:1:1:a10
1:1:1:1:1:1:1:1:1:1:1:1:9980:1:1:1:1:1:1:1:a11
289:269:313:299:320:307:278:292:310:311:301:284:296:285:319:258:324:293:276:275:a12
1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:6574:1:2590:a13
1:1:1:1:1:1:3038:2895:1:2897:1:1:1:1:1:1:1:1:1:1:a14
1:1:1:1:8931:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:a15
1:1894:1:1:1:1793:1:1:2132:1:1:1:1:1:1:1:1:2018:1:1:a16
1:1:4233:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:1:a17
1:1:1:1:1:1:1:1:1:4120:1:1:1:1:1:1:1:3326:1:1:a18
1:1:1:1:1:1:1:6342:1:1:1:1:1:1:1:1:1:1:1:1:a20
1:1:1:1:1:1:1:1:1:1:1:1:10:1:1:1:1:1:1:1:debris1
1:250:1:1000:5000:1:1500:500:500:250:250:1:1:1:1:500:1:1:250:1:p1
1:1:310:1:1:190:1:1:250:1500:1:1:1000:2700:130:1:2300:1500:1:120:p2
1700:1:1:1:1:1:1:1:1:1:1:1400:1:2900:1:1:1:1:3000:1000:p3
1:1:1:1000:1:1:1:1500:1:1500:1:1500:1500:1:1:1:1500:1:1500:1:p4
1:2250:1:250:1:1:2250:1250:1:1250:250:1:250:250:1:1250:250:250:250:1:p5
1:1:1:1:1:1:1:1400:1:1500:1000:1:1900:1200:1:1:1700:1300:1:1:p6
1:1700:1000:2800:1:1:1:2400:1:2100:1:1:1:1:1:1:1:1:1:1:p7
3100:1:1:1:1:1:1:1:1:1250:1300:3100:1:1:1:1:1:1250:1:1:p8
100:300:1:100:900:1:200:200:1:600:500:1800:100:1700:1:800:1600:700:400:1:p9
500:1:250:1:1:250:1:1000:1:500:1:500:5000:500:250:1:500:500:1:250:p10
1500:1:1:1300:1400:1:2200:1:1:1:1:1500:1:1:1:2100:1:1:1:1:p13
1:100:1:100:100:1:100:100:1:100:100:1:100:2700:1:100:2300:4000:100:1:p14
1:250:1:100:300:1:400:4500:1:500:500:1:2000:500:1:200:270:330:250:1:p15
3300:1:1:1:400:1:200:300:1:1:700:2700:1:1:1:600:100:900:800:1:p16
1:1:1:1:1:1:1:1:1:1:1:1:4200:1900:1:1:1:3900:1:1:p17
1:4200:1:1:3200:1:1:1:1:1:1:1:1:1:1:1:1:1:2600:1:p18
1100:300:1:700:100:1:200:700:1:700:400:1200:1400:600:1:700:700:500:700:1:p19
1:900:1:1:1400:1:3100:1:1:1:1:1:1800:1:1:2800:1:1:1:1:p20
);

# emit_json("planet_types", \@planet_types);

my @how;
for (1..($possible - $active)) {
  my $worst = (sort { $ores{$a} <=> $ores{$b} } @ores)[0];
  my $type = (sort { $b->{$worst} <=> $a->{$worst} } @planet_types)[0];
  $type = $planet_types[$_ % 2];
  push(@how, $type);
  $ores{$_} += $type->{$_} for @ores;
}

emit(join("\n", "First cut ore densities:",
          map { sprintf("%6d %-13s%6d %-13s%6d %-13s%6d %-13s",
                        $ores{$ores[$_]}, $ores[$_],
                        $ores{$ores[$_ + 5]}, $ores[$_ + 5],
                        $ores{$ores[$_ + 10]}, $ores[$_ + 10],
                        $ores{$ores[$_ + 15]}, $ores[$_ + 15]) } (0..4)));
emit(join("\n", "Using planet types:",
          map { type_string($_) } @how));

my $change;
do {
  $change = 0;
  my $min = min(values %ores);
  $debug && emit("Minimum ore value: $min ".join(", ", grep { $ores{$_} == $min } @ores));
  for my $j (0..$#how) {
    my %reduced = map { $_, $ores{$_} - $how[$j]{$_} } @ores;
    for my $type (@planet_types) {
      my %increased = map { $_, $reduced{$_} + $type->{$_} } @ores;
      my $worst = min(values %increased);
      $debug && emit("Yield $worst after replacing pos $j with ".type_string($type));
      if ($min < $worst) {
        $min = $worst;
        %ores = %increased;
        $how[$j] = $type;
        $change = 1;
        $debug && emit("KEEPER!");
      }
    }
  }
} while $change;

emit(join("\n", "Second cut ore densities:",
          map { sprintf("%6d %-13s%6d %-13s%6d %-13s%6d %-13s",
                        $ores{$ores[$_]}, $ores[$_],
                        $ores{$ores[$_ + 5]}, $ores[$_ + 5],
                        $ores{$ores[$_ + 10]}, $ores[$_ + 10],
                        $ores{$ores[$_ + 15]}, $ores[$_ + 15]) } (0..4)));
emit(join("\n", "Using planet types:",
          map { type_string($_) } @how));
my $min = min(values %ores);
my $median = (sort values %ores)[@ores / 2];
my $sum = sum(values %ores);
emit("Minimum $min, median $median, total $sum");

my $change;
do {
  $change = 0;
  my $min = min(values %ores);
  $debug && emit("Minimum ore value: $min ".join(", ", grep { $ores{$_} == $min } @ores));
  for my $j (0..$#how) {
    for my $k (($j + 1)..$#how) {
      my %reduced = map { $_, $ores{$_} - $how[$j]{$_} - $how[$k]{$_} } @ores;
      for my $type1 (@planet_types) {
        for my $type2 (@planet_types) {
          my %increased = map { $_, $reduced{$_} + $type1->{$_} + $type2->{$_} } @ores;
          my $worst = min(values %increased);
          $debug && emit("Yield $worst after replacing pos $j, $k with ".type_string($type1).", ".type_string($type2));
          if ($min < $worst) {
            $min = $worst;
            %ores = %increased;
            $how[$j] = $type1;
            $how[$k] = $type2;
            $change = 1;
            $debug && emit("KEEPER!");
          }
        }
      }
    }
  }
} while $change;

emit(join("\n", "Third cut ore densities:",
          map { sprintf("%6d %-13s%6d %-13s%6d %-13s%6d %-13s",
                        $ores{$ores[$_]}, $ores[$_],
                        $ores{$ores[$_ + 5]}, $ores[$_ + 5],
                        $ores{$ores[$_ + 10]}, $ores[$_ + 10],
                        $ores{$ores[$_ + 15]}, $ores[$_ + 15]) } (0..4)));
emit(join("\n", "Using planet types:",
          map { type_string($_) } @how));
my $min = min(values %ores);
my $median = (sort values %ores)[@ores / 2];
my $sum = sum(values %ores);
emit("Minimum $min, median $median, total $sum");

@how = reverse @how;

for my $body_id (@body_ids) {
  my $possible = $excavators{$body_id}{max_excavators};
  my $active = @{$excavators{$body_id}{excavators}} - 1;
  my $delta = $possible - $active;
  next unless $delta > 0;

  my $port = $client->find_building($body_id, "Space Port");
  my $ships = $client->port_all_ships($port->{id});
  my @excavators = grep { $_->{type} eq "excavator" } @{$ships->{ships}};
  my @ready = grep { $_->{task} eq "Docked" } @excavators;

  if (@excavators < $delta) {
    my @yards = $client->find_building($body_id, "Shipyard");
    $_->{buildable} = $client->yard_buildable($_->{id}) for @yards;
    for my $yard (@yards) {
      $yard->{work}{seconds_remaining} = Client::parse_time($yard->{work}{end}) - time() if $yard->{work}{end};
    }
    for (1..$delta) {
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
          $client->yard_build($yard->{id}, "excavator", $yard->{additional});
          emit("Building $yard->{additional} excavators", $body_id);
          1;
        } or emit("Couldn't build excavators: $@", $body_id);
      }
    }
  }

  my $status = $client->body_status($body_id);

  for my $ship (@ready) {
    my ($target_id, $name, $x, $y) = $star_db->selectrow_array(qq(
      select body_id, name, x, y from orbitals
      where subtype = ? and empire_id is null and excavated_by is null
      order by (x - ?) * (x - ?) + (y - ?) * (y - ?)
      limit 1
    ), {}, $how[0]{subtype}, $status->{x}, $status->{x}, $status->{y}, $status->{y});
    if ($target_id) {
      $star_db->do(qq(update orbitals set excavated_by = ? where body_id = ?), {}, $body_id, $target_id);
      eval {
        $client->send_ship($ship->{id}, { body_id => $target_id });
        emit("Sending excavator to $name at ($x,$y)", $body_id);
        1;
      } or emit("Couldn't send excavator to $name: $@", $body_id);
      shift(@how);
    } else {
      emit("Cannot find available instance of body subtype $how[0]{subtype}", $body_id);
    }
  }
}

sub type_string {
  my %density = (ref($_[0]) ? %$_ : @_);
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
