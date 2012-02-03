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
my $min_waste = 100000;
my $debug = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \$body_name,
  "min_waste=i" => \$min_waste,
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
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $buildings = $client->body_buildings($body_id);
my $status = $client->body_status($body_id);
$body_name = $status->{name};
emit("Waste stored: $status->{waste_stored}") if $debug;
if ($client->body_status($body_id)->{waste_hour} > 0) {
  exit(0) if $status->{waste_stored} < $min_waste;
}
else {
  exit(0) if $status->{waste_stored} < List::Util::max($status->{waste_capacity} * 3 / 4, $status->{waste_capacity} - 100000);
}

my $target = { star_id => $status->{star_id} };

my $ships = $client->call(spaceport => get_ships_for => $body_id, $target);

if ($debug) {
  emit("Ship count: ".scalar(@{$ships->{available}}));
  for my $ship (@{$ships->{available}}) {
    emit("$ship->{id}: $ship->{type} $ship->{task}");
  }
}

my $scow = (grep($_->{type} eq "scow" && $_->{task} eq "Docked" && $_->{hold_size} <= $status->{waste_stored}, @{$ships->{available}}))[0];
emit("Using ship: $scow->{id}") if $debug;

exit(0) unless $scow;

my $result = $client->call(spaceport => send_ship => $scow->{id}, $target);

emit("Sent scow to $status->{star_name}");

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
