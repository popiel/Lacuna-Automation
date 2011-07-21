#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::XS;

my $config_name = "config.json";
my $body_name;

GetOptions(
  "config=s" => \$config_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);

my $plans = $client->read_json("plans.json");
my %plans;
for my $plan (@{$plans->{plans}}) {
  $plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"} ||= [];
  push(@{$plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"}}, $plan->{id});
}
for my $name (sort keys %plans) {
  printf("%5d %-30s %s\n", scalar(@{$plans{$name}}), $name, join(", ", @{$plans{$name}}[0..3]));
}
