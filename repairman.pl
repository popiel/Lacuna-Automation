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
my $all_bodies = 0;
my $queue_name;
my $debug = 0;
my $quiet_no_body = 0;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "all-bodies" => \$all_bodies,
  "debug"    => \$debug,
  "quiet_no_body"    => \$quiet_no_body,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  exit(1) unless $body_id || !$quiet_no_body;
  die "No matching planet for name $body_name\n" unless $body_id;
  repair($body_id);
} elsif($all_bodies) {
    my $planets = $client->empire_status->{planets};
    repair($_) for keys(%$planets);
} else {
  $body_id = $client->empire_status->{home_planet_id};
  repair($body_id);
}

sub repair {
  my $body_id = shift;

  my $buildings = $client->body_buildings($body_id);
  $body_name = $client->body_status($body_id)->{name};

  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

  my @cost;
  for my $building (@buildings) {
    next if $building->{efficiency} == 100;
    my $view = $client->building_view($building->{url}, $building->{id})->{building};
    my $cost = List::Util::sum( values %{ $view->{repair_costs} } );
    if ( $cost == 0 ) {
      $client->building_repair($building->{url}, $building->{id});
      emit("Repaired $building->{name} from $building->{efficiency}%");
    }
    else {
      push @cost, [ $building, $cost ];
    }
  }

  my @sorted = map $_->[0], sort { $a->[1] <=> $b->[1] } @cost;

  while (@sorted) {
    # By default, repair the cheapest first
    my $pick = $sorted[0];

    # Repair platforms first if we're at negative plots
    if ($client->body_status($body_id)->{plots_available} < 0) {
      my @platforms_first = (
        grep { $_->{url} =~ /platform/ } @sorted,
        grep { $_->{url} !~ /platform/ } @sorted,
      );
      $pick = $platforms_first[0];
    }

    # If we're repairing a Tyleon, repair the most expensive one
    if ($pick->{name} =~ /Tyleon/) {
      my @tyleons = grep { $_->{name} =~ /Tyleon/ } @sorted;
      $pick = $tyleons[$#tyleons];
    }

    @sorted = grep { $_ ne $pick } @sorted;

    $client->building_repair($pick->{url}, $pick->{id});
    emit("Repaired $pick->{name} from $pick->{efficiency}%");
  }
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
