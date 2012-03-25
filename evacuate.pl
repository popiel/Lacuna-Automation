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
my $do_plans;
my $do_glyphs;
my $do_tyleon;
my $do_sculpture;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "stay!"       => \$stay,
  "debug"       => \$debug,
  "glyphs!"     => \$do_glyphs,
  "plans!"      => \$do_plans,
  "tyleon!"     => \$do_tyleon,
  "sculpture!"  => \$do_sculpture,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

if (!$do_glyphs && !$do_plans && !$do_tyleon) {
  $do_glyphs    = 1 unless defined $do_glyphs;
  $do_plans     = 1 unless defined $do_plans;
  $do_tyleon    = 1 unless defined $do_tyleon;
  $do_sculpture = 1 unless defined $do_sculpture;
}
if (defined($do_plans) && !defined($do_tyleon)) {
  $do_tyleon = $do_plans;
}
if (defined($do_plans) && !defined($do_sculpture)) {
  $do_sculpture = $do_plans;
}

die "Must specify two bodies\n" unless @body_name == 2;
$ship_name ||= join(" ", @body_name);

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
my @glyphs;

my $plans;
my $glyphs;

if ($do_plans || $do_tyleon || $do_sculpture) {
  $plans  = $client->call(trade => get_plans  => $trade[0]{id});
  @plans = @{$plans->{plans}};
  @plans = grep { $_->{name} ne "Halls of Vrbansk" } @plans;
  @plans = grep { $_->{name} !~ /Tyleon/ } @plans unless $do_tyleon;
  @plans = grep { $_->{name} !~ /Sculpture/ } @plans unless $do_sculpture;
  @plans = grep { $_->{name} =~ /Tyleon|Sculpture/ } @plans unless $do_plans;
}

if ($do_glyphs) {
  $glyphs = $client->call(trade => get_glyphs => $trade[0]{id});
  @glyphs = @{$glyphs->{glyphs}};
}

exit(0) unless @plans || @glyphs;

my $ships = $client->call(trade => get_trade_ships => $trade[0]{id}, $body_id[1]);
my @ships = grep($_->{name} !~ /(Alpha|Beta)$/ && $_->{task} eq "Docked" && $_->{hold_size} > 10, @{$ships->{ships}});

for my $ship (@ships) {
  my $space = $ship->{hold_size};
  my @items;
  my $pc = 0;
  my $gc = 0;
  while (@plans && $space > $plans->{cargo_space_used_each}) {
    my $plan = shift @plans;
    push(@items, { type => "plan", plan_id => $plan->{id} });
    $space -= $plans->{cargo_space_used_each};
    $pc++;
  }
  while (@glyphs && $space > $glyphs->{cargo_space_used_each}) {
    my $glyph = shift @glyphs;
    push(@items, { type => "glyph", glyph_id => $glyph->{id} });
    $space -= $glyphs->{cargo_space_used_each};
    $gc++;
  }
  if (@items) {
    emit("Sending $pc plans and $gc glyphs to $planets->{$body_id[1]} on $ship->{name}", $planets->{$body_id[0]});
    my $result = $client->trade_push(
      $trade[0]->{id}, $body_id[1], [ @items ],
      { ship_id => $ship->{id}, stay => $stay }
    );
  }
}

sub emit {
  my $message = shift;
  my $name = shift;
  print Client::format_time(time())." $name: $message\n";
}
