#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;
use List::Util qw(min max sum);

my $config_name = "config.json";
my $max_plots = 70 + 30; # Max habitable size + max Pantheon

GetOptions(
  "config=s" => \$config_name,
  "plots=i"  => \$max_plots,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %foods = (
  "Planetary Command Center",  ["algae"],

  "Malcud Fungus Farm",        ["fungus"],
  "Malcud Burger Packer",      ["burger"],
  "Algae Cropper",             ["algae"],
  "Algae Syrup Bottler",       ["syrup"],
  "Amalgus Bean Plantation",   ["bean"],
  "Amalgus Bean Soup Cannery", ["soup"],
  "Potato Patch",              ["potato"],
  "Potato Pancake Factory",    ["pancake"],
  "Denton Root Patch",         ["root"],
  "Denton Root Chip Frier",    ["chip"],
  "Corn Plantation",           ["corn"],
  "Corn Meal Grinder",         ["meal"],
  "Wheat Farm",                ["wheat"],
  "Bread Bakery",              ["bread"],
  "Beeldeban Herder",          ["beetle"],
  "Beeldeban Protein Shake Factory", ["shake"],
  "Apple Orchard",             ["apple"],
  "Apple Cider Bottler",       ["cider"],
  "Lapis Orchard",             ["lapis"],
  "Lapis Pie Bakery",          ["pie"],
  "Dairy Farm",                ["milk"],
  "Cheese Maker",              ["cheese"],

  "Algae Pond",                ["algae"],
  "Malcud Field",              ["fungus"],
  "Beeldeban Nest",            ["beetle"],
  "Lapis Forest",              ["lapis"],
  "Denton Brambles",           ["root"],
  "Amalgus Meadow",            ["bean"],

  "Lost City of Tyleon (A)",   [qw(burger syrup soup chip shake pie)],

  "Lake",                      ["algae"],
  "Lagoon",                    ["algae"],
);

my %samples;
my %stats;
my %best;

for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  my $buildings = $client->body_buildings($body_id);
  print "$planets->{$body_id}: orbit $buildings->{status}{body}{orbit}, net $buildings->{status}{body}{food_hour} food/hr\n";
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  for my $building (@buildings) {
    $samples{$building->{name}} ||= [];
    push(@{$samples{$building->{name}}}, $building);
  }
}

for my $name (sort keys %samples) {
  $samples{$name} = (sort { $a->{id} <=> $b->{id} } @{$samples{$name}})[0];
  my $building = $samples{$name};
  
  my $stats = $client->building_stats_for_level($building->{url}, $building->{id}, 30)->{building};
  if ($stats->{food_hour} > 100) {
    printf("%10d %s\n", $stats->{food_hour}, $name);
    $stats{$name}[30] = $stats;
    if ($foods{$name}) {
      my $amount = $stats->{food_hour} / @{$foods{$name}};
      for my $food (@{$foods{$name}}) {
        if ($best{$food}{amount} < $amount) {
          $best{$food} = { name => $name, amount => $amount };
        }
      }
    } else {
      print "Unknown food type for $name\n";
    }
    for my $level (1..29) {
      $stats = $client->building_stats_for_level($building->{url}, $building->{id}, $level)->{building};
      $stats{$name}[$level] = $stats;
    }
  }
}

for my $food (sort keys %best) {
  printf("%10d %-10s %s\n", $best{$food}{amount}, $food, $best{$food}{name});
}

my @necessary = (
  "Development Ministry",
  "Oversight Ministry",

  "Embassy",
  "Trade Ministry",

  "Observatory",
  "Archaeology Ministry",

  "Subspace Transporter",
  "Space Port",
  "Shipyard",

  "Lost City of Tyleon (A)",
  "Lost City of Tyleon (B)",
  "Lost City of Tyleon (C)",
  "Lost City of Tyleon (D)",
  "Lost City of Tyleon (E)",
  "Lost City of Tyleon (F)",
  "Lost City of Tyleon (G)",
  "Lost City of Tyleon (H)",
  "Lost City of Tyleon (I)",
);

