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
my @body_name;
my $ship_name;
my $for_name;
my $equalize = 0;
my $debug = 0;
my $quiet = 0;
my $hall_count = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "count=i"     => \$hall_count,
  "for=s"       => \$for_name,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify body\n" if $hall_count && !@body_name;

my $client = Client->new(config => $config_name);
eval {
  warn "Getting empire status\n" if $debug;
  my $planets = $client->empire_status->{planets};

  my $for_id;
  if ($for_name) {
    $for_id = (grep { $planets->{$_} =~ /$for_name/ } keys(%$planets))[0];
    die "No matching planet for name $for_name\n" if $for_name && !$for_id;
    $for_name = $planets->{$for_id};
  }

  push(@body_name, sort values(%$planets)) unless @body_name;
  warn "Looking at bodies ".join(", ", @body_name)."\n" if $debug;
  for my $body_name (@body_name) { 
    eval {
      my $body_id;
      for my $id (keys(%$planets)) {
        $body_id = $id if $planets->{$id} =~ /$body_name/;
      }
      exit(1) if $quiet && !$body_id;
      die "No matching planet for name $body_name\n" unless $body_id;

      # get archaeology
      warn "Getting body buildings for $planets->{$body_id}\n" if $debug;
      my $buildings = $client->body_buildings($body_id);
      my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

      my $arch_id = (grep($_->{name} eq "Archaeology Ministry", @buildings))[0]{id};
      unless ($arch_id) {
        warn "No Archaeology Ministry on $planets->{$body_id}\n";
        next;
      }
      warn "Using Archaeology Ministry id $arch_id\n" if $debug;

      warn "Getting glyphs on $planets->{$body_id}\n" if $debug;
      my $glyphs = $client->call(archaeology => get_glyphs => $arch_id);
      unless ($glyphs->{glyphs}) {
        warn "No glyphs on $planets->{$body_id}\n";
        next;
      }

      my @recipes = (
        [ qw(goethite halite gypsum trona) ],
        [ qw(gold anthracite uraninite bauxite) ],
        [ qw(kerogen methane sulfur zircon) ],
        [ qw(monazite fluorite beryl magnetite) ],
        [ qw(rutile chromite chalcopyrite galena) ],
      );

      my %glyphs = map { ($_, []) } map { @$_ } @recipes;
      for my $glyph (@{$glyphs->{glyphs}}) {
        push(@{$glyphs{$glyph->{type}}}, $glyph->{id});
      }

      my %extra;
      my %possible;
      for my $recipe (@recipes) {
        my $min = List::Util::min(map { scalar(@{$glyphs{$_}}) } @$recipe);
        $possible{$recipe} = $min;
        for my $glyph (@$recipe) {
          $extra{$glyph} = @{$glyphs{$glyph}} - $min;
        }
      }

      my $max_halls = List::Util::sum(values(%possible));
      print "Can make $max_halls halls with ".List::Util::sum(values(%extra))." unmatched glyphs on $planets->{$body_id}.\n";

      die "Insufficient glyphs to make $hall_count halls\n" if $max_halls < $hall_count;

      while ($max_halls > $hall_count) {
        for my $recipe (@recipes) {
          last if $max_halls <= $hall_count;
          if ($possible{$recipe}) { $possible{$recipe}--; $max_halls--; }
        }
      }

      for my $recipe (@recipes) {
        while ($possible{$recipe}--) {
          my @ids;
          for my $glyph (@$recipe) {
            push(@ids, pop(@{$glyphs{$glyph}}));
          }
          print "Making hall with ".join(", ", @$recipe).": ".join(", ", @ids)."\n";
          my $result = $client->call(archaeology => assemble_glyphs => $arch_id, [ @ids ]);
          print "Failed to make hall!\n" if $result->{item_name} ne "Halls of Vrbansk";
        }
      }

      if ($for_id) {
        my $trade_id = (grep($_->{name} eq "Trade Ministry", @buildings))[0]{id};
        unless ($trade_id) {
          warn "No Trade Ministry on $planets->{$body_id}\n";
          next;
        }
        warn "Using Trade Ministry id $trade_id\n" if $debug;

        my $plans = $client->call(trade => get_plans => $trade_id);
        my $psize = $plans->{cargo_space_used_each};
        my @plans = grep { $_->{name} eq "Halls of Vrbansk" } @{$plans->{plans}};
        $#plans = $hall_count - 1 if @plans > $hall_count;

        my @ships = @{$client->call(trade => get_trade_ships => $trade_id, $for_id)->{ships}};
        # Avoid ships already allocated to trade routes
        @ships = grep { $_->{name} !~ /(Alpha|Beta|Gamma|Delta)$/ } @ships;

        $_->{plan_count} = int($_->{hold_size} / $psize) for @ships;

        # Choose fast ships sufficient to carry all the plans
        @ships = sort { $b->{speed} <=> $a->{speed} } @ships;
        my $top = 0;
        my $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $hall_count;
        $#ships = $top;
        print "Can only ship $move_count halls. :-(\n" if $move_count < $hall_count;

        # Choose the big ships from among the sufficient chosen ships (and free up any extra fast small ships)
        @ships = sort { $b->{hold_size} <=> $a->{hold_size} } @ships;
        $top = 0;
        $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $hall_count;
        $#ships = $top;

        for my $ship (@ships) {
          my @items;
          push(@items, { type => "plan", plan_id => (shift(@plans))->{id} }) while @plans && @items < $ship->{plan_count};
          print "Pushing ".scalar(@items)." halls to $for_name on $ship->{name}.\n";
          $client->trade_push($trade_id, $for_id, \@items, { ship_id => $ship->{id}, stay => 0 });
        }
      }
    }
  }
};
