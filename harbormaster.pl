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
my $max_build_time = "2 hours";

GetOptions(
  "config=s" => \$config_name,
  "body|b=s" => \@body_name,
  "yard=s"   => \$yard_name,
  "max_build_time|build|fill=s" => \$max_build_time,
) or die "$0 --config=foo.json --body=Bar\n";

$max_build_time = $1         if $max_build_time =~ /^(\d+) ?s(econds?)?$/;
$max_build_time = $1 * 60    if $max_build_time =~ /^(\d+) ?m(inutes?)?$/;
$max_build_time = $1 * 3600  if $max_build_time =~ /^(\d+) ?h(ours?)?$/;
$max_build_time = $1 * 86400 if $max_build_time =~ /^(\d+) ?d(ays?)?$/;

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my $yard_planet = $yard_name ? $client->match_planet($yard_name) : $client->empire_status->{home_planet_id};
my $trade = $client->find_building($yard_planet, "Trade Ministry");
my $yard  = $client->find_building($yard_planet, "Shipyard");
my @yards = grep { $_->{level} == $yard->{level} } $client->find_building($yard_planet, "Shipyard");
my @ships_wanted;

my $buildable = $client->yard_buildable($yard->{id});
for my $type (keys(%{$buildable->{buildable}})) { $buildable->{buildable}{$type}{type} = $type; }
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
#print "waste_rate: $waste_rate\n";
  my $waste_chain = $client->body_waste_chain($body_id)->{waste_chain}[0];
#print "waste_chain: $waste_chain->{percent_transferred}% of $waste_chain->{waste_hour}\n";
  if ($waste_chain->{percent_transferred} >= 100) {
    $waste_rate += $waste_chain->{waste_hour};
  } else {
    $waste_rate += $waste_chain->{waste_hour} * $waste_chain->{percent_transferred} / 100;
  }
#print "total waste_rate: $waste_rate\n";
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
  manage_supply_ships($body_id, @ships);
  # Ensure at least 2 unassigned galleons
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

# Figure out where to build ships, starting with the fast-to-build ships
my $cutoff = time() + $max_build_time;
for my $type (sort { $buildable->{buildable}{$a}{cost}{seconds} <=> $buildable->{buildable}{$b}{cost}{seconds} } keys(%builds)) {
  next if $builds{$type} < 1;
  my %qty;
  for my $j (1..$builds{$type}) {
    my $winner = (sort { $a->{work_done} <=> $b->{work_done} } @yards)[0];
    last if $winner->{work_done} > $cutoff;
    $winner->{work_done} += $buildable->{buildable}{$type}{cost}{seconds};
    $qty{$winner->{id}}++;
  }
  for my $yard (@yards) {
    next unless ($qty{$yard->{id}} || 0) > 0;
    printf("Using yard at (%d,%d) to build %d %s\n",
           $yard->{x}, $yard->{y}, $qty{$yard->{id}}, $buildable->{buildable}{$type}{type_human});
    eval    { $client->yard_build($yard->{id}, $type, $qty{$yard->{id}}); }
    or eval { $client->yard_build($yard->{id}, $type); };
  }
}

# Send ships to requestors
for my $body_id (@body_ids) {
  next if $body_id eq $yard_planet;
  my %ready;
  for my $ship (@ships) {
    next unless $ship->{task} eq "Docked";
    $ready{$ship->{type}} ||= [];
    push(@{$ready{$ship->{type}}}, $ship);
  }
  my @sending;
  for my $type (keys(%{$requests{$body_id}})) {
    my $n = $requests{$body_id}{$type};
    while ($n > 0) {
      last unless $ready{$type} && @{$ready{$type}};
      push(@sending, shift(@{$ready{$type}}));
      $n--;
    }
  }

  send_many_ships("sending %s to $planets->{$body_id} with:\n",
                  $trade->{id}, $body_id, \@sending, \@ships);
}

# Send all returns back to the yard planet
for my $body_id (@body_ids) {
  next if $body_id eq $yard_planet;
  next unless $returns{$body_id} && @{$returns{$body_id}};

  send_many_ships("returning %s from $planets->{$body_id} with:\n",
                  $client->find_building($body_id, "Trade Ministry")->{id},
                  $yard_planet, $returns{$body_id}, $client->port_all_ships($body_id)->{ships});
}

