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
my $quiet_no_body = 0;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "debug"    => \$debug,
  "quiet_no_body"    => \$quiet_no_body,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  exit(1) unless $body_id || !$quiet_no_body;
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $buildings = $client->body_buildings($body_id);
$body_name = $client->body_status($body_id)->{name};

my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

for my $building (@buildings) {
  next if $building->{efficiency} == 100;
  $client->building_repair($building->{url}, $building->{id});
  emit("Repaired $building->{name} from $building->{efficiency}%");
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
