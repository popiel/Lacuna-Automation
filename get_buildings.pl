#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $body_name;
my $name = "Trade|Subspace|Mission|Port";
my $every = "Warehouse";

GetOptions(
  "config=s" => \$config_name,
  "name=s"   => \$name,
  "body=s"   => \$body_name,
  "every=s"  => \$every,
) or die "$0 --config=foo.json --name=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %plans;
for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  next if $body_name && $body_name ne $planets->{$body_id};
  print "$planets->{$body_id} ($body_id):\n";
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my %buildings;
  my %levels;
  for my $building (@buildings) {
    my $key = $building->{name};
    $key .= " $building->{id}" if $key =~ $every;
    $buildings{$key} = $building->{id};
    $levels{$key} = $building->{level};
  }
  for my $key (sort grep { /$name/ } keys %buildings) {
    (my $name = $key) =~ s/ \Q$buildings{$key}\E\z//;
    printf("  %-28slevel %2d, id %d\n", "$name:", $levels{$key}, $buildings{$key});
  }
}
