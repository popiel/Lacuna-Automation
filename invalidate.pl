#!/usr/bin/perl

use strict;

use Carp;
use Client;
use DBI;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util qw(min max sum first);
use File::Path;
use POSIX qw(strftime);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my @types;
my $quiet;

GetOptions(
  "config=s"  => \$config_name,
  "body|b=s"  => \@body_names,
  "type|name=s" => \@types,
  "quiet" => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $empire_name = $client->empire_status->{name};

my $planets = $client->empire_status->{planets};

@body_names = values(%$planets) unless @body_names;
my @body_ids = map { $client->match_planet($_) } @body_names;
if ((@body_ids != @body_names)) {
  emit("Aborting due to identification errors", $empire_name);
  exit 1;
}
@body_ids = sort { $planets->{$a} cmp $planets->{$b} } @body_ids;
@body_names = map { $planets->{$_} } @body_ids;

@types = qw(buildable buildings) unless @types;

my @valid = qw(
  body_status
  buildings
  buildable
  spy_list
  spaceport_view_all_ships
  session
  plans
  glyphs
);

@types = map { my $t = $_; $t =~ s/\W//g; first { $_ =~ /$t/ } @valid } @types;

for my $body_id (@body_ids) {
  for my $type (@types) {
    emit("Invalidating $type", $body_id) if !$quiet;
    $client->cache_invalidate(type => $type, id => $body_id);
  }
}

sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." explorer: $prefix: $message\n";
}
