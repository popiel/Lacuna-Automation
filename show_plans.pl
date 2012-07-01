#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use List::Util qw(sum);
use JSON::PP;

my $config_name = "config.json";
my @body_name;
my $total_only;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \@body_name,
  "total!"   => \$total_only,
) or die "$0 --config=foo.json --body=Bar --total_only\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %plans;
for my $body_id (keys(%$planets)) {
  my $body_name = $planets->{$body_id};
  next unless !@body_name || grep { $body_name =~ /$_/ } @body_name;

  my $plans = eval { $client->body_plans($body_id) };
  next unless $plans;

  printf("Got %d plans from %s\n", sum(map { $_->{quantity} } @{$plans->{plans}}), $body_name);
  for my $plan (@{$plans->{plans}}) {
    $plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"} ||= {};
    $plans{"$plan->{name} ($plan->{level}+$plan->{extra_build_level})"}{$body_name} = $plan->{quantity};
  }
}
print "----\n";
for my $name (sort keys %plans) {
  my $plans = $plans{$name};
  my $total = sum(values %$plans);
  printf("%5d %-30s\n", $total, $name);
  unless ($total_only) {
    for my $body (sort keys %$plans) {
      printf("  %5d %s\n", $plans->{$body}, $body);
    }
  }
}
