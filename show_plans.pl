#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my @body_name;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \@body_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %plans;
for my $body_id (keys(%$planets)) {
  next unless !@body_name || grep { $planets->{$body_id} =~ /$_/ } @body_name;
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my $trade = (grep($_->{name} eq "Trade Ministry", @buildings))[0];
  next unless $trade;

  my $plans = $client->call(trade => get_plans => $trade->{id});
  printf("Got %d plans from %s\n", scalar(@{$plans->{plans}}), $planets->{$body_id});
  for my $plan (@{$plans->{plans}}) {
    $plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"} ||= [];
    push(@{$plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"}}, $plan->{id});
  }
}
for my $name (sort keys %plans) {
  printf("%5d %-30s %s\n", scalar(@{$plans{$name}}), $name, join(", ", @{$plans{$name}}[0..3]));
}
