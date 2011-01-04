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
my @body_name;
my $ship_name;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"    => \$config_name,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

for my $body_id (sort { $planets->{$a} cmp $planets->{$b} } keys %$planets) {
  my $body_name = $planets->{$body_id};
  print "$body_name:\n";
  my $buildings = $client->body_buildings($body_id);
  my $construction = 0;
  my @messages;
  for my $building_id (keys %{$buildings->{buildings}}) {
    my $building = $buildings->{buildings}{$building_id};
    if ($building->{pending_build}) {
      my $stamp = "  Finishing ".Client::format_time(Client::parse_time($building->{pending_build}{end}));
      if ($building->{level}) {
        push(@messages, "$stamp: UPGRADING $building->{level} $building->{name}");
      } else {
        push(@messages, "$stamp: BUILDING $building->{name}");
      }
      $construction = 1;
    }
    if ($building->{work}) {
      my $stamp = "  Finishing ".Client::format_time(Client::parse_time($building->{work}{end}));
      push(@messages, "$stamp: Working $building->{level} $building->{name}");
    }
  }
  print map { "$_\n" } sort @messages;
  print "  NO CONSTRUCTION!\n" unless $construction;
  print "\n";
}
