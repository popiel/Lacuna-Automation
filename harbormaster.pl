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

sub base_waste_rate {
  my $body_id = shift;

  my $waste_rate = $client->body_status($body_id)->{waste_hour};
  my $waste_chain = $client->body_waste_chain($body_id)->{waste_chain}[0];
  if ($waste_chain->{percent_transferred} >= 100) {
    $waste_rate += $waste_chain->{waste_hour};
  } else {
    $waste_rate += $waste_chain->{waste_hour} * $waste_chain->{percent_transferred} / 100;
  }
  $waste_rate;
}

my %returns;
my %requests;

my @body_ids = ();
for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  next unless !@body_name || grep { $planets->{$body_id} =~ /$_/ } @body_name;
  my $local_trade = eval { $client->find_building($body_id, "Trade Ministry") };
  next unless $local_trade;
  my $port = eval { $client->find_building($body_id, "Space Port") };
  next unless $port;
  push(@body_ids, $body_id);
}

for my $body_id (@body_ids) {
  my $slots = 2 * List::Util::sum(map $_->{level}, $client->find_building($body_id, "Space Port"));
  my @ships = @{$client->port_all_ships($body_id)->{ships}};

  manage_waste_ships($body_id, @ships);
  # Ensure at least 2 unassigned galleons
  # Ensure sufficient hulks in supply chain for 110%
  # Ensure 2 drones
  # Ensure 2-10 excavators

#  # Remove pending trades from requests
#  for my $ship (@ships) {
#    if ($ship->{task} =~ /Wait|Travel/) {
#      $requests{$body_id}{$ship->{type}}--;
#    }
#  }
}

# Tally requests as builds
my %builds;
for my $request (values(%requests)) {
  for my $type (keys(%$request)) {
    $request->{$type} = 0 if ($request->{type} || 0) < 0;
    $builds{$type} += $request->{$type};
  }
}

# Remove returns from builds
for my $ship (map { @$_ } values(%returns)) {
  $builds{$ship->{type}}--;
}

# Remove ships in stock from builds
my @ships = @{$client->port_all_ships($yard_planet)->{ships}};
for my $ship (@ships) {
  if ($ship->{task} !~ /Chain/) {
    $builds{$ship->{type}}--;
  }
}

# Figure out completion times for yards
for my $yard (@yards) {
  if ($yard->{work}) {
    $yard->{work_done} = Client::parse_time($yard->{work}{end});
  } else {
    $yard->{work_done} = time();
  }
}

# Figure out where to build ships
for my $type (keys(%builds)) {
  next if $builds{$type} < 1;
  my %qty;
  for my $j (1..$builds{$type}) {
    my $winner = (sort { $a->{work_done} <=> $b->{work_done} } @yards)[0];
    $winner->{work_done} += $buildable->{buildable}{$type}{cost}{seconds};
    $qty{$winner->{id}}++;
  }
  for my $yard (@yards) {
    next unless $qty{$yard->{id}} > 0;
    printf("Using yard at (%d,%d) to build %d %s\n",
           $yard->{x}, $yard->{y}, $qty{$yard->{id}}, $buildable->{buildable}{$type}{type_human});
    eval    { $client->yard_build($yard->{id}, $type, $qty{$yard->{id}}); }
    or eval { $client->yard_build($yard->{id}, $type); };
  }
}

# Send ships to requestors
for my $body_id (@body_ids) {
  my @ready = grep { $_->{task} eq "Docked" } @ships;
}

