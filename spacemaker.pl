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
my $queue_name;
my $debug = 0;
my $quiet = 0;
my $do_food = "default";
my $do_ore  = "default";

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "debug"    => \$debug,
  "quiet"    => \$quiet,
  "food!"    => \$do_food,
  "ore!"     => \$do_ore,
) or die "$0 --config=foo.json --body=Bar\n";

$do_food = 0 if $do_food eq "default" && $do_ore  && $do_ore  ne "default";
$do_ore  = 0 if $do_ore  eq "default" && $do_food && $do_food ne "default";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  exit(1) if $quiet && !$body_id;
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

$body_name = $client->empire_status->{planets}{$body_id};

my $buildings = $client->body_buildings($body_id);
my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

do_dump("food", "Food Reserve"     ) if $do_food;
do_dump("ore",  "Ore Storage Tanks") if $do_ore;

sub do_dump {
  my $type = shift;
  my $name = shift;

  my $building = (grep($_->{name} eq $name, @buildings))[0];
  if (!$building) {
    emit("Skipping $type; no $name");
    return;
  }

  my %stored = %{$client->call($building->{url} => view => $building->{id})->{$type."_stored"}};
  my $status = $client->body_status($body_id);
  my $wanted = List::Util::max($status->{$type."_capacity"} / 2, $status->{$type."_capacity"} - $status->{$type."_hour"} * 2);
  return if $status->{$type."_stored"} <= $wanted;

  my @ordered = sort { $stored{$a} <=> $stored{$b} } keys %stored;
  my %keep;
  while ($wanted / @ordered > $stored{$ordered[0]}) {
    my $f = shift @ordered;
    $keep{$f} = $stored{$f};
    $wanted  -= $stored{$f};
  }
  for my $f (@ordered) {
    $keep{$f} = int($wanted / @ordered);
  }

  my %dump = map { $_ => $stored{$_} - $keep{$_} } grep { $stored{$_} > $keep{$_} } keys %stored;

  emit("Dumping ".join(", ", map { "$dump{$_} $_" } keys %dump));

  for my $f (keys %dump) {
    next unless $dump{$f};
    eval { $client->call($building->{url} => dump => $building->{id}, $f, $dump{$f}); };
  }
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
