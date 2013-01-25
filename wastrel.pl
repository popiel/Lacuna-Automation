#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my $body_name;
my $min_waste = "10%";
my $max_waste = "90%";
my $interval = "1 hour";
my $debug = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \$body_name,
  "min_waste=s" => \$min_waste,
  "max_waste=s" => \$max_waste,
  "interval=s"  => \$interval,
  "debug"       => \$debug,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  die "No matching planet for name $body_name\n" unless $body_id;
  $body_name = $planets->{$body_id};
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

$interval = $1         if $interval =~ /^(\d+) ?s(econds?)?$/i;
$interval = $1 * 60    if $interval =~ /^(\d+) ?m(inutes?)?$/i;
$interval = $1 * 3600  if $interval =~ /^(\d+) ?h(ours?)?$/i;
$interval = $1 * 86400 if $interval =~ /^(\d+) ?d(ays?)?$/i;

my $trade = $client->find_building($body_id, "Trade Ministry");
die "No trade ministry on $body_name\n" unless $trade;

my $status = $client->body_status($body_id);
$min_waste = int($status->{waste_capacity} * $1 / 100) if $min_waste =~ /^(\d+)\%$/;
$max_waste = int($status->{waste_capacity} * $1 / 100) if $max_waste =~ /^(\d+)\%$/;
die "Unable to parse min_waste: $min_waste\n" unless $min_waste =~ /^\d+$/;
die "Unable to parse max_waste: $max_waste\n" unless $max_waste =~ /^\d+$/;
$min_waste = $max_waste if $min_waste > $max_waste;

emit("Boundaries: $min_waste ... $max_waste") if $debug;
emit("Interval: $interval") if $debug;
emit("Waste stored: $status->{waste_stored} + $status->{waste_hour}/hour") if $debug;
my $projection = $status->{waste_stored} + $status->{waste_hour} * $interval / 3600;
emit("Projection: $projection ".($projection < $min_waste ? "low" : ($projection > $max_waste ? "high" : "good"))) if $debug;
exit(0) if $projection >= $min_waste && $projection <= $max_waste;

my $chain = $client->call(trade => view_waste_chains => $trade->{id})->{waste_chain}[0];
my $capacity = $chain->{waste_hour} * ($chain->{percent_transferred} || 1) / 100;
my $pct = $chain->{waste_hour} * 100 / ($capacity || 1);
emit("Existing chain transfer $chain->{waste_hour}/hour ($pct% of $capacity)");

my $desired = $chain->{waste_hour};
if ($projection > $max_waste) {
  if ($chain->{waste_hour} && $chain->{percent_transferred} < 100) {
    if ($status->{waste_hour} < 0) {
      emit("Barely keeping up with waste production.");
    } else {
      emit("Cannot keep up with waste production!");
    }
    exit(0);
  }
  my $amount = ($projection - $max_waste) * 3600 / $interval;
  $desired = $chain->{waste_hour} + $amount;
} elsif ($projection < $min_waste) {
  if ($chain->{waste_hour} < 2) {
    emit("Cannot produce enough waste!");
    exit(0);
  }
  my $amount = ($min_waste - $projection) * 3600 / $interval;
  $desired = $chain->{waste_hour} - $amount;
  $desired = 1 if $desired < 1;
}

my $pct = int($desired * 100 / ($capacity || 1));
emit("Changing waste chain rate to $desired/hour ($pct% of $capacity)");
$client->call(trade => update_waste_chain => $trade->{id}, $chain->{id}, $desired);

sub emit {
  my $message = shift;
  print Client::format_time(time())." wastrel: $body_name: $message\n";
}
