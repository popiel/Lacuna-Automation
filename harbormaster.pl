#!/usr/bin/perl

use strict;
use warnings;

use Client;
use Getopt::Long;
use JSON::PP;
use List::Util qw(min max sum first);

my $config_name = "config.json";
my @body_name;
my $yard_name;

GetOptions(
  "config=s" => \$config_name,
  "body=s" => \@body_name,
  "yard=s" => \$yard_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my $yard_planet = $yard_name ? $client->match_planet($yard_name) : $client->empire_status->{home_planet_id};
my $trade = $client->find_building($yard_planet, "Trade Ministry");
my $yard  = $client->find_building($yard_planet, "Shipyard");
my @yards = grep { $_->{level} == $yard->{level} } $client->find_building($yard_planet, "Shipyard");
my @ships_wanted;

my $buildable = $client->yard_buildable($yard->{id});
my @buildable = sort grep { $buildable->{buildable}{$_}{can} } keys(%{$buildable->{buildable}});
print "Can build: ".join(" ", @buildable)."\n";
my $galleon  = $buildable->{buildable}{galleon};
my $hulk     = $buildable->{buildable}{hulk_huge};
my $smuggler = $buildable->{buildable}{smuggler_ship};

# my @unbuildable = sort grep { !$buildable->{buildable}{$_}{can} } keys(%{$buildable->{buildable}});
# for my $name (@unbuildable) {
#   printf("%-26s: %s\n", $buildable->{buildable}{$name}{type_human}, $buildable->{buildable}{$name}{reason}[1]);
# }

my @build_ships = map { { type => $_, %{$buildable->{buildable}{$_}} } } keys(%{$buildable->{buildable}});

my @supply_ships = sort { $b->{attributes}{berth_level} <=> $a->{attributes}{berth_level} }
                   grep { grep { $_ eq "SupplyChain" } @{$_->{tags}} } @build_ships;
my @waste_ships  = sort { $b->{attributes}{berth_level} <=> $a->{attributes}{berth_level} }
                   grep { grep { $_ eq "WasteChain"  } @{$_->{tags}} } @build_ships;
my %ship_tags;
for my $ship (@build_ships) {
  $ship_tags{$ship->{type}} = { map { $_ => 1} @{$ship->{tags}} };
}

# for my $name (qw(smuggler_ship galleon hulk_huge scow scow_fast scow_large scow_mega)) {
# for my $name (@buildable) {
#  my $ship = $buildable->{buildable}{$name};
for my $ship (@supply_ships, @waste_ships) {
  if ($ship->{can}) {
    printf("%-26s berth %2d  speed %5d  stealth %5d  combat %5d  hold %9d\n",
           $ship->{type_human},
           @{$ship->{attributes}}{qw(berth_level speed stealth combat hold_size)});
  } else {
    printf("%-26s: %s\n", $ship->{type_human}, $ship->{reason}[1]);
  }
}

for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  next unless !@body_name || grep { $planets->{$body_id} =~ /$_/ } @body_name;

  my $local_trade = eval { $client->find_building($body_id, "Trade Ministry") };
  next unless $local_trade;
  my $port = eval { $client->find_building($body_id, "Space Port") };
  next unless $port;
  my $slots = 2 * List::Util::sum(map $_->{level}, $client->find_building($body_id, "Space Port"));
  my @ships = @{$client->port_all_ships($port->{id})->{ships}};

  # Ensure enough scows in waste chain to handle total waste output + 10%
  my $waste_rate = $client->body_status($body_id)->{waste_hour};
  my $waste_chain = $client->body_waste_chain($body_id)->{waste_chain}[0];
  if ($waste_chain->{percent_transferred} >= 100) {
    $waste_rate += $waste_chain->{waste_hour};
  } else {
    $waste_rate += $waste_chain->{waste_hour} * $waste_chain->{percent_transferred} / 100;
  }
  my $best_waste = first { $_->{attributes}{berth_level} <= $port->{level} } @waste_ships;
  my $best_haul = $best_waste->{attributes}{hold_size} * $best_waste->{attributes}{speed} / sqrt(3) / 2000;
  my $num_ships = int(($waste_rate * 1.1 + $best_haul - 1) / $best_haul);
  printf("Base waste production rate %d/hr.  Best ship is %s, can haul %d/hr.  Want %d waste ships.\n",
         $waste_rate, $best_waste->{type_human}, $best_haul, $num_ships);

  my @waste = is_waste_ship(@ships);
  my @obsolete = grep { $_->{type} ne $best_waste->{type} || is_obsolete($_) } @waste;
  printf("Detected %d obsolete waste ships on %s.\n", scalar(@obsolete), $planets->{$body_id}) if @obsolete;
  for my $ship (@obsolete) {
    printf("%-26s berth %2d  speed %5d  stealth %5d  combat %5d  hold %9d\n",
           $ship->{type_human},
           @{$ship}{qw(berth_level speed stealth combat hold_size)});
  }
  my @current = grep { $_->{type} eq $best_waste->{type} && !is_obsolete($_) } @waste;
  my $haul = sum(0, map { $_->{hold_size} * $_->{speed} } @current) / sqrt(3) / 2000;
  printf("Current waste ships can haul %d/hr on %s.\n", $haul, $planets->{$body_id});
  if (@current < $num_ships) {
    push(@ships_wanted, { body => $body_id, type => $best_waste->{type}, count => $num_ships - @current });
  }

  # Ensure at least 2 unassigned galleons
  # Ensure sufficient hulks in supply chain for 110%
  # Ensure 2 drones
  # Ensure 2-10 excavators
}

sub is_tagged_ship {
  my $tag  = shift;
  (wantarray ? grep { $ship_tags{$_->{type}}{$tag} } @_ : $ship_tags{$_[0]->{type}}{$tag})
}

sub is_waste_ship {
  (wantarray ? (is_tagged_ship("WasteChain", @_),) : scalar(is_tagged_ship("WasteChain", @_)))
}

sub is_obsolete {
  my $ship = shift;
  my $ideal = $buildable->{buildable}{$ship->{type}};
  return 0 unless $ideal->{can};
  for my $attr (qw(speed stealth combat hold_size)) {
    return 1 if $ship->{$attr} < $ideal->{attributes}{$attr};
  }
  return 0;
}
