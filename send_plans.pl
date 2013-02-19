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
my @body_name;
my $ship_name;
my $stay = 0;
my $debug = 0;
my $quiet = 0;
my $wanted;
my $plan_type = "Halls of Vrbansk";
my $extra_levels = 0;
my $noaction;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "noaction|n!" => \$noaction,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
  "count=s"     => \$wanted,
  "ship=s"      => \$ship_name,
  "name|type=s" => \$plan_type,
  "extra=i"     => \$extra_levels,
) or die "$0 --config=foo.json --body=Bar --body=Baz --count=all\n";

die "Must specify two bodies\n" unless @body_name == 2;
#$ship_name ||= join(" ", @body_name);

die "Must specify count or all\n" unless $wanted =~ /^\d+|all$/i;

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my @body_id;
for my $id (keys(%$planets)) {
  $body_id[0] = $id if $planets->{$id} =~ /$body_name[0]/;
  $body_id[1] = $id if $planets->{$id} =~ /$body_name[1]/;
}
exit(1) if !$debug && $quiet && (!$body_id[0] || !$body_id[1]);
die "No matching planet for name $body_name[0]\n" unless $body_id[0];
die "No matching planet for name $body_name[1]\n" unless $body_id[1];

# get trade ministries, space ports, and ships for each planet
my @trade;
my @port;
for my $body_id (@body_id) {
  $debug and print "Looking at $planets->{$body_id}\n";
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

  my $trade = (grep($_->{name} eq "Trade Ministry", @buildings))[0];
  my $port  = (grep($_->{name} eq "Space Port",     @buildings))[0];

  die "No Trade Ministry on $planets->{$body_id}\n" unless $trade;
  die "No Space Port ". "on $planets->{$body_id}\n" unless $port;

  $debug and print "Got trade $trade->{id}, port $port->{id}\n";

  push(@trade, $trade);
  push(@port,  $port);
}

my @plans;
my $plans;

$plans  = $client->body_plans($body_id[0]);
@plans = @{$plans->{plans}};
@plans = grep { $_->{name} =~ /$plan_type/ && $_->{extra_build_level} == $extra_levels } @plans;

my $available = ($plans[0] || {})->{quantity} || 0;

$wanted = $available if $wanted eq "all";

die "Insufficient plans on $planets->{$body_id[0]}: only $available available\n" if $available < $wanted;

my $ships = $client->call(trade => get_trade_ships => $trade[0]{id}, $body_id[1]);
my @ships = grep($_->{name} !~ /(Alpha|Beta)$/ && $_->{task} eq "Docked" && $_->{hold_size} > 10 && ( ! $ship_name || $_->{name} =~ $ship_name ), @{$ships->{ships}});

for my $ship (@ships) {
  my $space = $ship->{hold_size};
  my @items;
  my $pc = 0;
  my $gc = 0;
  while (@plans && $space > $plans->{cargo_space_used_each}) {
    my $max = int($space / $plans->{cargo_space_used_each});
    my $plan = $plans[0];
    my $count = List::Util::min($max, $wanted);
    push(@items, { type => "plan", %$plan, quantity => $count });
    $space -= $count * $plans->{cargo_space_used_each};
    $pc += $count;
    $wanted -= $count;
    shift @plans unless $wanted;
  }
  if (@items) {
    emit("Sending $pc plans to $planets->{$body_id[1]} on $ship->{name}", $planets->{$body_id[0]});
    if ($noaction) {
      use Data::Dumper;
      emit( Data::Dumper->new([\@items])->Terse(1)->Sortkeys(1)->Dump() );
    }
    else {
      my $result = $client->trade_push(
        $trade[0]->{id}, $body_id[1], [ @items ],
        { ship_id => $ship->{id}, stay => $stay }
      );
    }
  }
}

sub emit {
  my $message = shift;
  my $name = shift;
  print Client::format_time(time())." $name: $message\n";
}
