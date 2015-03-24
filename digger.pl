#!/usr/bin/perl

use v5.14;
use strict;
use warnings;
use Carp;
use Client;
use DBI;
use Data::Dumper; $Data::Dumper::Indent = 1;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util qw(min max sum first);
use File::Path;
use POSIX qw(strftime);

autoflush STDOUT 1;
autoflush STDERR 1;

my $help = 0;
my $config_name = "config.json";
my @body_names;
my $debug = 0;
my $noaction = 0;
my $quiet = 0;
my $repeat = 0;
my $skipSS = 0;

GetOptions(
  "help"    => \$help,
  "config=s"  => \$config_name,
  "body|b=s@"  => \@body_names,
  "debug+"    => \$debug,
  "noaction"  => \$noaction,
  "quiet"     => \$quiet,
  "repeat"  => \$repeat,
  'skipSS=s'  => \$skipSS,
) or usage ();
usage () if ( $help );

my $client;
my $rpccount;
my $empire_name;
my $restart = 0;
my $sleepy = 0;

do {
    $client = Client->new(config => $config_name, rpc_sleep => 1);
    $rpccount = $client->empire_status->{rpc_count};
    $empire_name = $client->empire_status->{name};
    print "Starting RPC: $rpccount\n";
    my $planets = $client->empire_status->{planets};
    my $skipping = 1 unless @body_names;
    @body_names = values(%$planets) unless @body_names;
    if ( $skipping ) {
      if ( $skipSS ) {
        foreach my $removeSS ( @body_names) {
          @body_names = grep { !/$skipSS/ } @body_names;
        }
      }
    }
    my @body_ids = map { $client->match_planet($_) } @body_names;
    if ((@body_ids != @body_names)) {
      emit("Aborting due to identification errors", $empire_name);
      exit 1;
    }
    @body_ids = sort { $planets->{$a} cmp $planets->{$b} } @body_ids;
    @body_names = map { $planets->{$_} } @body_ids;

    my %arches = map { ($_, scalar(eval { $client->find_building($_, "Archaeology Ministry") } )) } @body_ids;
    @body_ids = grep { $arches{$_} && $arches{$_}{level} } @body_ids;

    emit("Looking at bodies ".join(', ', @body_names));
### Made a new workaround, for those times the script crashes and you need to restart it, so I am killing this next line.
#    exit(0) unless $noaction || grep { $_ && !($_->{work}{end} && Client::parse_time($_->{work}{end}) >= time()) } values(%arches);

    my %glyphs;
    for my $body_id (@body_ids) {
      my $summary = eval { $client->glyph_list($body_id) };
      if (!$summary) {
        warn "Couldn't get glyphs on $planets->{$body_id}: $@\n";
        next;
      }
      $glyphs{$_->{name}} += $_->{quantity} for @{$summary->{glyphs}};
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
      my @sorted = sort { $a <=> $b } map { $glyphs{$_} || 0 } @$recipe;
      my $average = ($sorted[0] + $sorted[1]) / 2;
      for my $ore (@$recipe) {
        $bias{$ore} = $glyphs{$ore} - $average;
      }
      emit(sprintf("%5d %-12s %5d %-12s %5d %-12s %5d %-12s", map { $glyphs{$_}, $_ } @$recipe));
      emit(sprintf("  %5d %-12s %5d %-12s %5d %-12s %5d %-12s", map { $bias{$_}, "bias" } @$recipe));
    }

    for my $body_id (@body_ids) {
      my $end = Client::parse_time($arches{$body_id}{work}{end}) || 0;
      ### New code to detect if you are restarting the script for some reason before the first planet that would
      ### normally be checked has finished it's current dig (the script crashed, comp died, etc). If that first
      ### planet is still digging, go to sleep until it finishes, then continue onwards.
      my $cplanet = $planets->{$body_id};
      if ( $restart == 0 && $end > time() ) {
        $restart++;
        my $secs = (($end - time())+30);
        my $then = Client::format_time((time())+$secs);
        say "This Archministry on $cplanet is still digging, sleeping for ",sec2str($secs),".  Will continue at $then.";
        sleep $secs;
        say "Continuing now.";
        }
      elsif ( $restart == 0 ) {
        $restart++;
      }
      if ( $end > time() ) {
        say "This Archministry on $cplanet is still digging, skipping. Will be checked next run.";
        next;
      } ### End of new code.
      my $ores = $client->ores_for_search($arches{$body_id}{id});
      my @ores = sort { $bias{$a} <=> $bias{$b} } keys (%{$ores->{ore}});
      @ores = grep { $bias{$_} < 0 } @ores;
      if (@ores) {
        emit("Searching for $ores[0] glyph (bias $bias{$ores[0]})", $body_id);
        $noaction or $client->archaeology_search($arches{$body_id}{id}, $ores[0]);
        $bias{$ores[0]}++;
        next;
      }
      my $embassy = eval { $client->find_building($body_id, "Embassy"); };
      if (!$embassy) {
        emit("Build an embassy to search for more important glyphs", $body_id);
      } else {
        my $result = $client->call(embassy => view_stash => $embassy->{id});
        if (!($result->{exchanges_remaining_today} && $result->{max_exchange_size} >= 10000)) {
          emit("Upgrade your embassy to search for more important glyphs", $body_id);
        } else {
          my %stored = %{$result->{stored}};
          my %stash  = %{$result->{stash}};

          @ores = sort { $bias{$a} <=> $bias{$b} } keys %bias;
          @ores = grep { $stash{$_} >= 10000 && $bias{$_} <= 0 } @ores;
          if (!@ores) {
            emit("Restock your embassy to search for more important glyphs", $body_id);
          } else {
            my %wanted = ( $ores[0] => 10000 );
            my %extra = map { $_, $stored{$_} } keys %bias;
            delete $extra{$ores[0]};
            my %giving = $client->select_exchange(\%stash, \%extra, \%wanted);
            emit("Exchanging ". join(", ", map { "$giving{$_} $_" } keys(%giving)). " for ". join(", ", map { "$wanted{$_} $_" } keys(%wanted)));
            $noaction or eval { $client->call(embassy => exchange_with_stash => $embassy->{id}, { %giving }, { %wanted }); };
            emit("Searching for $ores[0] glyph (bias $bias{$ores[0]})", $body_id);
            $noaction or eval { $client->archaeology_search($arches{$body_id}{id}, $ores[0]); };
            $bias{$ores[0]}++;
            next;
          }
        }
      }
      @ores = sort { $bias{$a} <=> $bias{$b} } keys (%{$ores->{ore}});
      if (@ores) {
        emit("Searching for $ores[0] glyph (bias $bias{$ores[0]})", $body_id);
        $noaction or $client->archaeology_search($arches{$body_id}{id}, $ores[0]);
        $bias{$ores[0]}++;
        next;
      }
    }
    $rpccount = $client->empire_status->{rpc_count};
    say "Ending RPC: $rpccount";
    if ( $repeat ) {
        say "Sleeping for 5 hours & 50 minutes. Will restart at: ".(Client::format_time((time())+21600))."\n";
        sleep 21000;
    }
} while ($repeat);

sub usage {
    diag(<<END);
Usage: $0 [options]

This program performs automatic digging for glyphs at each of your planets that
has an Archeology Ministry.  Requires Lacuna Automation to function.

Options:
  --help             - This info.
  --config "FILE"    - Specify an config file, normally config.json
  --body "NAME"      - Specify planet, may use switch more than once.
  --debug+           - Run in debugging mode.
  --noaction         - Basically an dry run giving you just the glyph counts
                       and bias values.
  --quiet            - Run printing out less info
  --repeat           - Continously perform digs every 6 hours.
  --skipSS "STRING"  - Skips bodies (Space Stations) if regex is matched.
                       Example use:  --skipSS "^(S|Z)ASS"
                       The above skips all SS starting with SASS or ZASS.

END
  exit 1;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
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

sub sec2str {
  my ($sec) = @_;

  my $day = int($sec/(24 * 60 * 60));
  $sec -= $day * 24 * 60 * 60;
  my $hrs = int( $sec/(60*60));
  $sec -= $hrs * 60 * 60;
  my $min = int( $sec/60);
  $sec -= $min * 60;
  return sprintf "%02dH:%02dM:%02dS", $hrs, $min, $sec;
}
