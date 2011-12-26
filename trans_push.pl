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
my $target_name;
my $ship_name = "^Food Swap";
my $cargo = "algae";
my $stay = 0;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \$body_name,
  "target=s"    => \$target_name,
  "cargo=s"     => \$cargo,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify body and target\n" unless $body_name && $target_name;

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my $body_id;
my $target_id;
for my $id (keys(%$planets)) {
  $body_id   = $id if $planets->{$id} =~ /$body_name/;
  $target_id = $id if $planets->{$id} =~ /$target_name/;
}
exit(1) if $quiet && (!$body_id || !$target_id);
die "No matching planet for name $body_name\n"   unless $body_id;
die "No matching planet for name $target_name\n" unless $target_id;

my $buildings = $client->body_buildings($body_id);
$body_name = $client->body_status($body_id)->{name};

my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

my $trade = (grep($_->{name} eq "Subspace Transporter", @buildings))[0];

die "No Subspace Transporter on $body_name\n" unless $trade;

my $items;
if ($cargo =~ /^\{/) {
  $cargo = decode_json($cargo);
  $items = [ map { { type => $_, quantity => $cargo->{$_} } } keys %$cargo ];
}
elsif ($cargo =~ /^\[/) {
  $items = decode_json($cargo);
}
#else {
  #my $resources = $client->call(trade => get_stored_resources => $trade->{id});
  #my $amount = List::Util::min($ship->{hold_size}, $resources->{resources}{$cargo});
  #$items = [ { type => $cargo, quantity => $amount } ],
#}

eval {
  my $result = $client->transporter_push($trade->{id}, $target_id, $items);
  my $item_text = join(", ", map { "$_->{quantity} $_->{type}" } @$items);
  emit("Sending $item_text to $planets->{$target_id} via subspace") if $result;
};

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
