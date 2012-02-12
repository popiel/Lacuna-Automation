#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $body_name;
my $debug;
my $glyph;
my $spy;

GetOptions(
  "config=s" => \$config_name,
  "debug!"   => \$debug,
  "glyph"    => \$glyph,
  "spy"      => \$spy,
) or die "$0 --config=foo.json\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

for my $body_id (keys(%$planets)) {
  $body_name = $planets->{$body_id};
  my $buildings = $client->body_buildings($body_id);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});
  my %buildings = map { $_->{name}, $_->{id} } @buildings;
  my $parliament = $buildings{Parliament};
  next unless $parliament;

  my $props = $client->call(parliament => view_propositions => $parliament);
  for my $prop (@{$props->{propositions}}) {
    next unless $prop->{name} =~ /^Upgrade|Install|Repair/;
    next if exists $prop->{my_vote};
    emit("Approving proposition $prop->{name}");
    my $result = eval { $client->call(parliament => cast_vote => $parliament, $prop->{id}, 1) };
    if (!$result) {
      if (my $e = Exception::Class->caught('LacunaRPCException')) {
        emit("Couldn't vote: ".$e->code." ".$e->text);
      } else {
        my $e = Exception::Class->caught();
        ref $e ? $e->rethrow : die $e;
      }
    }
  }
}

my @trash;
my $inbox = $client->call(inbox => 'view_inbox');
emit("inbox result: ".encode_json($inbox)) if $debug;
for my $message (@{$inbox->{messages}}) {
  emit("Inspecting message tag '@{$message->{tags}}'; subject '$message->{subject}'") if $debug;
  if ((grep(/Parliament/, @{$message->{tags}}) && $message->{subject} =~ /^(Pass: )?(Upgrade|Install|Repair)/) ||
      ($glyph && grep(/Alert/, @{$message->{tags}}) && $message->{subject} eq "Glyph Discovered!") ||
      ($spy && grep(/Spies|Intelligence/, @{$message->{tags}}) && $message->{subject} =~ /Put Me To Work|Mission Objective Missing|Appropriation Report/)) {
    emit("Trashing $message->{id}") if $debug;
    push(@trash, $message->{id});
  }
}
if (@trash) {
  my $result = $client->call(inbox => trash_messages => \@trash);
  emit("trash result: ".encode_json($result)) if $debug;
  my $count = @{$result->{success}};
  emit("Trashed $count inbox messages.");
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
