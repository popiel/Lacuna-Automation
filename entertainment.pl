#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;
use List::Util;

my $config_name = "config.json";
my $sleep = 1;

GetOptions(
  "config=s" => \$config_name,
  "sleep!" => \$sleep,
) or die "$0 --config=foo.json --body=Bar\n";

sleep(900 + rand() * 900) if $sleep;

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my @links;
for my $id (keys(%$planets)) {
  my $buildings = $client->body_buildings($id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my $ed = (grep($_->{name} eq "Entertainment District", @buildings))[0];
  if ($ed) {
    my $result = eval { $client->call(entertainment => get_lottery_voting_options => $ed->{id}) };
    if ($result) {
      emit("Got ".scalar(@{$result->{options}})." entertainment links", $id);
      push(@links, map { { body_id => $id, %$_ } } @{$result->{options}});
    }
  }
}
@links = List::Util::shuffle(@links);
my %visited;
for my $link (@links) {
  next if $visited{$link->{name}};
  $visited{$link->{name}}++;
  emit("Visiting $link->{name} at $link->{url}", $link->{body_id});
  `GET '$link->{url}'`;
  sleep(10 + rand() * 15);
}

sub emit {
  my $message = shift;
  my $body_id = shift;
  my $body_name = $planets->{$body_id};
  print Client::format_time(time())." $body_name: $message\n";
}
