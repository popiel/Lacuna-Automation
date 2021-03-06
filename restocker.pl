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
my $min_exchange = 2000;

$min_exchange = 100 if (gmtime(time))[2] == 23; # Be more eager to exchange at the end of the RPC day

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "debug"    => \$debug,
  "quiet"    => \$quiet,
  "min_exchange|minexchange=i" => \$min_exchange,
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

my $embassy = (grep($_->{name} eq "Embassy", @buildings))[0];
$embassy or do { emit("No Embassy"); exit(1); };

my $result = $client->call(embassy => view_stash => $embassy->{id});
exit(0) unless $result->{exchanges_remaining_today};
my %stored = %{$result->{stored}};
my %stash  = %{$result->{stash}};

my %resources = (%stored, %stash);

my $ideal = int(500000 / 44); # stash capacity / types
my %delta = map { $_ => $ideal - $stash{$_} } keys %resources;

# emit(join("\n", "Delta stash:", map { sprintf("%9d %s", $delta{$_}, $_) } sort keys(%resources))) if $debug;

my %give = map { $_ => List::Util::min($stored{$_}, $delta{$_}) } grep { $delta{$_} > 0 && $stored{$_} > 0 } keys %resources;
my $amount = List::Util::sum(values(%give));
if ($amount < $min_exchange) {
  emit("Too little to exchange: $amount");
  exit(0);
}
while (List::Util::sum(values(%give)) > $result->{max_exchange_size}) {
  emit("Reducing exchange size: ".List::Util::sum(values(%give))." > $result->{max_exchange_size}") if $debug;
  my $which = List::Util::first { $give{$b} <=> $give{$a} } keys %give;
  emit("Eliminating $give{$which} $which") if $debug;
  delete $give{(sort { $give{$b} <=> $give{$a} } keys %give)[0]};
}

my %extra = map { $_ => -$delta{$_} } grep { $delta{$_} < 0 } keys %stash;
my %take = $client->select_exchange(\%stored, \%extra, \%give);

emit(join("\n", "Final stash:", map { sprintf("%9d %s", $stash{$_} + $give{$_} - $take{$_}, $_) } sort keys(%resources))) if $debug;
emit("Exchanging ". join(", ", map { "$give{$_} $_" } sort keys(%give)). " for ". join(", ", map { "$take{$_} $_" } sort keys(%take)));
emit("Totals ". List::Util::sum(values(%give)). " for ". List::Util::sum(values(%take))) if $debug;
eval { $client->call(embassy => exchange_with_stash => $embassy->{id}, { %give }, { %take }); };

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
