#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;
use List::Util qw(max);

my $config_name = "config.json";
my $waste = 0;

GetOptions(
  "config=s" => \$config_name,
  "waste!"   => \$waste,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %happy;
for my $id (keys(%$planets)) {
  $happy{$id} = $client->body_status($id)->{happiness};
}
for my $id (sort { $happy{$b} <=> $happy{$a} } keys %happy) {
  printf("%13.0f %10.0f/hr   %s\n",
         $happy{$id},
         $waste
         ? $client->body_status($id)->{happiness_hour} - max(0, $client->body_status($id)->{waste_hour})
         : $client->body_status($id)->{happiness_hour},
         $planets->{$id});
}
