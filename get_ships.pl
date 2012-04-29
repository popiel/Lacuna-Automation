#!/usr/bin/perl

use strict;
use warnings;

use Client;
use Getopt::Long;
use JSON::PP;
use List::Util ();

my $config_name = "config.json";
my $body_name = "";
my $json;

GetOptions(
  "config=s" => \$config_name,
  "body=s" => \$body_name,
  "json" => \$json,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
if ($body_name) {
  my $body_id = $client->match_planet($body_name);
  $planets = { $body_id => $planets->{$body_id} };
}
for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys(%$planets)) {
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my $port = eval { $client->find_building($body_id, "Space Port") };
  next unless $port;
  my $slots = 2 * List::Util::sum(map $_->{level}, $client->find_building($body_id, "Space Port"));
  my @ships = @{$client->port_all_ships($port->{id})->{ships}};

  if ($json) {
    $json = JSON::PP->new->ascii->canonical;
    for my $ship (@ships) {
      for my $date( $ship->{date_available}, $ship->{date_started} ) {
        $date = Client::format_time(Client::parse_time($date));
      }
      print $json->encode($ship), "\n";
    }
  }
  else {
    print "$planets->{$body_id} ($body_id):\n";
    my $trade = eval { $client->find_building($body_id, "Trade Ministry") };
    print "  Trade Ministry:       $trade->{id}\n" if $trade;
    print "  Space Port:           $port->{id}\n";
    for my $ship (@ships) {
      printf("    %-8d  hold:%6d  speed:%4d   %-20s %-11s%s\n", @{$ship}{qw(id hold_size speed name task)},
           $ship->{task} ne "Docked" ? Client::format_time(Client::parse_time($ship->{date_available})) : "");
    }
    printf("      %d of %d slots used, %d slots empty\n", scalar(@ships), $slots, $slots - @ships);
  }
}
