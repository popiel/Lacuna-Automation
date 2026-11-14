#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
BEGIN {
  @INC = (@INC, $FindBin::RealBin, "$FindBin::RealBin/local/lib/perl5");
}

use Carp;
use Client;
use DBI;
use Getopt::Long;
use JSON::XS ();
use List::Util qw(min max sum first);
use POSIX qw(strftime);

autoflush STDOUT 1;
autoflush STDERR 1;

# Package globals (also visible to tests that require this file).
our $config_name = "config.json";
our @body_names;
our @zones;
our $db_file = "stars.db";
our $debug   = 0;
our $noaction = 0;
our $quiet   = 0;
our $help    = 0;

our $client;
our $star_db;
our $empire_name;
our %body_names = ();
our %claimed    = ();
our %en_route   = ();
our %sitting    = ();

sub usage {
  print <<"END";
Usage: $0 --zone X|Y --body Name [--zone X|Y --body Name ...] [options]
  --zone   / -z   Zone label X|Y (repeatable, required)
  --body   / -b   Base body name (repeatable, required)
  --config          Client config file (default config.json)
  --db              Star database file (default stars.db)
  --noaction / -n   Simulate: no RPC mutations or DB writes
  --debug   / -d    Print debug information (repeatable for more)
  --quiet           Suppress routine output; errors still print
  --help            Show this help
END
}

sub emit {
  return if $quiet;
  my $message = shift;
  my $prefix  = shift // $empire_name;
  print Client::format_time(time()) . " probe_hunter: $prefix: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash    = shift;
  print Client::format_time(time()) . " $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash), "\n";
}

sub valid_zone {
  my $zone = shift;
  return $zone =~ /^-?\d+\|-?\d+$/;
}

sub parse_args {
  GetOptions(
    "config=s" => \$config_name,
    "body|b=s" => \@body_names,
    "zone|z=s" => \@zones,
    "db=s"     => \$db_file,
    "debug+"   => \$debug,
    "noaction" => \$noaction,
    "quiet"    => \$quiet,
    "help"     => \$help,
  ) or die "Try '$0 --help' for usage.\n";
  usage() and exit 0 if $help;
  die "Missing required options. Try '$0 --help' for usage.\n" unless @zones && @body_names;
  for my $zone (@zones) {
    die "Invalid zone '$zone': expected X|Y with integer components. Try '$0 --help'.\n"
      unless valid_zone($zone);
  }
  return;
}

sub compute_build_count {
  my ($docked, $building, $slots, $used) = @_;
  my $room   = max(0, $slots - $used);
  my $need   = 3 - $docked - $building;
  return min($need, $room) if $need > 0 && $room > 0;
  return 0;
}

sub should_abandon {
  my ($orb_count, $colony_or_station, $desirable) = @_;
  return 0 unless $orb_count;                       # C1: not explored
  return 0 if $colony_or_station;                   # C2: colony/station present
  return 0 if $desirable;                           # C3: desirable orbit present
  return 1;
}

sub open_star_db {
  my $file = shift;
  -f $file or die "Database does not exist ($file), run star_db_util.pl --create-db\n";
  my $dbh = DBI->connect("dbi:SQLite:$file");
  die "Can't open star database $file: $DBI::errstr\n" unless $dbh;
  $dbh->{RaiseError} = 1;
  $dbh->{PrintError} = 0;
  return $dbh;
}

sub check_schema {
  my $dbh = shift;
  for my $check (
    [ 'select zone from stars limit 1',                          'stars.zone' ],
    [ 'select subtype from orbitals limit 1',                    'orbitals.subtype' ],
    [ 'select station_id from orbitals limit 1',                 'orbitals.station_id' ],
  ) {
    my ($sql, $col) = @$check;
    eval { $dbh->do($sql); 1 }
      or die "Database is outdated: $col is missing; run star_db_util.pl --upgrade\n";
  }
  return;
}

sub find_target {
  my ($body_id, $body) = @_;
  my $placeholders = join(',', ('?') x @zones);
  my $sth = $star_db->prepare(<<SQL);
select s.id, s.name, s.x, s.y, s.zone,
       (s.x - ?) * (s.x - ?) + (s.y - ?) * (s.y - ?) as dist2
from stars s
where s.zone in ($placeholders)
  and not exists (select 1 from orbitals o where o.star_id = s.id)
order by dist2
SQL
  $sth->execute($body->{x}, $body->{x}, $body->{y}, $body->{y}, @zones);
  while (my $row = $sth->fetchrow_hashref) {
    return $row unless $claimed{$row->{id}} || $en_route{$row->{id}} || $sitting{$row->{id}};
  }
  return;
}

