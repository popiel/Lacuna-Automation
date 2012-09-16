#!/usr/bin/perl

use strict;

use Carp;
use Client;
use DBI;
use Getopt::Long;
use IO::Handle;
use Data::Dumper;
use JSON::XS;
use List::Util qw(min max sum first);
use File::Path;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"                    => \$config_name,
  "body|planet|b=s"             => \@body_names,
  "debug|d+"                    => \$debug,
  "quiet"                       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client      = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};
my $planets     = $client->empire_status->{planets};

@body_names = values(%$planets) unless @body_names;
my @body_ids = map { $client->match_planet($_) } @body_names;
if ((@body_ids != @body_names)) {
  emit("Aborting due to identification errors", $empire_name);
  exit 1;
}
@body_names = map { $planets->{$_} } @body_ids;

my %goals = (
  1 => {
    "Subspace Transporter"  => { location => [ -1, 1 ] },
  },
  2 => {
    "Interdimensional Rift" => {},
    "Ravine"                => {},
    "Volcano"               => {},
    "Natural Spring"        => {},
    "Geo Thermal Vent"      => {},
    "food glyph"            => {},
  },
  3 => {
    "Space Port"            => { location => [  0, -1 ] },
    "Shipyard"              => { location => [  1, -1 ] },
    "Archaeology Ministry"  => { location => [ -1, -1 ] },
    "Observatory"           => { location => [ -1,  0 ] },
    "Trade Ministry"        => { location => [  0,  1 ] },
    "Ore Refinery"          => {},
    map { ("Lost City of Tyleon ($_)" => {}) } qw(A B C D E F G H I),
  },
  4 => {
    "Oversight Ministry"    => { level => 30 },
    "Archaeology Ministry"  => { level => 30 },
    "Space Port"            => { level => 15 },
  },
);

my %groups = (
  "food glyph" => [ "Algae Pond", "Amalgus Meadow", "Beeldeban Nest", "Denton Brambles", "Lapis Forest", "Malcud Field" ],
);

my @goals;
for my $priority (keys %goals) {
  for my $building (keys %{$goals{$priority}}) {
    push(@goals, { %{$goals{$priority}{$building}}, name => $building, priority => $priority });
  }
}

my @current;
for my $body_id (@body_ids) {
  my @missing = grep { ! eval { 
    my @buildings;
    for my $name (@{$groups{$_->{name}} || [ $_->{name} ]}) {
      push(@buildings, eval { $client->find_building($body_id, $name) });
    }
    @buildings = sort { $b->{level} <=> $a->{level} } @buildings;
    @buildings = @buildings[0..$_->{count}] if $_->{count} && @buildings > $_->{count};
    return @buildings >= $_->{count} && $buildings[$#buildings]{level} >= $_->{level};
  } } @goals;
  @missing = sort { $a->{priority} <=> $b->{priority} } @missing;
  @missing = grep { $_->{priority} <= $missing[0]{priority} } @missing;
  push(@current, map { { %$_, body_id => $body_id } } @missing);
}

emit_json("Current goals", \@current);

my @tasks;
for my $goal (@current) {
}

sub tasks_for_goal {
  my $goal = shift;

  my @buildings;
  for my $name (@{$groups{$_->{name}} || [ $_->{name} ]}) {
    push(@buildings, eval { $client->find_building($body_id, $name) });
  }
  $goal->{count} ||= 1;
  if (@buildings < $goal->{count}) {
#    { task => "build", name

  }
    @buildings = sort { $b->{level} <=> $a->{level} } @buildings;
    @buildings = @buildings[0..$_->{count}] if $_->{count} && @buildings > $_->{count};

}

sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." archaeologist: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
