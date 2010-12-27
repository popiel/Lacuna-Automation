#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::XS;

my $config_name = "config.json";
my $body_name;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $result = $client->body_buildings($body_id);
my $time = time();

warn "Time delta: ".($time - $result->{status}{_time})."\n";

my @buildings;

for my $id (keys %{$result->{buildings}}) {
  my $name  = $result->{buildings}{$id}{name};
  my $level = $result->{buildings}{$id}{level};
  push(@buildings, { name => $name, level => $level });
}

my %stored;

for my $resource (qw(food ore water energy waste)) {
  $stored{$resource} = resource_info($result->{status}, $resource, $time);
}

print encode_json({ buildings => [ @buildings ], stored => { %stored }, time => $time })."\n";

exit(0);

sub resource_info {
  my $status = shift;
  my $resource = shift;
  my $time = shift;

  my $body = $status->{body};

  my $stored = $body->{"${resource}_stored"};
  my $capacity = $body->{"${resource}_capacity"};
  my $production = $body->{"${resource}_hour"};

  my $current = $stored + $production * ($time - $status->{_time}) / 3600;
  $current = 0 if $current < 0;
  $current = $capacity if $current > $capacity;

  return $current;
}
