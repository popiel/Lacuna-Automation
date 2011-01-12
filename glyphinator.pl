#!/usr/bin/perl
#
# =================
#   Glyphinator
# =================
#
# Digs:
#   *) Collect list of current glyphs
#   *) On each ready planet, search in order of:
#       1. What we have the fewest glyphs of
#       2. What we have the most ore of
#       3. Random
#   *) Dig!
#
# Excavators:
#   *) Get list of ready excavators
#   *) Get closest ready body for each excavator
#   *) Launch!
#
# Spit out interesting times
#   *) When digs will be done
#   *) When excavators will arrive
#   *) When excavators will be finished building

use strict;
use warnings;

use feature ':5.10';

# Cache stuff to reduce lookups
#   --refresh

use DBI;
use FindBin;
use List::Util qw(first min max sum);
use Date::Parse qw(str2time);
use Math::Round qw(round);
use Getopt::Long;
use Data::Dumper;
use Exception::Class;
use Client;

my @batches;
my $current_batch = 0;
my $batch_opt_cb = sub {
    my ($opt, $val) = @_;

    if ($opt eq 'and') {
        $current_batch++;
        return;
    }

    $batches[$current_batch]{$opt} = $val;
};
my %opts;
GetOptions(\%opts,
    # General options
    'h|help',
    'q|quiet',
    'v|verbose',
    'config=s',
    'planet=s@',
    'dry-run|dry',
    'full-times',

    # Arch digs
    'do-digs|dig',
    'min-ore=i',
    'min-arch=i',
    'preferred-ore|ore=s',

    # Excavator options
    'db=s',
    'send-excavators|send',

    # make planet part of this too?
    'and'                     => $batch_opt_cb,
    'max-excavators|max=s'    => $batch_opt_cb,
    'min-dist=i'              => $batch_opt_cb,
    'max-dist=i'              => $batch_opt_cb,
    'zone=s'                  => $batch_opt_cb,
    'safe-zone-ok'            => $batch_opt_cb,
    'inhabited-ok'            => $batch_opt_cb,
    'furthest-first|furthest' => $batch_opt_cb,
    'random-dist|random'      => $batch_opt_cb,
    #   - alter 'dist' by a random % of the search range
    #   - but how to deal with multiple search windows?  just the closest
    #     window is probably not ok
    'find-destinations=i',

    # Build moar?  how to do that and not be too aggressive?
) or usage();
push @batches, {} unless @batches;

usage() if $opts{h};

my %do_planets;
if ($opts{planet}) {
    %do_planets = map { normalize_planet($_) => 1 } @{$opts{planet}};
}

my $client = Client->new(
    config => $opts{config} || "config.json",
);

my $star_util = "$FindBin::Bin/star_db_util.pl";
no warnings 'once';
my $db_file = $opts{db} || "$FindBin::Bin/../stars.db";
my $star_db;
if (-f $db_file) {
    $star_db = DBI->connect("dbi:SQLite:$db_file")
        or die "Can't open star database $db_file: $DBI::errstr\n";
    $star_db->{RaiseError} = 1;
    $star_db->{PrintError} = 0;
} else {
    warn "No star database found.  Specify it with --db or use $star_util --create-db to create it.\n";
    if ($opts{'send-excavators'}) {
        warn "Can't send excavators without star database!\n";
    }
}
if ($star_db) {
    # Check that db is populated
    my ($cnt) = $star_db->selectrow_array('select count(*) from orbitals');
    unless ($cnt) {
        diag("Star database is empty!\n");
        $star_db = undef;
    }
}
if ($star_db) {
    my $ok = eval {
        $star_db->do('select zone from stars limit 1');
        return 1;
    };
    unless ($ok) {
        my $e = $@;
        if ($e =~ /no such column/) {
            die "Database needs an upgrade, please run $star_util --upgrade\n";
        } else {
            die $e;
        }
    }
}

my $status;
get_status();
do_digs() if $opts{'do-digs'};
send_excavators() if $opts{'send-excavators'} and $star_db;
report_status();
output("$client->{total_calls} api calls made.\n");

exit 0;