my %singleton = (
  "Planetary Command Center" => 1,
  "Algae Pond" => 1,
  "Amalgus Meadow" => 1,
  "Beeldeban Nest" => 1,
  "Malcud Field" => 1,
  "Lapis Forest" => 1,
  "Denton Brambles" => 1,

  "Pyramid Junk Sculpture" => 1,
  "Kalavian Ruins" => 1,

  "Natural Spring" => 1,
  "Volcano" => 1,
  "Geo Thermal Vent" => 1,

  "Pantheon of Hagness" => 1,
  "Interdimensional Rift" => 1,
  "Ravine" => 1,

  "Black Hole Generator" => 1,

  "Terraforming Platform1" => 1,
  "Terraforming Platform2" => 1,
  "Terraforming Platform3" => 1,
  "Terraforming Platform4" => 1,
);

my @buildings = map { { name => $_, level => 1 } } (@necessary, keys %singleton);

sub plots {
  my @list = grep { !$singleton{$_->{name}} } @_;
  # @list + 9; # Add in LCOT cost
}

sub amounts {
  my @list = @_;
  my %amounts = map { $_ => 0 } keys %best;
  for my $building (@list) {
    next unless $foods{$building->{name}};
    my @foods = @{$foods{$building->{name}}};
    next unless @foods;
    my $amount = $stats{$building->{name}}[$building->{level}]{food_hour} / @foods;
    for my $food (@foods) {
      $amounts{$food} += $amount;
    }
  }
  %amounts;
}

sub fill {
  my @buildings = @_;

  my %amounts = amounts(@buildings);
  my $max = max(values(%amounts));

  my $pos = 0;
  while ($pos < @buildings) {
    if ($buildings[$pos]{level} >= ($singleton{$buildings[$pos]{name}} ? 30 : 20) ||
        !$foods{$buildings[$pos]{name}} || !@{$foods{$buildings[$pos]{name}}}) {
      $pos++;
      next;
    }
    my @grow = @buildings;
    $grow[$pos] = { name => $grow[$pos]{name}, level => $grow[$pos]{level} + 1 };
    my %grow = amounts(@grow);
    if (max(values(%grow)) <= $max) {
      print "Levelling $grow[$pos]{name} to $grow[$pos]{level}\n";
      @buildings = @grow;
    } else {
      $pos++;
    }
  }

  return @buildings;
}

sub increase {
  my $food = shift;
  my @buildings = @_;

  for my $pos (0..$#buildings) {
    next unless $best{$food}{name} eq $buildings[$pos]{name};
    next if $buildings[$pos]{level} >= ($singleton{$buildings[$pos]{name}} ? 30 : 20);
    $buildings[$pos] = { name => $buildings[$pos]{name}, level => $buildings[$pos]{level} + 1 };
    return @buildings;
  }
  for my $pos (0..$#buildings) {
    next unless grep { $food eq $_ } @{$foods{$buildings[$pos]{name}}};
    next if $buildings[$pos]{level} >= ($singleton{$buildings[$pos]{name}} ? 30 : 20);
    $buildings[$pos] = { name => $buildings[$pos]{name}, level => $buildings[$pos]{level} + 1 };
    return @buildings;
  }

  if (!$singleton{$best{$food}{name}} && @buildings < 121 && plots(@buildings) < $max_plots) {
    return (@buildings, { name => $best{$food}{name}, level => 1 });
  }

  print "Couldn't increase $food\n";

  @buildings = fill(@buildings);

  print "\n";
  my %amounts = amounts(@buildings);
  for my $food (sort keys %amounts) {
    printf("%10d %s\n", $amounts{$food}, $food);
  }
  
  print "\n";
  my %types;
  for my $building (@buildings) {
    $types{$building->{name}}{$building->{level}}++;
  }
  for my $type (sort keys %types) {
    printf("%-25s %s\n", $type, join(" ", map { $types{$type}{$_}."x".$_ } reverse sort keys %{$types{$type}}));
  }

  print "\nUsing ".scalar(@buildings)." spaces and ".plots(@buildings)." plots.\n";
  exit(0);
}

for (;;) {
  my %amounts = amounts(@buildings);
  my $lowest = (sort { $amounts{$a} <=> $amounts{$b} } keys %amounts)[0];
  my $old = $amounts{$lowest};
  @buildings = increase($lowest, @buildings);
  %amounts = amounts(@buildings);
  print "Increasing $lowest from $old to $amounts{$lowest}\n";
}
