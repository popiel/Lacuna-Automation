#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my $body_name;
my $queue_name;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "debug"    => \$debug,
  "quiet"    => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

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

my $food = (grep($_->{name} eq "Food Reserve", @buildings))[0];
$food or do { emit("No Food Reserve"); exit(1); };

my %stored = %{$client->call(foodreserve => view => $food->{id})->{food_stored}};
my $status = $client->body_status($body_id);
my $wanted = List::Util::max($status->{food_capacity} / 2, $status->{food_capacity} - $status->{food_hour} * 2);
exit(0) if $status->{food_stored} <= $wanted;

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
  eval { $client->call(foodreserve => dump => $food->{id}, $f, $dump{$f}); };
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
