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

my %zones;
for my $id (List::Util::shuffle(keys(%$planets))) {
  my $buildings = $client->body_buildings($id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_, body_id => $id } } keys(%{$buildings->{buildings}});
  my $ed = (grep($_->{name} eq "Entertainment District", @buildings))[0];
  if ($ed) {
    $zones{$buildings->{status}{body}{zone}} = $ed;
  }
}

my $tries = 3;
for my $ed (List::Util::shuffle(values(%zones))) {
  my $result;
  do {
    $result = eval { $client->call(entertainment => get_lottery_voting_options => $ed->{id}) };
    if ($tries > 0 && $result && !@{$result->{options}}) {
      emit("No entertainment links, sleeping", $ed->{body_id});
      sleep(900 + rand() * 900);
    }
  } while ($tries-- > 0 && (!$result || !@{$result->{options}}));
  if ($result) {
    emit("Got ".scalar(@{$result->{options}})." entertainment links", $ed->{body_id});
    for my $link (List::Util::shuffle(@{$result->{options}})) {
        if ($link) {
          emit("Visiting $link->{name} at $link->{url}", $ed->{body_id});
          `GET '$link->{url}'`;
          sleep(10 + rand() * 15);
        }
    }
  }
}

sub emit {
  my $message = shift;
  my $body_id = shift;
  my $body_name = $planets->{$body_id};
  print Client::format_time(time())." entertainment: $body_name: $message\n";
}