sub get_status {
    my $empire = $client->empire_status;

    # reverse hash, to key by name instead of id
    my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};
    $status->{planets} = \%planets;

    # Scan each planet
    for my $planet_name (keys %planets) {
        if (keys %do_planets) {
            next unless $do_planets{normalize_planet($planet_name)};
        }

        verbose("Inspecting $planet_name\n");

        # Load planet data
        my $building_status = $client->body_buildings($planets{$planet_name});
        $status->{planet_location}{$planet_name}{x} = $building_status->{status}{body}{x};
        $status->{planet_location}{$planet_name}{y} = $building_status->{status}{body}{y};
        my $buildings = $building_status->{buildings};

        if ($opts{'find-destinations'}) {
            my @dests;
            my $remain = $opts{'find-destinations'};
            for my $batch (@batches) {
                unless ($remain) {
                    diag("Ran out of excavators before batches were complete!\n");
                    next;
                }

                my $count = $batch->{'max-excavators'} || $remain;
                if ($count =~ /^(\d+)%/) {
                    $count = max(int(($1 / 100) * $opts{'find-destinations'}), 1);
                }
                $count = min($count, $remain);

                my @new = pick_destination(
                    planet => $planet_name,
                    count  => $count,
                    batch  => $batch,
                );
                $remain -= @new;
                push @dests, @new;
            }
            for my $dest (@dests) {
                output("Destination from $planet_name: $dest->[0] ($dest->[3] units, zone $dest->[4])\n")
            }
            next;
        }

        my ($arch, $level, $seconds_remaining) = find_arch_min($buildings);
        if ($arch) {
            verbose("Found an archaeology ministry on $planet_name\n");
            $status->{archmin}{$planet_name}   = $arch;
            $status->{archlevel}{$planet_name} = $level;
            if ($seconds_remaining) {
                push @{$status->{digs}}, {
                    planet   => $planet_name,
                    finished => time() + $seconds_remaining,
                };
            } else {
                $status->{idle}{$planet_name} = 1;
                $status->{available_ore}{$planet_name} =
                    $client->ores_for_search($arch)->{ore}
            }

            my $glyphs = $client->get_glyphs($arch)->{glyphs};
            for my $glyph (@$glyphs) {
                $status->{glyphs}{$glyph->{type}}++;
            }
        } else {
            verbose("No archaeology ministry on $planet_name\n");
        }

        my $spaceport = find_spaceport($buildings);
        if ($spaceport) {
            verbose("Found a spaceport on $planet_name\n");
            $status->{spaceports}{$planet_name} = $spaceport;

            # How many in flight?  When arrives?
            my $ships = $client->port_all_ships($spaceport)->{ships};
            my @excavators = grep { $_->{type} eq 'excavator' } @$ships;

            push @{$status->{flying}},
                map {
                    $_->{distance} = int(($_->{arrives} - $_->{departed}) * $_->{speed} / 360000);
                    $_->{remaining} = int(($_->{arrives} - time()) * $_->{speed} / 360000);
                    $_
                }
                map {
                    {
                        planet      => $planet_name,
                        destination => $_->{to}{name},
                        speed       => $_->{speed},
                        departed    => str2time(
                            map { s!^(\d+)\s+(\d+)\s+!$2/$1/!; $_ }
                            $_->{date_started}
                        ),
                        arrives     => str2time(
                            map { s!^(\d+)\s+(\d+)\s+!$2/$1/!; $_ }
                            $_->{date_arrives}
                        ),
                    }
                }
                grep { $_->{task} eq 'Travelling' }
                @excavators;

            # How many ready now?
            $status->{ready}{$planet_name} = grep { $_->{task} eq 'Docked' } @excavators;
            verbose("$status->{ready}{$planet_name} excavators ready to launch\n");

            # How many open spots?
            my $total_docks = get_spaceport_dock_count($buildings);
            $status->{open_docks}{$planet_name} = $total_docks - @$ships;
            verbose("$status->{open_docks}{$planet_name} available docks\n");
        } else {
            verbose("No spaceport on $planet_name\n");
        }

        if ($status->{archlevel}{$planet_name} and $status->{archlevel}{$planet_name} >= 15) {
            my @shipyards = find_shipyards($buildings);
            verbose("No shipyards on $planet_name\n") unless @shipyards;
            for my $yard (@shipyards) {
                verbose("Found a shipyard on $planet_name\n");

                # Keep a record of any planet that could be building excavators, but isn't
                $status->{not_building}{$planet_name} = 1
                    unless exists $status->{not_building}{$planet_name};

                # How many building?
                my $ships_building = $client->yard_queue($yard)->{ships_building};
                my @excavators_building =
                    map {
                        {
                            finished => str2time(
                                map { s!^(\d+)\s+(\d+)\s+!$2/$1/!; $_ }
                                $_->{date_completed}
                            ),
                        }
                    }
                    grep { $_->{type} eq 'excavator' }
                    @$ships_building;

                if (@excavators_building) {
                    verbose(scalar @excavators_building . " excavators building at this yard\n");
                    push @{$status->{building}{$planet_name}}, @excavators_building;
                    $status->{not_building}{$planet_name} = 0;
                }
            }
        } else {
            verbose("$planet_name can't build excavators, skipping shipyards\n")
        }
    }
}

