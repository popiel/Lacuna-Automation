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
  my $happy = sprintf("%0.0f ", $happy{$id});
  1 while $happy =~ s/(\d)(\d\d\d)(\D)/$1,$2$3/;
  my $perhour = sprintf("%0.0f ", $waste
    ? $client->body_status($id)->{happiness_hour} - max(0, $client->body_status($id)->{waste_hour})
    : $client->body_status($id)->{happiness_hour});
  1 while $perhour =~ s/(\d)(\d\d\d)(\D)/$1,$2$3/;
  printf("%20s %15s/hr   %s\n", $happy, $perhour, $planets->{$id});
}
