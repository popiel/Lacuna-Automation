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
my $ore;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "ore|type=s" => \$ore,
  "debug"    => \$debug,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify ore to process\n" unless $ore;

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
$body_name = $client->body_status($body_id)->{name};

my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

my $ministry = (grep($_->{name} eq "Archaeology Ministry", @buildings))[0];

die "No Archaeology Ministry on $body_name\n" unless $ministry;

exit(0) if $ministry->{work};

my $result = $client->archaeology_search($ministry->{id}, $ore);
emit("Searching for $ore glyph.");

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
