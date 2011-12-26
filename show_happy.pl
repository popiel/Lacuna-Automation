#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $body_name;

GetOptions(
  "config=s" => \$config_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %happy;
for my $id (keys(%$planets)) {
  $happy{$id} = $client->body_status($id)->{happiness};
}
for my $id (sort { $happy{$b} <=> $happy{$a} } keys %happy) {
  printf("%10d %s\n", $happy{$id}, $planets->{$id});
}