sub report_status {
    if (keys %{$status->{glyphs} || {}}) {
        my $total_glyphs = 0;
        output("Current glyphs:\n");
        my $cnt;
        for my $glyph (sort keys %{$status->{glyphs}}) {
            $total_glyphs += $status->{glyphs}->{$glyph};
            output(sprintf '%13s: %3s', $glyph, $status->{glyphs}->{$glyph});
            output("\n") unless ++$cnt % 4
        }
        output("\n") if $cnt % 4;
        output("\n");
        output("Current stock: $total_glyphs glyphs\n\n");
    }

    # Ready to go now?
    if (my @planets = grep { $status->{ready}{$_} } keys %{$status->{ready}}) {
        output(<<END);
**** Notice! ****
You have excavators ready to send.  Specify --send-excavators if you want to
send them to the closest available destinations.
*****************
END
        for my $planet (sort @planets) {
            output("$planet has ", pluralize($status->{ready}{$planet}, 'excavator')
                , " ready to launch!\n");
        }
        output("\n");
    }

    # Any idle archmins?
    if (keys %{$status->{idle}}) {
        output(<<END);
**** Notice! ****
You have idle archaeology minstries.  Specify --do-digs if you want to
start the recommended digs automatically.
*****************
END
        for my $planet (keys %{$status->{idle}}) {
            output("Archaeology Ministry on $planet is idle!\n");
        }
        output("\n");
    }


    # Fix this to be something like the following:
    #   Planet Foo is buildng N excavators, first done in [when], last done in [when]
    if (grep { @{$status->{building}{$_}} } keys %{$status->{building}}
        or grep { $status->{not_building}{$_} } keys %{$status->{not_building}}) {

        output("Excavators building:\n");
        for my $planet (sort keys %{$status->{planets}}) {
            if ($status->{building}{$planet} and @{$status->{building}{$planet}}) {
                my @sorted = sort { $a->{finished} <=> $b->{finished} }
                    @{$status->{building}{$planet}};

                my $first = $sorted[0];
                my $last = $sorted[$#sorted];

                output("    ",scalar(@sorted), " excavators building on $planet, ",
                    "first done in ", format_time($first->{finished}, $opts{'full-times'}),
                    ", last done in ", format_time($last->{finished}, $opts{'full-times'}), "\n");

            } elsif ($status->{not_building}{$planet}) {
                output("$planet is not currently building any excavators!  It has "
                    . pluralize($status->{open_docks}{$planet}, 'spot') . " currently available.\n");
            }
        }
        output("\n");
    }

    my @events;
    for my $dig (@{$status->{digs}}) {
        push @events, {
            epoch  => $dig->{finished},
            detail => "Dig finishing on $dig->{planet}",
        };
    }

    for my $ship (@{$status->{flying}}) {
        push @events, {
            epoch  => $ship->{arrives},
            detail => "Excavator from $ship->{planet} arriving at $ship->{destination} ($ship->{distance} units, $ship->{remaining} left)",
        };
    }
    @events =
        sort { $a->{epoch} <=> $b->{epoch} }
        map  { $_->{when} = format_time($_->{epoch}, $opts{'full-times'}); $_ }
        @events;

    if (@events) {
        output("Searches completing:\n");
        for my $event (@events) {
            display_event($event);
        }
    }

    output("\n");
}

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

sub format_time_delta {
    my ($delta, $strict) = @_;

    given ($delta) {
        when ($_ < 0) {
            return "just finished";
        }
        when ($_ < ($strict ? 60 : 90)) {
            return pluralize($_, 'second');
        }
        when ($_ < ($strict ? 3600 : 5400)) {
            my $min = round($_ / 60);
            return pluralize($min, 'minute');
        }
        when ($_ < 86400) {
            my $hrs = round($_ / 3600);
            return pluralize($hrs, 'hour');
        }
        default {
            my $days = round($_ / 86400);
            return pluralize($days, 'day');
        }
    }
}

sub format_time_delta_full {
    my ($delta) = @_;

    return "just finished" if $delta <= 0;

    my @formatted;
    my $sec = $delta % 60;
    if ($sec) {
        unshift @formatted, format_time_delta($sec,1);
        $delta -= $sec;
    }
    my $min = $delta % 3600;
    if ($min) {
        unshift @formatted, format_time_delta($min,1);
        $delta -= $min;
    }
    my $hrs = $delta % 86400;
    if ($hrs) {
        unshift @formatted, format_time_delta($hrs,1);
        $delta -= $hrs;
    }
    my $days = $delta;
    if ($days) {
        unshift @formatted, format_time_delta($days,1);
    }

    return join(', ', @formatted);
}

sub format_time {
    my ($time, $full) = @_;
    my $delta = $time - time();
    return $full ? format_time_delta_full($delta) : format_time_delta($delta);
}

sub pluralize {
    my ($num, $word) = @_;

    if ($num == 1) {
        return "$num $word";
    } else {
        return "$num ${word}s";
    }
}

sub display_event {
    my ($event) = @_;

    output(sprintf "    %11s: %s\n", $event->{when}, $event->{detail});
}

## Buildings ##

sub find_arch_min {
    my ($buildings) = @_;

    # Find the Archaeology Ministry
    my $arch_id = first {
            $buildings->{$_}->{name} eq 'Archaeology Ministry'
    }
    grep { $buildings->{$_}->{level} > 0 }
    keys %$buildings;

    return if not $arch_id;
    my $level     = $buildings->{$arch_id}{level};
    my $remaining = $buildings->{$arch_id}{work} ? $buildings->{$arch_id}{work}{seconds_remaining} : undef;

    return ($arch_id, $level, $remaining);
}

sub find_shipyards {
    my ($buildings) = @_;

    # Find the Shipyards
    my @yard_ids = grep {
            $buildings->{$_}->{name} eq 'Shipyard'
    }
    grep { $buildings->{$_}->{level} > 0 }
    keys %$buildings;

    return if not @yard_ids;
    return @yard_ids;
}

sub find_spaceport {
    my ($buildings) = @_;

    # Find a Spaceport
    my $port_id = first {
            $buildings->{$_}->{name} eq 'Space Port'
    }
    grep { $buildings->{$_}->{level} > 0 }
    keys %$buildings;

    return if not $port_id;
    return $port_id;
}

sub get_spaceport_dock_count {
    my ($buildings) = @_;

    my $level_sum = sum(
        map  { $buildings->{$_}->{level} }
        grep { $buildings->{$_}->{name} eq 'Space Port' }
        keys %$buildings
    );

    return $level_sum * 2;
}

## Arch digs ##

sub do_digs {

    # Try to avoid digging for the same ore on every planet, even if it's
    # determined somehow to be the "best" option.  We don't have access to
    # whatever digs are currently in progress so we'll base this just on what
    # we've started during this run.  This will be computed simply by adding
    # each current dig to glyphs, as if it were going to be successful.
    my $digging = {};

    for my $planet (keys %{$status->{idle}}) {
        if ($opts{'min-arch'} and $status->{archlevel}{$planet} < $opts{'min-arch'}) {
            output("$planet is not above specified Archaeology Ministry level ($opts{'min-arch'}), skipping dig.\n");
            next;
        }
        my $ore = determine_ore(
            $opts{'min-ore'} || 10_000,
            $opts{'preferred-ore'} || [],
            $status->{available_ore}{$planet},
            $status->{glyphs},
            $digging
        );
        if ($ore) {
            if ($opts{'dry-run'}) {
                output("Would have started a dig for $ore on $planet.\n");
            } else {
                output("Starting a dig for $ore on $planet...\n");
                $client->archaeology_search($status->{archmin}{$planet}, $ore);
                push @{$status->{digs}}, {
                    planet   => $planet,
                    finished => time() + (6 * 60 * 60),
                };
            }
            delete $status->{idle}{$planet};
        } else {
            output("Not starting a dig on $planet; not enough of any type of ore.\n");
        }
    }
}

sub determine_ore {
    my ($min, $preferred, $ore, $glyphs, $digging) = @_;

    my %is_preferred = map { $_ => 1 } @$preferred;

    my ($which) =
        sort {
            ($is_preferred{$b} || 0) <=> ($is_preferred{$a} || 0) or
            ($glyphs->{$a} || 0) + ($digging->{$a} || 0) <=> ($glyphs->{$b} || 0) + ($digging->{$b} || 0) or
            $ore->{$b} <=> $ore->{$a} or
            int(rand(3)) - 1
        }
        grep { $ore->{$_} >= $min }
        keys %$ore;

    if ($which) {
        $digging->{$which}++;
    }

    return $which;
}


## Excavators ##

sub send_excavators {
    PLANET:
    for my $planet (grep { $status->{ready}{$_} } keys %{$status->{ready}}) {
        verbose("Prepping excavators on $planet\n");
        my $port = $status->{spaceports}{$planet};
        my $originally_docked = $status->{ready}{$planet};

        # During a dry-run, not actually updating the database results in
        # each excavator from each planet going to the same target.  Add
        # them to an exclude list to simulate them being actually used.
        my %skip;

        for my $batch (@batches) {
            my $docked = $status->{ready}{$planet};

            if ($docked == 0) {
                diag("Ran out of excavators before batches were complete!\n");
                delete $status->{ready}{$planet};
                next PLANET;
            }

            my $count = $batch->{'max-excavators'} || $docked;
            if ($count =~ /^(\d+)%/) {
                $count = max(int(($1 / 100) * $originally_docked), 1);
            }
            $count = min($count, $docked);

            my @dests = pick_destination(
                planet => $planet,
                count  => $count,
                batch  => $batch,
            );

            if (@dests < $count) {
                diag("Couldn't fetch $count destinations from $planet!\n");
            }

            my $all_done;
            while (!$all_done) {
                my $need_more = 0;

                for (@dests) {
                    my ($dest_name, $x, $y, $distance, $zone) = @$_;

                    my $ships;
                    my $ok = eval {
                        $ships = $client->ships_for($status->{planets}{$planet}, {x => $x, y => $y});
                        return 1;
                    };
                    unless ($ok) {
                        if (my $e = Exception::Class->caught('LacunaRPCException')) {
                            if ($e->code eq '1002') {
                                # Empty orbit, update db and try again
                                output("$dest_name is an empty orbit, trying again...\n");
                                mark_orbit_empty($x, $y);

                                $need_more++;
                                next;
                            }
                        }
                        else {
                            my $e = Exception::Class->caught();
                            ref $e ? $e->rethrow : die $e;
                        }
                    }

                    unless (grep { $_->{type} eq 'excavator' } @{$ships->{available}}) {
                        if (grep { $_->{reason}[0] eq '1010' } @{$ships->{unavailable}}) {
                            # This will set the "last_excavated" time to now, which is not
                            # the case, but it's as good as we have.  It means that some bodies
                            # might take longer to get re-dug but whatever, there are others
                            output("$dest_name was unavailable due to recent search, trying again...\n");
                            update_last_sent($x, $y);
                        } else {
                            diag("Unknown error sending excavator from $planet to $dest_name!\n");
                            next PLANET;
                        }

                        $need_more++;
                        next;
                    }

                    $skip{$dest_name}++;

                    my $ex = first {
                        $_->{type} eq 'excavator'
                    } @{$ships->{available}};

                    if ($opts{'dry-run'}) {
                        output("Would have sent excavator from $planet to $dest_name ($distance units, zone $zone).\n");
                    } else {
                        output("Sending excavator from $planet to $dest_name ($distance units, zone $zone)...\n");
                        my $launch_status = $client->send_ship($ex->{id}, {x => $x, y => $y});

                        if ($launch_status->{ship}->{date_arrives}) {
                            push @{$status->{flying}},
                                {
                                    planet      => $planet,
                                    destination => $launch_status->{ship}{to}{name},
                                    speed       => $ex->{speed},
                                    distance    => $distance,
                                    remaining   => $distance,
                                    departed    => time(),
                                    arrives     => str2time(
                                        map { s!^(\d+)\s+(\d+)\s+!$2/$1/!; $_ }
                                        $launch_status->{ship}{date_arrives}
                                    ),
                                };

                                update_last_sent($x, $y);
                        } else {
                            diag("Error sending excavator to $dest_name!\n");
                            warn Dumper $launch_status;
                        }
                    }

                    $status->{ready}{$planet}--;
                }

                # Defer looking up more until we've finished processing our
                # current queue, otherwise we end up re-fetching ones we haven't
                # actually tried yet and get duplicates
                if ($need_more) {
                    @dests = pick_destination(
                        planet => $planet,
                        count  => $need_more,
                        batch  => $batch,
                        skip   => [keys %skip],
                    );
                } else {
                    $all_done = 1;
                }
            }
        }
        delete $status->{ready}{$planet}
            if !$status->{ready}{$planet};
    }
}

sub pick_destination {
    my (%args) = @_;

    my $planet = $args{planet};
    my $batch  = $args{batch};
    my $base_x = $status->{planet_location}{$planet}{x};
    my $base_y = $status->{planet_location}{$planet}{y};

    # Compute box size based on specified max hypotenuse
    my $min_dist = $batch->{'min-dist'} || 0;
    my $max_dist = $batch->{'max-dist'} || 3000;
    my $box_min = $min_dist ? int(sqrt($min_dist * $min_dist / 2)) : 0;
    my $box_max = int(sqrt($max_dist * $max_dist / 2));
    my $max_squared = $max_dist * $max_dist;
    my $min_squared = $min_dist * $min_dist;

    my $count       = $args{count} || 1;
    my $current_min = $box_max;
    my $current_max = $box_min;
    my $skip        = $args{skip} || [];

    my $furthest = $batch->{'furthest-first'};

    verbose("Seeking $count destinations for $planet\n");

    my @results;
    while (@results < $count and ($furthest ? $current_min > 0 : $current_max < $box_max)) {
        if ($furthest) {
            $current_max = $current_min;
            $current_min -= 100;
            $current_min = 0 if $current_min < 0;
            verbose("Decreasing box size, max is $current_max, min is $current_min\n");
        } else {
            $current_min = $current_max;
            $current_max += 100;
            $current_max = $box_max if $current_max > $box_max;
            verbose("Increasing box size, max is $current_max, min is $current_min\n");
        }

        # This would be better using SQLite's R*Tree support, but DBD::SQLite doesn't
        # support that yet, so we can't
        my $skip_sql = '';
        if (@$skip) {
            $skip_sql = "and s.name || ' ' || o.orbit not in (" . join(',',map { '?' } 1..@$skip) . ")";
        }
        my $inner_box = $current_min > 0 ? 'and not (o.x between ? and ? and o.y between ? and ?)' : '';
        my $safe_zone = $batch->{'safe-zone-ok'} ? '' : q{and (s.zone is null or s.zone != '-3|0')};
        my $inhabited = $batch->{'inhabited-ok'} ? '' : q{and o.empire_id is null};
        my $zone      = $batch->{'zone'} ? 'and zone = ?' : '';
        my $order     = $batch->{'furthest-first'} ? 'desc' : 'asc';
        my $rand      = $batch->{'random-dist'} ? "+ ((random()) % 50000)" : '';
        my $find_dest = $star_db->prepare(<<SQL);
select   s.name, o.orbit, o.x, o.y, s.zone, (o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?) as dist,
         (((o.x - ?) * (o.x - ?) + (o.y - ?) * (o.y - ?)) $rand) as sort_dist
from     orbitals o
join     stars s on o.star_id = s.id
where    (type in ('habitable planet', 'asteroid', 'gas giant') or type is null)
and      (last_excavated is null or date(last_excavated) < date('now', '-30 days'))
and      o.x between ? and ?
and      o.y between ? and ?
and      dist <= $max_squared
and      dist >= $min_squared
$skip_sql
$safe_zone
$inhabited
$zone
$inner_box
order by sort_dist $order
limit    $count
SQL

        # select columns,x/y betweens
        my @vals = (
            $base_x, $base_x, $base_y, $base_y,
            $base_x, $base_x, $base_y, $base_y,
            $base_x - $current_max,
            $base_x + $current_max,
            $base_y - $current_max,
            $base_y + $current_max,
            @$skip,
        );
        if ($batch->{zone}) {
            push @vals, $batch->{zone};
        }
        if ($current_min > 0) {
            push @vals,
                $base_x - $current_min,
                $base_x + $current_min,
                $base_y - $current_min,
                $base_y + $current_min,
        }

        $find_dest->execute(@vals);
        while (my $row = $find_dest->fetchrow_hashref) {
            my $dest_name = "$row->{name} $row->{orbit}";
            my $dist = int(sqrt($row->{dist}));
            verbose("Selected destination $dest_name, which is $dist units away\n");

            my $zone = $row->{zone};
            unless ($zone) {
                my $x_zone = int($row->{x} / 250);
                my $y_zone = int($row->{y} / 250);
                $zone = "$x_zone|$y_zone";
            }
            push @results, [$dest_name, $row->{x}, $row->{y}, $dist, $zone];
            push @$skip, $dest_name;
        }
    }

    return @results;
}

sub update_last_sent {
    my ($x, $y) = @_;

    my $r = $star_db->do(q{update orbitals set last_excavated = datetime(?,'unixepoch') where x = ? and y = ?}, {}, time(), $x, $y);
    unless ($r > 0) {
        diag("Warning: could not update orbitals table for body at $x, $y!\n");
    }
}

sub mark_orbit_empty {
    my ($x, $y) = @_;

    my $r = $star_db->do(q{update orbitals set type = 'empty' where x = ? and y = ?}, {}, $x, $y);
    unless ($r > 0) {
        diag("Warning: could not update orbitals table for body at $x, $y!\n");
    }
}

sub usage {
    diag(<<END);
Usage: $0 [options]

This program will manage your glyph hunting worries with minimal manual
intervention required.  It will notice archeology digs, ready-to-launch
excavators, and idle shipyards and notify you of them.  It can start digs
for the most needed glyphs, and send excavators to the nearest available
bodies.

This is suitable for automation with cron(8) or at(1), but you should
know that it tends to use a substantial number of API calls, often 50-100
per run.  With the daily limit of 5000, including all web UI usage, you
will want to keep these at a relatively infrequent interval, such as every
60 minutes at most.

Options:
  --verbose              - Output extra information.
  --quiet                - Print no output except for errors.
  --config <file>        - Specify a config file, normally config.json
  --db <file>            - Specify a star database, normally stars.db.
  --planet <name>        - Specify a planet to process.  This option can be
                           passed multiple times to indicate several planets.
                           If this is not specified, all relevant colonies will
                           be inspected.
  --do-digs              - Begin archaeology digs on any planets which are idle.
  --min-ore <amount>     - Do not begin digs with less ore in reserve than this
                           amount.  The default is 10,000.
  --min-arch <level>     - Do not begin digs on any archaeology ministry less
                           than this level.  The default is 1.
  --preferred-ore <type> - Dig using the specified ore whenever available.
  --send-excavators      - Launch ready excavators at their nearest destination.
                           The information for these is selected from the star
                           database, and the database is updated to reflect your
                           new searches.
  --max-excavators <n>   - Send at most this number of excavators from any colony.
                           This argument can also be specified as a percentage,
                           eg '25%'
  --min-dist <n>         - Minimum distance to send excavators
  --max-dist <n>         - Maximum distance to send excavators
  --zone <id>            - Specify a particular zone to send to, if possible
  --safe-zone-ok         - Ok to send excavators to -3|0, the neutral zone
  --inhabited-ok         - Ok to send excavators to inhabited planets
  --furthest-first       - Select the furthest away rather than the closest
  --dry-run              - Don't actually take any action, just report status and
                           what actions would have taken place.
  --full-times           - Specify timestamps in full precision instead of rounded

The excavator arguments can be combined into separate batches, to allow you to
send with multiple set of criteria, separated by an --and argument.  All of the
options above starting with --max-excavators through --furthest-first may be
used independently in each batch.  An example might be:

    --max-excavators 2 --min-dist 500 --and --max-excavators '50%'

Which would first send 2 500 or more units, then half of the remaining docked
ones to their nearest destination.  This is repeated for each colony, or the ones
indicated by --planet
END
    exit 1;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
}
