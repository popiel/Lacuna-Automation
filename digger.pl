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
my $debug = 0;
my $noaction = 0;
my $quiet = 0;

GetOptions(
  "config=s"  => \$config_name,
  "body|b=s"  => \@body_names,
  "debug+"    => \$debug,
  "noaction"  => \$noaction,
  "quiet"     => \$quiet,
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

my %arches = map { ($_, scalar(eval { $client->find_building($_, "Archaeology Ministry") } )) } @body_ids;

@body_ids = grep { $arches{$_} } @body_ids;

emit("Looking at bodies ".join(', ', @body_names));

exit(0) unless grep { !($_->{work}{end}) || Client::parse_time($_->{work}{end}) < time() } values(%arches);

my %glyphs;
for my $body_id (@body_ids) {
  my $glyphs = $client->get_glyphs($arches{$body_id}{id});
  for my $glyph (@{$glyphs->{glyphs}}) {
    $glyphs{$glyph->{type}}++;
  }
}

my @recipes = (
  [ qw(goethite halite gypsum trona) ],
  [ qw(gold anthracite uraninite bauxite) ],
  [ qw(kerogen methane sulfur zircon) ],
  [ qw(monazite fluorite beryl magnetite) ],
  [ qw(rutile chromite chalcopyrite galena) ],
);

my %bias;
for my $recipe (@recipes) {
  my $average = sum(map { $glyphs{$_} } @$recipe) / @$recipe;
  for my $ore (@$recipe) {
    $bias{$ore} = $glyphs{$ore} - $average;
  }
  emit(sprintf("%5d %-12s %5d %-12s %5d %-12s %5d %-12s", map { $glyphs{$_}, $_ } @$recipe));
}

for my $body_id (@body_ids) {
  next if Client::parse_time($arches{$body_id}{work}{end}) > time();
  my $ores = $client->ores_for_search($arches{$body_id}{id});
  my @ores = sort { $bias{$a} <=> $bias{$b} } keys (%{$ores->{ore}});
  if (@ores) {
    emit("Searching for $ores[0] glyph", $body_id);
    $noaction or $client->archaeology_search($arches{$body_id}{id}, $ores[0]);
    $bias{$ores[0]}++;
  }
}

sub emit {
  my $message = shift;
  my $prefix = shift;
  $prefix ||= $empire_name;
  my $planets = $client->empire_status->{planets};
  $prefix = $planets->{$prefix} if $planets->{$prefix};
  print Client::format_time(time())." digger: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
