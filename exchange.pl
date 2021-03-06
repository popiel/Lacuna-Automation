#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_name;
my $ship_name;
my $equalize = 0;
my $themepark = 0;
my $stay = 1;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "ship|name=s" => \$ship_name,
  "equalize"    => \$equalize,
  "themepark"   => \$themepark,
  "stay!"       => \$stay,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify two bodies\n" unless @body_name == 2;
$ship_name ||= join(" ", @body_name);

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my @body_id;
for my $id (keys(%$planets)) {
  $body_id[0] = $id if $planets->{$id} =~ /$body_name[0]/;
  $body_id[1] = $id if $planets->{$id} =~ /$body_name[1]/;
}
exit(1) if !$debug && $quiet && (!$body_id[0] || !$body_id[1]);
die "No matching planet for name $body_name[0]\n" unless $body_id[0];
die "No matching planet for name $body_name[1]\n" unless $body_id[1];

# get trade ministries, space ports, and ships for each planet
my @trade;
my @port;
my @ship;
for my $body_id (@body_id) {
  $debug and print "Looking at $planets->{$body_id}\n";
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

  my $trade = (grep($_->{name} eq "Trade Ministry", @buildings))[0];
  my $port  = (grep($_->{name} eq "Space Port",     @buildings))[0];

  die "No Trade Ministry on $planets->{$body_id}\n" unless $trade;
  die "No Space Port ". "on $planets->{$body_id}\n" unless $port;

  $debug and print "Got trade $trade->{id}, port $port->{id}\n";

  my $ships = $client->port_all_ships($port->{id});
  my $ship = (grep($_->{name} =~ /$ship_name/ && $_->{task} eq "Docked", @{$ships->{ships}}))[0];

  $debug and print "Got ship $ship->{id}\n";

  exit(0) unless $ship->{id};

  push(@trade, $trade);
  push(@port,  $port);
  push(@ship,  $ship);
}

my @foods = qw(algae apple bean beetle bread burger
               cheese chip cider corn fungus lapis
               meal milk pancake pie potato root
               shake soup syrup wheat);
my @ores = qw(anthracite bauxite beryl chalcopyrite chromite
              fluorite galena goethite gold gypsum
              halite kerogen magnetite methane monazite
              rutile sulfur trona uraninite zircon);


# get resource counts for each planet
my @resources;
my %total;
for my $trade (@trade) {
  my $resources = $client->call(trade => get_stored_resources => $trade->{id});
  push(@resources, $resources);
  for my $res (keys %{$resources->{resources}}) {
    $total{$res} += $resources->{resources}{$res};
  }
}

# find flight time
my $duration = $client->call(trade => get_trade_ships => $trade[0]->{id}, $body_id[1]);
$duration = (grep($_->{id} eq $ship[0]->{id}, @{$duration->{ships}}))[0]->{estimated_travel_time};
$debug and print "Flight time: $duration seconds\n";

# determine desired resource levels
my %desire;
distribute($client->body_status($body_id[0])->{food_capacity},
           $client->body_status($body_id[0])->{food_hour},
           @foods);
distribute($client->body_status($body_id[0])->{ore_capacity},
           0, # $client->body_status($body_id[0])->{ore_hour},
           @ores);
distribute($client->body_status($body_id[0])->{water_capacity }, 0, "water");
distribute($client->body_status($body_id[0])->{energy_capacity}, 0, "energy");
if ($equalize) {
  distribute($client->body_status($body_id[0])->{waste_capacity}, 0, "waste");
}
else {
  $desire{waste} = List::Util::min($client->body_status($body_id[0])->{waste_stored},
                                   $client->body_status($body_id[0])->{waste_capacity} * 3 / 4);
}

sub distribute {
  my $capacity = shift;
  my $rate     = shift;
  my @types    = @_;

  if ($themepark && $types[0] eq $foods[0]) {
    for my $type (@types) {
      $desire{$type} = List::Util::min(1100, $total{$type} - 10);
    }
    my @sorted = sort { $total{$b} <=> $total{$a} } @types;
    emit("Collecting top foods: " . join(", ", @sorted[0..4]), $planets->{$body_id[0]});
    for my $type (@sorted[0..4]) {
      $desire{$type} = List::Util::min(($capacity - 22000) / 5, $total{$sorted[2]}, $total{$type});
    }
  }
  elsif ($equalize && $types[0] eq "waste") {
    $desire{waste} = int($total{waste} * $capacity / ($capacity + $client->body_status($body_id[1])->{waste_capacity}));
  }
  elsif ($equalize) {
    for my $type (@types) {
      $desire{$type} = int($total{$type} / 2);
    }
  }
  else {
    $rate = 0 if $rate < 0;

    my $buffer         = int($rate / 3600 * $duration * 2);
    my $fill_remaining = $capacity - $buffer;

    # Distribute capacity as evenly as possible across types
    @types = sort { $total{$a} <=> $total{$b} } grep($total{$_}, @types);
    while (@types && $fill_remaining) {
      my $per = int($fill_remaining / @types);
      my $type = shift @types;
      $desire{$type} = List::Util::min($total{$type}, $per);
      $fill_remaining -= $desire{$type};
    }
  }
}

# Fill ships
my @items = ([], []);
for my $type ("waste", @foods, "water", "energy", @ores) {
  my $delta = $desire{$type} - $resources[0]->{resources}{$type};
  if ($delta < 0) {
    my $size = $ship[0]->{hold_size};
    my $used = List::Util::sum(map { $_->{quantity} } @{$items[0]});
    my $amount = List::Util::min($size - $used, -$delta, List::Util::max(0, $resources[0]->{resources}{$type} - 10));
    push(@{$items[0]}, { type => $type, quantity => int($amount) }) if (int($amount));
  }
  elsif ($delta > 0) {
    my $size = $ship[1]->{hold_size};
    my $used = List::Util::sum(map { $_->{quantity} } @{$items[1]});
    my $amount = List::Util::min($size - $used, $delta, List::Util::max(0, $resources[1]->{resources}{$type} - 10));
    push(@{$items[1]}, { type => $type, quantity => int($amount) }) if (int($amount));
  }
}

push(@{$items[0]}, { type => "energy", quantity => 1 }) unless @{$items[0]};
push(@{$items[1]}, { type => "energy", quantity => 1 }) unless @{$items[1]};

# Push ships

my $item_text = join(", ", map { "$_->{quantity} $_->{type}" } @{$items[0]});
emit("Sending $item_text to $planets->{$body_id[1]} on $ship[0]{name}", $planets->{$body_id[0]});
my $result = $client->trade_push(
  $trade[0]->{id}, $body_id[1], $items[0],
  { ship_id => $ship[0]->{id}, stay => $stay }
);

my $item_text = join(", ", map { "$_->{quantity} $_->{type}" } @{$items[1]});
emit("Sending $item_text to $planets->{$body_id[0]} on $ship[1]{name}", $planets->{$body_id[1]});
my $result = $client->trade_push(
  $trade[1]->{id}, $body_id[0], $items[1],
  { ship_id => $ship[1]->{id}, stay => $stay }
);

sub emit {
  my $message = shift;
  my $name = shift;
  print Client::format_time(time())." $name: $message\n";
}
