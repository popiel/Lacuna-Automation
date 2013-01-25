#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util qw(first min max sum);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $ship_name;
my $equalize = 0;
my $themepark = 0;
my $debug = 0;
my $quiet = 0;
my $noaction = 0;
my $do_waste = 1;
my $use_chain = 0;

GetOptions(
  "config=s"         => \$config_name,
  "body=s"           => \@body_names,
  "ship|name=s"      => \$ship_name,
  "debug"            => \$debug,
  "quiet"            => \$quiet,
  "noaction!"        => \$noaction,
  "waste!"           => \$do_waste,
  "use_chain|chain!" => \$use_chain,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify at least two bodies\n" unless @body_names >= 2;
$ship_name ||= join(" ", @body_names);

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my @order;
my %plan_count;
my $plan_type;
my $size_per_plan;
for my $name (@body_names) {
  my $body_id = first { $planets->{$_} =~ /$name/ } keys %$planets;
  die "No matching planet for name $name\n" unless $body_id;
  push(@order, $body_id);
  my $plans = $client->body_plans($body_id);
  my $halls = first { $_->{name} eq "Halls of Vrbansk" } @{$plans->{plans}};
  $plan_count{$body_id} = $halls ? $halls->{quantity} : 0;
  $plan_type ||= $halls->{plan_type};
  $size_per_plan = $plans->{cargo_space_used_each};
}

my $average = int(sum(values %plan_count) / @order);

for my $j (0..$#order) {
  my $body_id = $order[$j];
  my $next_id = $order[($j + 1) % @order];

  my $amount = $plan_count{$body_id} - $average;
  next if $amount <= 0;

  my @ships = sort { $b->{hold_size} <=> $a->{hold_size} }
              grep { $_->{name} =~ /$ship_name/ && $_->{task} eq "Docked" }
              @{$client->port_all_ships($body_id)->{ships}};
  die "No ships available for name $ship_name on planet $planets->{$body_id}\n" unless @ships;
  for my $ship (@ships) {
    last if $amount <= 0;
    my $actual = min(int($ship->{hold_size} / $size_per_plan), $amount);
    emit(($noaction ? "Would send" : "Sending")." $actual halls to $planets->{$next_id} on $ship->{name}", $planets->{$body_id});
    eval {
      $client->trade_push($client->find_building($body_id, "Trade Ministry")->{id}, $next_id,
        [ { type => "plan",
            plan_type => $plan_type,
            level => 1,
            extra_build_level => 0,
            quantity => $actual
        } ], { ship_id => $ship->{id} }) unless $noaction;
    };
    $amount -= $actual;
  }
}

sub emit {
  my $message = shift;
  my $name = shift;
  print Client::format_time(time())." $name: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::PP->new->allow_nonref->canonical->pretty->encode($hash);
}