sub run {
  parse_args();

  $client = Client->new(config => $config_name);
  $client->cache_invalidate(type => 'empire_status');
  my $empire_status = $client->empire_status;
  $empire_name = $empire_status->{name};

  my $planets = $empire_status->{planets};
  my @body_ids = map { $client->match_planet($_) } @body_names;
  die "Failed to resolve one or more bodies\n" unless @body_ids == @body_names;
  %body_names = map { $_ => $planets->{$_} } @body_ids;
  @body_ids = sort { $body_names{$a} cmp $body_names{$b} } @body_ids;

  $star_db = open_star_db($db_file);
  check_schema($star_db);

  # --- validate bases --------------------------------------------------
  my (%obs, %ports, %yards);
  for my $body_id (@body_ids) {
    $client->cache_invalidate(type => 'buildings', id => $body_id);
    $obs{$body_id}  = eval { $client->find_building($body_id, "Observatory") };
    $ports{$body_id} = [ eval { $client->find_building($body_id, "Space Port") } ];
    $yards{$body_id} = [ eval { $client->find_building($body_id, "Shipyard") } ];
  }
  @body_ids = grep { $obs{$_} && @{$ports{$_}} && @{$yards{$_}} } @body_ids;
  die "No valid bases (each needs an Observatory, Space Port, and Shipyard)\n"
    unless @body_ids;
  %body_names = map { $_ => $body_names{$_} } @body_ids;

  # --- fetch per-body data ---------------------------------------------
  my (%ships, %probed_stars, %body_coords, %yard_queues, %yard_buildable);
  for my $body_id (@body_ids) {
    $client->cache_invalidate(type => 'observatory_get_probed_stars', id => $obs{$body_id}{id});
    $client->cache_invalidate(type => 'spaceport_view_all_ships',     id => $body_id);
    $client->cache_invalidate(type => 'shipyard_view_build_queue',    id => $_->{id}) for @{$yards{$body_id}};
    $client->cache_invalidate(type => 'shipyard_buildable',           id => $_->{id}) for @{$yards{$body_id}};

    my $ok = eval {
      $ships{$body_id}      = $client->port_all_ships($body_id);
      $probed_stars{$body_id} = $client->get_probed_stars($obs{$body_id}{id});
      $body_coords{$body_id}  = $client->body_status($body_id);
      for my $yard (@{$yards{$body_id}}) {
        $yard_queues{$yard->{id}}  = $client->yard_queue($yard->{id});
        $yard_buildable{$yard->{id}} = $client->yard_buildable($yard->{id});
      }
      1;
    };
    unless ($ok) {
      emit("Skipping probe operations for $body_names{$body_id}: $@");
      delete $obs{$body_id};
      delete $ports{$body_id};
      delete $yards{$body_id};
      next;
    }
    emit_json("Probed stars for $body_names{$body_id}", $probed_stars{$body_id}) if $debug > 1;
  }
  @body_ids = grep { exists $obs{$_} } @body_ids;
  die "No usable bases remain\n" unless @body_ids;

  # --- global sets ------------------------------------------------------
  for my $body_id (@body_ids) {
    for my $star (@{$probed_stars{$body_id}{stars}}) {
      $sitting{$star->{id}} = 1;
    }
    for my $ship (@{$ships{$body_id}{ships}}) {
      if ($ship->{type} eq 'probe'
        && $ship->{task} eq 'Travelling'
        && $ship->{to}
        && $ship->{to}{id})
      {
        $en_route{$ship->{to}{id}} = 1;
      }
    }
  }

  # --- capture missing star data ----------------------------------------
  my @missing_planets;
  my %seen_missing_planet;
  for my $body_id (@body_ids) {
    for my $star (@{$probed_stars{$body_id}{stars}}) {
      my $count = $star_db->selectrow_array('select count(*) from orbitals where star_id = ?', {}, $star->{id});
      unless ($count) {
        push @missing_planets, $body_names{$body_id} unless $seen_missing_planet{$body_id}++;
      }
    }
  }
  if (@missing_planets && !$noaction) {
    my $cmd = join(' ', $^X, "$FindBin::RealBin/star_db_util.pl",
                   '--config', $config_name, '--db', $db_file, '--no-vacuum',
                   '--planet', @missing_planets);
    emit("Refreshing star data: $cmd") if $debug;
    system($cmd);
    $star_db = open_star_db($db_file);
    check_schema($star_db);
  } elsif (@missing_planets) {
    emit("Sitting-probe stars lack orbitals in $db_file; run star_db_util.pl --planet @missing_planets");
  }

  my %sent   = ();
  my $abandoned = 0;
  my $sent_total = 0;
  my $built_total = 0;

  # --- section 7: abandon probes -----------------------------------------
  for my $body_id (@body_ids) {
    my $obs_id = $obs{$body_id}{id};
    my $stars  = $probed_stars{$body_id};
    for my $star (@{$stars->{stars}}) {
      my $orb_count = $star_db->selectrow_array('select count(*) from orbitals where star_id = ?', {}, $star->{id});
      my $cs = $star_db->selectrow_array(
        'select count(*) from orbitals where star_id = ? and (empire_id is not null or station_id is not null)',
        {}, $star->{id});
      my $des = $star_db->selectrow_array(
        'select count(*) from orbitals where star_id = ? and orbit between 2 and 5 and subtype in (?,?,?,?)',
        {}, $star->{id}, 'p11', 'p12', 'p33', 'p35');
      next unless should_abandon($orb_count, $cs, $des);
      unless ($noaction) {
        eval { $client->call(observatory => abandon_probe => $obs_id, $star->{id}); 1; }
          or do { emit("Couldn't abandon probe at $star->{name}: $@"); next; };
      }
      emit("Abandoning probe at $star->{name} ($star->{x},$star->{y})", $body_names{$body_id});
      $stars->{star_count}--;
      $abandoned++;
    }
  }

  # --- section 8: send probes --------------------------------------------
  for my $body_id (@body_ids) {
    my $stars = $probed_stars{$body_id};
    my $room  = $stars->{max_probes} - $stars->{star_count} - $stars->{travelling};
    my @probes = grep { $_->{type} eq 'probe' } @{$ships{$body_id}{ships}};
    my @ready  = grep { $_->{task} eq 'Docked' } @probes;
    my $body   = $body_coords{$body_id};
    for my $probe (@ready) {
      last unless $room > 0;
      my $target = find_target($body_id, $body);
      last unless $target;
      $claimed{$target->{id}} = 1;
      unless ($noaction) {
        eval { $client->send_ship($probe->{id}, { star_id => $target->{id} }); 1; }
          or do { delete $claimed{$target->{id}}; emit("Couldn't send probe to $target->{name}: $@"); next; };
      }
      $room--;
      $sent{$body_id}++;
      $sent_total++;
      $en_route{$target->{id}} = 1;
      emit("Sent probe to $target->{name} at ($target->{x},$target->{y})", $body_names{$body_id});
    }
  }

  # --- section 9: build probes -------------------------------------------
  for my $body_id (@body_ids) {
    my @probes = grep { $_->{type} eq 'probe' } @{$ships{$body_id}{ships}};
    my $docked = scalar(grep { $_->{task} eq 'Docked' } @probes) - ($sent{$body_id} // 0);
    my $building = 0;
    for my $yard (@{$yards{$body_id}}) {
      my $q = $yard_queues{$yard->{id}};
      $building += scalar(grep { $_->{type} eq 'probe' } @{$q->{ships_building}}) if $q;
    }
    my $slots   = 2 * sum(map { $_->{level} } @{$ports{$body_id}});
    my $used    = scalar @{$ships{$body_id}{ships}};
    my $build_count = compute_build_count($docked, $building, $slots, $used);
    next unless $build_count > 0;

    my @buildable = grep {
      my $yb = $yard_buildable{$_->{id}};
      $yb && $yb->{buildable}{probe}{can};
    } @{$yards{$body_id}};
    @buildable = sort {
      my $aq = $yard_queues{$a->{id}}{ships_building} // [];
      my $bq = $yard_queues{$b->{id}}{ships_building} // [];
      scalar(@$aq) <=> scalar(@$bq);
    } @buildable;

    for my $yard (@buildable) {
      last unless $build_count > 0;
      my $count = $build_count;
      my $ok = eval {
        $noaction or $client->yard_build($yard->{id}, 'probe', $count);
        1;
      };
      unless ($ok) {
        $ok = eval {
          $noaction or $client->yard_build($yard->{id}, 'probe', 1);
          1;
        };
        $count = 1 if $ok;
      }
      if ($ok) {
        emit("Building $count probe(s) in yard at ($yard->{x},$yard->{y})", $body_names{$body_id});
        $built_total += $count;
        $build_count = 0;
      } else {
        emit("Couldn't build probe(s) at yard ($yard->{x},$yard->{y}): $@");
      }
    }
  }

  emit("Summary: abandoned=$abandoned sent=$sent_total built=$built_total bodies=" . scalar(@body_ids));
}

run() unless caller;
1;
