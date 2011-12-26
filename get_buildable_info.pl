#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

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

my %buildings;

my $result = $client->body_buildable($body_id);
for my $name (keys %{$result->{buildable}}) {
  my $building = $result->{buildable}{$name};
  $buildings{$name}{1}{cost} = $building->{build}{cost};
  my %production;
  my %capacity;
  for my $resource (qw(food ore water energy waste happiness)) {
    $production{$resource} = $building->{production}{"${resource}_hour"};
    $capacity{$resource} = $building->{production}{"${resource}_capacity"};
  }
  $buildings{$name}{1}{production} = { %production };
  $buildings{$name}{1}{capacity} = { %capacity };
}

my $result = $client->body_buildings($body_id);
for my $id (keys %{$result->{buildings}}) {
  my $name = $result->{buildings}{$id}{name};
  my $url = $result->{buildings}{$id}{url};
  next if $buildings{$name}{2};
  for my $level (1..10) {
warn "Fetching stats for $level $name\n";
    my $info = $client->building_stats_for_level($url, $id, $level);
    unless ($buildings{$name}{$level}{production}) {
      my %production;
      my %capacity;
      for my $resource (qw(food ore water energy waste happiness)) {
        $production{$resource} = $info->{building}{"${resource}_hour"};
        $capacity{$resource} = $info->{building}{"${resource}_capacity"};
      }
      $buildings{$name}{$level}{production} = { %production };
      $buildings{$name}{$level}{capacity} = { %capacity };
    }
    my %production;
    my %capacity;
    for my $resource (qw(food ore water energy waste happiness)) {
      $production{$resource} = $info->{building}{upgrade}{production}{"${resource}_hour"};
      $capacity{$resource} = $info->{building}{upgrade}{production}{"${resource}_capacity"};
    }
    $buildings{$name}{$level}{upgrade} = $info->{building}{upgrade}{cost};
    $buildings{$name}{$level+1}{production} = { %production };
    $buildings{$name}{$level+1}{capacity} = { %capacity };
  }
}

print encode_json({%buildings})."\n";
