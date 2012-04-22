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
my $body_name;
my $queue_name;
my $debug = 0;
my $quiet = 0;
my $max_build_time = "30 minutes";

GetOptions(
  "config=s" => \$config_name,
  "body|b=s"   => \$body_name,
  "time|build|fill=s"   => \$max_build_time,
  "debug"    => \$debug,
  "quiet"    => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

$max_build_time = $1         if $max_build_time =~ /^(\d+) ?s(econds?)?$/;
$max_build_time = $1 * 60    if $max_build_time =~ /^(\d+) ?m(inutes?)?$/;
$max_build_time = $1 * 3600  if $max_build_time =~ /^(\d+) ?h(ours?)?$/;
$max_build_time = $1 * 86400 if $max_build_time =~ /^(\d+) ?d(ays?)?$/;

$max_build_time -= 10;

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  exit(1) if $quiet && !$body_id;
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $buildings = $client->body_buildings($body_id);
my $keep_limit = 100;
if ($client->body_status($body_id)->{waste_hour} < 0) {
  $keep_limit = $client->body_status($body_id)->{waste_capacity} / 2;
}
exit(0) if $client->body_status($body_id)->{waste_stored} < $keep_limit;
$body_name = $client->body_status($body_id)->{name};

my @centers = reverse($client->find_building($body_id, "Waste Recycling Center"),
                      $client->find_building($body_id, "Waste Exchanger"));

for my $center (@centers) {
  next if $center->{work};
  my $view = $client->building_view($center->{url}, $center->{id});
  my $waste = List::Util::min($max_build_time / $view->{recycle}{seconds_per_resource},
                              $client->body_status($body_id)->{waste_stored} - $keep_limit);
  my %res;
  my $sum = 0;
  for my $res (qw(ore water energy)) {
    $res{$res} = $client->body_status($body_id)->{"${res}_capacity"} - $client->body_status($body_id)->{"${res}_stored"} + 1;
    $sum += $res{$res};
  }

  for my $res (qw(ore water energy)) {
    $res{$res} = int($res{$res} * $waste / $sum);
  }

  $client->recycle_recycle($center->{id}, $res{water}, $res{ore}, $res{energy}, $center->{url});
  emit("Recycled for $res{ore} ore, $res{water} water, and $res{energy} energy.");
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
