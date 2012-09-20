#!/usr/bin/perl

# newpie_pack script initially requested by United Federation

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util qw(min max sum first);
use File::Path;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
our $body_name;
local $body_name;
my $queue_name;
my $debug = 0;
my $quiet = 0;
my $no_action = 1;
my @plan_list;
my $price = 0.1;
my $max_offers = 1000;

GetOptions(
  "config=s"   => \$config_name,
  "body=s"     => \$body_name,
  "plans=s"    => \@plan_list,
  "price=s"    => \$price,
  "debug"      => \$debug,
  "quiet"      => \$quiet,
  "max-offers" => \$max_offers,
  "noaction!"  => \$no_action,
) or die "$0 --config=foo.json --body=Bar --plan=Volcano --price=2\n";

# $body_name ||= "UF Command";
@plan_list or @plan_list = split(", ", q(Algae Pond, Amalgus Meadow, Beeldeban Nest, Denton Brambles, Lapis Forest, Malcud Field, Natural Spring, Geo Thermal Vent, Volcano, Interdimensional Rift, Kalavian Ruins));

my $client = Client->new(config => $config_name);

my $planets = $client->empire_status->{planets};
my $body_id = first { $planets->{$_} =~ /$body_name/ } keys %$planets;
die "Unknown planet: $body_name\n" unless $body_id;
$body_name = $planets->{$body_id};

my $trade = $client->find_building($body_id, "Trade Ministry");

my $plans = $client->body_plans($body_id);
my %plan_types = map { ($_->{name}, $_->{plan_type}) } @{$plans->{plans}};
my @plan_types = map { $plan_types{$_} } @plan_list;

my $offers = $client->call(trade => view_my_market => $trade->{id});
my @offers = grep { $_->{offer}[0] eq "1 $plan_list[0] (1) plan" } @{$offers->{trades}};
if (@offers < $max_offers) {
  eval {
    my $ships = $client->call(trade => get_trade_ships => $trade->{id});
    my @ships = grep { $_->{type} eq "smuggler_ship" } @{$ships->{ships}};
    if (@ships) {
      last unless @ships;
      $client->call(trade => add_to_market => $trade->{id},
        [ map { { type => "plan", plan_type => $plan_types{$_},
                  level => 1, extra_build_level => 0, quantity => 1 } }
              @plan_list ],
        $price, { ship_id => $ships[0]->{id} });
      shift(@ships);
      emit("Added trade");
    } else {
      emit("No smuggler ships available");
    }
    1;
  } or emit("Could not add trade: $@");
} else {
  emit("Already have $max_offers trades posted.");
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." post_trade: $body_name: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