sub send_many_ships {
  my $message = shift;
  my $source_trade = shift;
  my $target_id = shift;
  my $sending = shift;
  my $ships = shift;

  my @sending = sort { !!is_trade_ship($b) <=> !!is_trade_ship($a) ||
                       $b->{speed} <=> $a->{speed} } @$sending;
  while (@sending && is_trade_ship($sending[0])) {
    my $carrier = shift(@sending);
    last unless send_ships("Permanently $message", 1, $carrier, \@sending, $source_trade, $target_id);
  }
  if (@sending) {
    my @carriers = sort { $b->{hold_size} <=> $a->{hold_size} } grep { $_->{task} eq "Docked" } is_trade_ship(@$ships);
    while (@sending) {
      my $carrier = shift(@carriers);
      last unless send_ships("Temporarily $message", 0, $carrier, \@sending, $source_trade, $target_id);
    }
  }
}

sub send_ships {
  my $message      = shift;
  my $lenient      = shift;
  my $carrier      = shift;
  my $sending      = shift;
  my $source_trade = shift;
  my $target_id    = shift;

  my $space = int(($carrier->{hold_size} || 0) / 50000);
  my @carried;
  while (@$sending && $space) {
    push(@carried, pop(@$sending));
    $space--;
  }
  my @items = map { { type => ship => ship_id => $_->{id} } } @carried;
  if (!@items) {
    return 0 if !$lenient;
    push(@items, { type => water => quantity => 1 });
  }
  eval {
    printf($message, $carrier->{type_human});
    for my $ship (@carried) {
      printf("%10d %-26s berth %2d  speed %5d  stealth %5d  combat %5d  hold %9d\n",
             @{$ship}{qw(id type_human berth_level speed stealth combat hold_size)});
    }
    $client->trade_push($source_trade, $target_id, [ @items ], { ship_id => $carrier->{id}, stay => 0 } );
    for my $ship ($carrier, @carried) {
      $ship->{task} = "Travelling";
    }
  };
  return 1;
}

# Ensure sufficient hulks in supply chain for 110%
sub manage_supply_ships {
  my $body_id = shift;
  my @ships = @_;

  my $port = eval { $client->find_building($body_id, "Space Port") };
  my $best_supply = first { $_->{attributes}{berth_level} <= $port->{level} } @supply_ships;
  # fetch supply chains
  # determine capacity * distance required
  # determine ship count needed
  # reallocate ships
  # clean up ships
}

# Ensure enough scows in waste chain to handle total waste output + 10%
sub manage_waste_ships {
  my $body_id = shift;
  my @ships = @_;

  my $port = eval { $client->find_building($body_id, "Space Port") };

  my $waste_rate = max(0, base_waste_rate($body_id));
  my $best_waste = first { $_->{attributes}{berth_level} <= $port->{level} } @waste_ships;
  my $best_haul = $best_waste->{attributes}{hold_size} * $best_waste->{attributes}{speed} / sqrt(3) / 2000;
  my $num_ships = int(($waste_rate * 1.1 + $best_haul - 1) / $best_haul);
  printf("%s: Base waste production rate %d/hr.  Best ship is %s, can haul %d/hr.  Need %d waste ships.\n",
         $planets->{$body_id}, $waste_rate, $best_waste->{type_human}, $best_haul, $num_ships);

  my @waste = is_waste_ship(@ships);
  my @current = grep { !is_obsolete($_, $best_waste) } @waste;
  my @ordered = sort { is_obsolete($a, $best_waste) <=> is_obsolete($b, $best_waste) ||
                       $b->{hold_size} <=> $a->{hold_size} ||
                       ($b->{task} eq "Waste Chain") <=> ($a->{task} eq "Waste Chain") } @waste;
  my $have_enough = adjust_waste_chain($body_id, $waste_rate * 1.1, @ordered);
  if ($have_enough) {
    my @junk  = grep { $_->{task} eq "Docked" &&  is_obsolete($_) } @waste;
    my @extra = grep { $_->{task} eq "Docked" && !is_obsolete($_) } @waste;
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
      } elsif ($ships[$j]{task} eq "Docked") {
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

sub is_trade_ship {
  (wantarray ? (is_tagged_ship("SupplyChain", @_),) : scalar(is_tagged_ship("SupplyChain", @_)))
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
