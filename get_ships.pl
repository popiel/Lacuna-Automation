#!/usr/bin/perl

use strict;
use warnings;

use Client;
use Getopt::Long;
use JSON::XS;

my $config_name = "config.json";
my $body_name = "";

GetOptions(
  "config=s" => \$config_name,
  "body=s" => \$body_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  next if $body_name && $planets->{$body_id} !~ /\Q$body_name/i;
  print "$planets->{$body_id} ($body_id):\n";
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my $trade = (grep($_->{name} eq "Trade Ministry", @buildings))[0];
  print "  Trade Ministry:       $trade->{id}\n";
  my $port = (grep($_->{name} eq "Space Port", @buildings))[0];
  my $slots = List::Util::sum(map { $_->{level} } grep { $_->{name} eq "Space Port" } @buildings) * 2;
  print "  Space Port:           $port->{id}\n";
  next unless $port->{id};
  my @ships = @{$client->port_all_ships($port->{id}, 1)->{ships}};
  for my $ship (@ships) {
    printf("    %-8d  hold:%6d  speed:%4d   %-20s %-11s%s\n", @{$ship}{qw(id hold_size speed name task)},
           $ship->{task} ne "Docked" ? Client::format_time(Client::parse_time($ship->{date_available})) : "");
  }
  printf("      %d of %d slots used, %d slots empty\n", scalar(@ships), $slots, $slots - @ships);
}