# Ensure enough scows in waste chain to handle total waste output + 10%
sub manage_waste_ships {
  my $body_id = shift;
  my @ships = @_;

  my $port = eval { $client->find_building($body_id, "Space Port") };

  my $waste_rate = base_waste_rate($body_id);
  my $best_waste = first { $_->{attributes}{berth_level} <= $port->{level} } @waste_ships;
  my $best_haul = $best_waste->{attributes}{hold_size} * $best_waste->{attributes}{speed} / sqrt(3) / 2000;
  my $num_ships = int(($waste_rate * 1.1 + $best_haul - 1) / $best_haul);
  printf("Base waste production rate %d/hr.  Best ship is %s, can haul %d/hr.  Need %d waste ships.\n",
         $waste_rate, $best_waste->{type_human}, $best_haul, $num_ships);

  my @waste = is_waste_ship(@ships);
  my @current = grep { !is_obsolete($_, $best_waste) } @waste;
  my @ordered = sort { is_obsolete($b, $best_waste) <=> is_obsolete($a, $best_waste) ||
                       $b->{hold_size} <=> $a->{hold_size} ||
                       ($b->{task} eq "Waste Chain") <=> ($a->{task} eq "Waste Chain") } @waste;
  my $have_enough = adjust_waste_chain($body_id, $waste_rate * 1.1, @ordered);
  if ($have_enough) {
    my @junk  = grep { $_->{task} eq "Idle" &&  is_obsolete($_) } @waste;
    my @extra = grep { $_->{task} eq "Idle" && !is_obsolete($_) } @waste;
    printf("Scuttling %2d obsolete waste ships on %s\n", scalar(@junk),  $planets->{$body_id}) if @junk;
    printf("Returning %2d extra waste ships on %s\n",    scalar(@extra), $planets->{$body_id}) if @extra;
    scuttle_ships($body_id, @junk);
    $returns{$body_id} ||= [];
    push(@{$returns{$body_id}}, @extra);
  } elsif ($num_ships > @current) {
    $requests{$body_id}{$best_waste->{type}} = $num_ships - @current;
    printf("Requesting %2d new %s for %s\n",
           $requests{$body_id}{$best_waste->{type}}, $best_waste->{type_human}, $planets->{$body_id});
  }
}

sub adjust_waste_chain {
  my $body_id = shift;
  my $wanted_haul = shift;
  my @ships = @_;

  my $added = 0;
  my $removed = 0;
  my $haul = 0;
  for my $j (0..$#ships) {
    if ($haul < $wanted_haul) {
      if ($ships[$j]{task} eq "Waste Chain") {
        $haul += $ships[$j]{hold_size} * $ships[$j]{speed} / sqrt(3) / 2000;
      } elsif ($ships[$j]{task} eq "Idle") {
        printf("%s: Adding ships to waste chain:\n", $planets->{$body_id}) unless $added;
        printf("  %-26s berth %2d  speed %5d  stealth %5d  combat %5d  hold %9d\n",
               $ships[$j]{type_human},
               @{$ships[$j]}{qw(berth_level speed stealth combat hold_size)});
        $added = 1;
        eval {
          $client->add_waste_ship_to_fleet($body_id, $ships[$j]{id});
          $ships[$j]{task} = "Waste Chain";
          $haul += $ships[$j]{hold_size} * $ships[$j]{speed} / sqrt(3) / 2000;
        }
      }
    } else {
      if ($ships[$j]{task} eq "Waste Chain") {
        printf("%s: Removing ships from waste chain:\n", $planets->{$body_id}) unless $removed;
        printf("  %-26s berth %2d  speed %5d  stealth %5d  combat %5d  hold %9d\n",
               $ships[$j]{type_human},
               @{$ships[$j]}{qw(berth_level speed stealth combat hold_size)});
        $removed = 1;
        eval {
          $client->remove_waste_ship_from_fleet($body_id, $ships[$j]{id});
          $ships[$j]{task} = "Return From Assignment";
        }
      }
    }
  }

  return $haul >= $wanted_haul;
}

sub scuttle_ships {
  my $body_id = shift;
  my @ships = @_;

  for my $ship (@ships) {
    eval {
      $client->scuttle_ship($body_id, $ship->{id});
    }
  }
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
  my $ideal = shift || $buildable->{buildable}{$ship->{type}};
  return 0 unless $ideal->{can};
  return 1 if $ship->{type} ne $ideal->{type};
  for my $attr (qw(speed stealth combat hold_size)) {
    return 1 if $ship->{$attr} < $ideal->{attributes}{$attr};
  }
  return 0;
}
