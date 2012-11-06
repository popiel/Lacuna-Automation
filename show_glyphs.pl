#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use List::Util qw(sum);
use JSON::PP;

my $config_name = "config.json";
my @body_name;
my @glyph_name;
my $total_only;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \@body_name,
  "name|glyph|n=s"   => \@glyph_name,
  "total!"   => \$total_only,
) or die "$0 --config=foo.json --body=Bar --total_only\n";

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %glyphs;
for my $body_id (keys(%$planets)) {
  my $body_name = $planets->{$body_id};
  next unless !@body_name || grep { $body_name =~ /$_/i } @body_name;

  my $glyphs = eval { $client->glyph_list($body_id) };
  next unless $glyphs;

  printf("Got %d glyphs from %s\n", sum(map { $_->{quantity} } @{$glyphs->{glyphs}}), $body_name);
  for my $glyph (@{$glyphs->{glyphs}}) {
    $glyphs{$glyph->{name}} ||= {};
    $glyphs{$glyph->{name}}{$body_name} = $glyph->{quantity};
  }
}
print "----\n";
for my $name (sort keys %glyphs) {
  next unless !@glyph_name || grep { $name =~ /$_/i } @glyph_name;
  my $glyphs = $glyphs{$name};
  my $total = sum(values %$glyphs);
  printf("%5d %-30s\n", $total, $name);
  unless ($total_only) {
    for my $body (sort keys %$glyphs) {
      printf("  %5d %s\n", $glyphs->{$body}, $body);
    }
  }
}
