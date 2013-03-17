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
  my @archive;
  my $inbox = $client->mail_inbox();
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
    if (grep(/Excavator/, @{$message->{tags}}) &&
        $message->{subject} =~ /Excavator Results|Excavator Deployed/) {
      # my $detail = $client->call(inbox => read_message => $message->{id});
      my $detail = $client->mail_message($message->{id});
      my $body_id = '';
      $body_id = $1 if $detail->{message}{body} =~ /\{Planet (\d+)/;
      my @replacements = grep { $_->[1] eq "Replace" && $_->[2] !~ /^Fail/ } @{$detail->{message}{attachments}{table}};
      my @targets = map { $_->[0] } @replacements;
      push(@targets, $1) if !@replacements && $detail->{message}{body} =~ /deployed on \{Starmap -?\d+ -?\d+ ([^}]+)\}/;
      if (@targets) {
        emit("Excavator replacement for ".join(", ", @targets)."; invalidating ship list.", $body_id);
        $client->cache_invalidate( type => 'spaceport_view_all_ships', id => $body_id );
        $client->cache_invalidate( type => 'excavators',               id => $body_id );
      }
      emit("Trashing $message->{id}") if $debug;
      push(@trash, $message->{id});
    }
    if ($client->{email_forward} && grep(/Correspondence/, @{$message->{tags}})) {
      emit("Forwarding to real mail: [$message->{from}] $message->{subject}");
      my $detail = $client->call(inbox => read_message => $message->{id});
      open(MAIL, "|-", "mail", "-s", "[Lacuna] [$message->{from}] $message->{subject}", $client->{email_forward}) || die "Couldn't send email";
      my $text = $detail->{message}{body};
      $text =~ s/\\n/\n/g;
      print MAIL $text;
      close(MAIL);
      push(@archive, $message->{id});
      # forward
    }
    if (grep(/Probe/, @{$message->{tags}}) && !$message->{has_read}) {
      my $detail = $client->call(inbox => read_message => $message->{id});
      if ($detail->{message}{body} =~ /\{Empire \d+ (last|kiamo|fireartist|Cryptomega|Kreeact)\}/) {
        emit("Trashing $message->{id}") if $debug;
        push(@trash, $message->{id});
      }
    }
    
  }
  if (@archive) {
    my $result = $client->mail_archive(\@archive);
    my $count = @{$result->{success}};
    emit("Archived $count inbox messages.");
  }
  last unless @trash;

  my $result = $client->mail_trash(\@trash);
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
