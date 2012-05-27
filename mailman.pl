#!/usr/bin/perl

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
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"  => \$config_name,
  "debug"     => \$debug,
  "quiet"     => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};

#         "assigned_to" : {
#            "body_id" : "791268",
#            "name" : "Ouv Oozagh 5",
#            "x" : "-245",
#            "y" : "1245"
#         },

my $planets = $client->empire_status->{planets};

sub match_planet {
  my $name = shift;
  my $planets = $client->empire_status->{planets};
  my @candidates = grep { $planets->{$_} =~ /$name/ } keys %$planets;
  return $candidates[0] if @candidates == 1;
  emit("Planet name $name not found", $empire_name) unless @candidates;
  emit("Planet name $name is ambiguous: ".join(", ", map { $planets->{$_} } @candidates), $empire_name);
  return;
}

my $lottery;

for (;;) {
  my @trash;
  my $inbox = $client->call(inbox => 'view_inbox');
  emit_json("inbox result", $inbox) if $debug;
  for my $message (@{$inbox->{messages}}) {
    emit("Inspecting message tag '@{$message->{tags}}'; subject '$message->{subject}'") if $debug;
    if (grep(/Alert/, @{$message->{tags}}) &&
        $message->{subject} =~ /Excavator Deployed|Glyph Discovered|We Won The Lottery/) {
      $lottery++ if $message->{subject} =~ /We Won The Lottery/;
      emit("Trashing $message->{id}") if $debug;
      push(@trash, $message->{id});
    }
    if (grep(/Trade/, @{$message->{tags}}) &&
        $message->{subject} =~ /Trade Withdrawn/) {
      emit("Trashing $message->{id}") if $debug;
      push(@trash, $message->{id});
    }
  }
  last unless @trash;

  my $result = $client->call(inbox => trash_messages => \@trash);
  emit("trash result: ".encode_json($result)) if $debug;
  my $count = @{$result->{success}};
  emit("Trashed $count inbox messages.");
}

emit("Won $lottery lotteries!") if $lottery;


sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." mailman: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
