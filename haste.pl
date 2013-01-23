#!/usr/bin/perl

use strict;
use warnings;

use feature ':5.10';

use Carp;
use IO::Handle;
use JSON::PP;
use List::Util qw(sum max min);
use Data::Dumper;
use Getopt::Long;

use Client;
use Tools  qw( :all );

autoflush STDOUT 1;
autoflush STDERR 1;

my @owe = qw( ore water energy ); # We'll repeat this a lot

our %opts;
our $usage = qq{
Usage: $0 [options]

This script attempts to maintain waste levels within your specified parameters,
sustaining a minimum amount of waste for your waste consuming planets and
keeping waste below a maximum percentage of your storage. It adapts to the
capacity and production levels for each planet.

When waste production is negative, it will dump resources in a balanced manner
to bring down the most abundant resource down first to generate waste. For
resources that have subtypes (food and ore), this balancing extends to the
subtypes.

When waste production is positive, it will attempt to bring the amount of
stored waste below the maximum percentage of storage by using scows to dump
waste in the local star and then by recycling waste into usable resources.
Recycling is done in batches to take an --iteration's worth of time, if run
in continuous mode, or 10 minutes' worth of time if it is a single run.

It reports its actions so you can always see what it has done.

Options:
    --config <empire.json>    - JSON configuration file for empire login
    --dry-run                 - Do not take any real action. Useful for testing
                                options to see how different combinations will
                                affect behavior
    --help                    - Prints this help message
    --quiet                   - Suppresses most output (TODO)
    --verbose                 - Provides additional information about how decisions
                                are made
    --planet <p1[,p2,...]>    - List of planets to run against
    --interval <minutes>      - Minutes to sleep between runs. Also controls recycle
                                center batches
    --recycle-balanced        - Forces haste to recycle balanced amounts between all
                                resources
    --recycle-by-amount       - Recycling focuses on the resource with the smallest
                                amount stored at the time of recycling.
    --recycle-by-rate         - Recycling focuses on the resource with the slowest
                                production rate
    --keep-hours <hours>      - Minimum number of hours of waste to keep. This uses
                                the planet's waste per hour metric to determine the
                                minimum amount of waste to keep.
    --keep-units <units>      - Minimum amount of waste to keep.
    --min-percent <.00>       - Minimum percentage of waste storage to keep filled.
                                This uses the planet's waste storage capacity to
                                calculate the minimum amount of waste to keep.
    --max-percent <.00>       - Maximum percentage of waste storage to keep filled.
                                This uses the planet's waste storage capacity to
                                calculate the maximum amount of waste to keep.
};

my $client;

Main( @ARGV );

exit(0);

sub Main {
    local @ARGV = @_;
    GetOptions(\%opts,
        'config|c=s',
        'debug|d!',
        'dry-run|n',
        'help|h!',
        'quiet|q!',
        'verbose|v!',
        'planet|p=s@',
        'interval|i|s|sleep=i',
        'keep-hours|kh=f',
        'keep-units|ku=f',
        'min-percent|min=f',
        'max-percent|max=f',
        'recycle-balanced|rb',
        'recycle-by-amount|ra',
        'recycle-by-rate|rr',
    ) or usage();

    usage() if $opts{help};

    # Ensure we have some kind of threshold
    unless ( grep { $opts{$_} } qw( keep-hours keep-kilos min-percent max-percent ) ) {
        usage();
    }

    # check for list of planets to work on
    my %do_planets;
    if ($opts{planet}) {
        %do_planets = map { normalize_planet($_) => 1 } @{$opts{planet}};
    }

    # instantiate the client and get initial status
    my $config = $opts{config} || shift @ARGV || 'config.json' ;
    $client = Client->new(config => $config);
    my $empire = $client->empire_status();

    # Take $empire->{planets} and turn it inside-out, but cross-reference %do_planets to
    # 1) get a hash of only the planets we care about; or
    # 2) get a hash of *all* planets
    my $grep = ( keys %do_planets )
        ? sub { exists $do_planets{ normalize_planet( $empire->{planets}{$_} ) } }
        : sub { 1 }
    ;
    my %planets =
            map  { $empire->{planets}{$_} => $_ }
            grep { $grep->($_) }
            keys %{ $empire->{planets} }
    ;

    # If we have a list of planets to work on, we only want to do those planets; otherwise, we do all planets.
    %do_planets = map {  $empire->{planets}{$_}, $_ } keys %{$empire->{planets}} unless ( keys %do_planets );

    do {
        for my $planet_name ( keys %do_planets ) {
            output("Checking waste stores on $planet_name");

            my $s = $client->body_status($planets{$planet_name});

            # use opts to determine the largest minimum waste / smallest maximum waste threshholds
            my $minimum_waste = max(
                ( $opts{'keep-hours'}  ? abs( $s->{waste_hour}     * $opts{'keep-hours'}  ) : () ),
                ( $opts{'keep-units'}  ? $opts{'keep-units'}                                : () ),
                ( $opts{'min-percent'} ? int( $s->{waste_capacity} * $opts{'min-percent'} ) : () ),
                0
            );
            my $maximum_waste =
                ( $opts{'max-percent'} )
                    ? int( $s->{waste_capacity} * $opts{'max-percent'} )
                    : $s->{waste_capacity}
            ;

            verbose("keeping waste between $minimum_waste and $maximum_waste units");
            if ($s->{waste_hour} < 0) { # we're burning waste
                output("Waste rate is negative ($s->{waste_hour})");

                my $hours_left = sprintf('%0.2f', -1 * $s->{waste_stored} / $s->{waste_hour});
                output("We have $hours_left hours ($s->{waste_stored} units) of waste stored");
            }
            elsif ($s->{waste_hour} > 0) { # we are making waste already
                output("Waste rate is positive ($s->{waste_hour})");

                my $hours_full = sprintf('%0.2f',
                    ( $s->{waste_capacity} - $s->{waste_stored} ) / $s->{waste_hour}
                );
                output("$hours_full hours until waste is full; currently at $s->{waste_stored} units");
            }
            else {
                output("You have attained waste zen.");
            }

            if ( $s->{waste_stored} < $minimum_waste ) {
                verbose("We have less than our threshold of $minimum_waste units of waste");
                make_waste( $s, $minimum_waste - $s->{waste_stored} );
            }
            elsif ( $s->{waste_stored} > $maximum_waste ) {
                verbose( "More than $maximum_waste stored; disposing of some" );
                waste_disposal( $s, $s->{waste_stored} - $maximum_waste );
            }
            else {
                verbose("Stored waste is currently 'in-the-zone'. Do nothing.");
            }

            output("$planet_name ... done");
            # grab the buildings on this planet
            my $building_status = $client->body_buildings($planets{$planet_name});
            my $buildings = $building_status->{buildings};
        }
        output(
            scalar(localtime(time)),
            ' All planets are done.',
            ($opts{interval}?" Sleeping $opts{interval} minutes":''),
        );
    } while ( $opts{interval} && sleep( $opts{interval} * 60 ) );

    return;
}

sub make_waste {
    my ($s, $limit) = @_;

    verbose("Need to create $limit units of waste");
    verbose("Gathering storage facility information");
    # get the storage facilities on this planet
    my $body_buildings = $client->body_buildings($s->{id})->{'buildings'};
    my %seen;
    my %storage_facilities =
        map  { $body_buildings->{$_}{type} => +{ %{ $body_buildings->{$_} }, id => $_ } }
        grep {
            my ($type) = map { lc $_ } ($body_buildings->{$_}{name} =~ /^(\w+) (?:Storage|Reserve)/);
            ( $type && !$seen{$type} )
                ? ($seen{$type},$body_buildings->{$_}{type}) = (1,$type) # yes, this is sneaking a new key into items we want
                : 0
        }
        keys %{$body_buildings};

    unless ( keys %storage_facilities ) {
        output( 'No storage facilities found; cannot produce waste!' );
        return;
    }

    output("Gathering resource information");
    # only consider resources that we can dump
    my %resources = map { $_ => $s->{"${_}_stored"} } keys %seen;

    debug( 'current resources: ', Dumper( \%resources ) );

    my %resource_dump = proportionalize( $limit, \%resources );
    debug("proportionalized dump: ",Dumper( \%resource_dump ) );

    debug('storage facilities: ',Dumper(\%storage_facilities));
    dump_resource( $storage_facilities{$_}, $_, $resource_dump{ $_ } ) for ( keys %resource_dump );
    $client->cache_invalidate( type => 'body_status', id => $s->{id} );

    return;
}

sub dump_resource {
    my ($building, $type, $amount) = @_;

    debug( 'building: ',Dumper( $building ) );
    output("Dump $amount units of $type");
    return unless $amount;
    given ($type) {
        when ('energy') {
            $client->call('energyreserve','dump',$building->{id}, $amount) unless $opts{'dry-run'};
        }
        when ('water') {
            $client->call('waterstorage','dump',$building->{id}, $amount) unless $opts{'dry-run'};
        }
        when ('food') {
            my $food_stored = $client->call('foodreserve','view',$building->{id})->{'food_stored'};
            my %food_types = proportionalize($amount, $food_stored);
            while ( my ($specifically, $amount) = each %food_types ) {
                next unless $amount;
                output("Dumping $amount units of $specifically");
                $client->call('foodreserve','dump',$building->{id}, $specifically, $amount)
                        unless $opts{'dry-run'};
            }
        }
        when ('ore') {
            my $ore_stored = $client->call('orestorage','view',$building->{id})->{'ore_stored'};
            my %ore_types = proportionalize($amount, $ore_stored);
            while ( my ($specifically, $amount) = each %ore_types ) {
                next unless $amount;
                output("Dumping $amount units of $specifically");
                $client->call('orestorage','dump',$building->{id}, $specifically, $amount)
                        unless $opts{'dry-run'};
            }
        }
        default {
            output("I don't know how to dump $type\n");
        }
    }
}

sub waste_disposal {
    my ($s, $amount) = @_;

    my $recycled_amount = 0;
    my $recycled = recycle( $s, $amount );
    if (keys %$recycled) {
        $recycled_amount = sum( values %$recycled );
        output(
            sprintf(
                "Recycled %d units of waste into %s",
                $recycled_amount,
                join('; ', map { "$_: $recycled->{$_}" } keys %$recycled ),
            )
        );
    }
    else {
        output("Could not recycle waste into resources");
    }

    return if ($recycled_amount >= $amount);
    my $dumped   = scow_dump( $s, ($amount - $recycled_amount) );
    output("Shipped off $dumped units of waste via scow");

    $client->cache_invalidate( type => 'body_status', id => $s->{id} );
}

sub proportionalize {
    my ($limit, $resources) = @_;

    verbose("Proportionalizing $limit units between @{[ scalar keys %$resources ]} resource types");
    # Let's see what we're looking at...sorted by amount, descending
    my @types  = sort { $resources->{$b} <=> $resources->{$a} } keys   %$resources;

    # we still have to dump $limit's worth
    my $remainder = $limit;
    my %dump_amount;
    for my $ii ( 0 .. $#types - 1) {
        # Initialize the amount we want to dump
        $dump_amount{ $types[$ii] } = 0;

        # How much do we have between our current type and the next most plentiful type?
        my $diff = $resources->{ $types[$ii] } - $resources->{ $types[$ii + 1] };
        verbose( "diff between $types[$ii] and $types[$ii + 1] is $diff" );
        # jump to the next resource if difference is 0
        next unless $diff;

        # If that difference is greater than what we still need to dump, only dump
        # what we still need to in order to hit the limit
        my $amount = ( $diff > $remainder ) ? $remainder : $diff;
        verbose( "split $amount between @{[ scalar keys %dump_amount ]} resources" );
        # divide that amount by the total number of things that we have queued to dump
        $amount = int( ( $amount ) / scalar keys %dump_amount )||1;
        $dump_amount{ $_ } += $amount for keys %dump_amount;

        debug( "current split: ",Dumper(\%dump_amount) );
        if ( (my $dumped = sum( values %dump_amount )) >= $limit ) { # we've dumped enough waste
            verbose("accumulated dump amount: $dumped; done");
            # we're done
            last;
        }
        else {
            # subtract out the dumped amount from the remainder
            $remainder = $limit - $dumped;
            verbose("accumulated dump amount: $dumped; $remainder units remaining to be dumped");
        }
    }

    if ( keys %dump_amount &&  0 == sum( values %dump_amount ) ) {
        verbose( "Looks like you have equal amounts of all resources; evenly splitting total dump amount" );
        my $amount = int( ( $limit ) / scalar keys %dump_amount )||1;
        $dump_amount{ $_ } += $amount for keys %dump_amount;
    }

    return %dump_amount;
}

sub scow_dump {
    my ($s, $amount) = @_;
    my $dumped = 0;

    my $target = { star_id => $s->{star_id} };
    my $ships = $client->call(spaceport => get_ships_for => $s->{id}, $target);

    if ($opts{verbose}) {
        verbose("Ship count: ".scalar(@{$ships->{available}}));
        for my $ship (@{$ships->{available}}) {
            verbose("$ship->{id}: $ship->{type} $ship->{task} $ship->{hold_size}");
        }
    }

    for my $scow (
        sort { $b->{hold_size} <=> $a->{hold_size}            }
        grep { $_->{type} =~ /scow/ && $_->{task} eq "Docked" }
        @{$ships->{available}}
    ) {
        my $result = eval {
            $client->call(spaceport => send_ship => $scow->{id}, $target) unless $opts{'dry-run'};
        };
        if ( $@ ) {
            verbose("Sending scow $scow->{id} failed: $!");
            next;
        }

        output("Sent scow '$scow->{name}' ($scow->{hold_size} waste) to $s->{star_name}");
        $dumped += $scow->{hold_size};
        verbose("dupmed $dumped of $amount so far");
        last if ($dumped >= $amount);
    }

    if ( $dumped == 0 ) {
        output( "Nothing dumped via scows. Do you have any scows available?" );
    }
    else {
        output( "Dumped a total of $dumped via scows" );
    }

    return $dumped;
}

sub recycle {
    my ($s, $amount) = @_;
    my %recycled;

    output( "Looking to recycle $amount of waste into new resources" );
    my $buildings = $client->body_buildings($s->{id})->{'buildings'};
    my @buildings = map  { +{ %{ $buildings->{$_} }, id => $_ } } keys(%$buildings);
    my @centers   =
        sort { $b->{level} <=> $a->{level} }
        grep { $_->{name} eq "Waste Recycling Center" }
        @buildings;
    verbose( "We have @{[ scalar @centers || 0 ]} recycling centers on this planet." );

    unless ( scalar @centers ) {
        output( "No recycling centers; nothing to do." );
        return \%recycled;
    }

    my $left_to_recycle = $amount;
    for my $center (@centers) {
        if ( $left_to_recycle <= 0 ) {
            verbose( "Already recycled $amount; nothing left to recycle." );
            last;
        }

        if ( $center->{work} ) {
            verbose( "recycling center $center->{id} is busy; skipping\n" );
            next;
        }

        my $view = $client->building_view($center->{url}, $center->{id});
        my $recycle_capacity = int List::Util::min(
            ( ( ( ($opts{interval}||10) * 60 ) - 30 ) / $view->{recycle}{seconds_per_resource} ),
            $left_to_recycle,
            $client->body_status($s->{id})->{'waste_stored'}
        );
        verbose("recycling $recycle_capacity units of waste into new resources at center $center->{id}");

        # pull our resource info out
        my $resources;
        for my $res ( @owe ) {
            for my $stat ( qw( hour stored capacity ) ) {
                $resources->{"${res}_${stat}"} = $s->{"${res}_${stat}"};
            }
        }

        # determine what we want to make (hint: don't make it if it would excede capacity)
        my %producing = map { $_ => ( $resources->{ "${_}_capacity" } > $resources->{ "${_}_stored" } + 1 ) } @owe;
        my $production_count = sum( values %producing );
        unless ( $production_count ) {
            verbose("All storage is full. Falling back to balanced recycling.");
            $production_count = scalar @owe;
            @producing{ @owe } = (1) x $production_count;
        }

        #initialize our hash
        my %recycle = map { $_ => 0 } @owe;
        if ( $opts{'recycle-by-rate'} ) {
            my ($focus) = sort { $resources->{ "${a}_hour" } <=> $resources->{ "${b}_hour" } } @owe;
            $recycle{ $focus } = $recycle_capacity;
        }
        elsif ( $opts{'recycle-by-amount'} ) {
            my ($focus) =
                map  { $_->[0] }
                sort { $a->[1] <=> $b->[1] }
                map  { [ $_ => ($resources->{"${_}_stored"}/$resources->{"${_}_capacity"}) ] }
                grep { $producing{ $_ } }
                @owe;
            $recycle{ $focus } = $recycle_capacity;
        }
        else { # default to balanced recycling
            %recycle = map  { $_ => int( $recycle_capacity / $production_count ) * $producing{$_}||0 } @owe;
        }

        for my $res ( @owe ) {
            verbose("we want to make $recycle{$res} units of $res");
            $recycled{ $res } += $recycle{ $res };
        }

        $client->recycle_recycle($center->{id}, $recycle{water}, $recycle{ore}, $recycle{energy})
            unless $opts{'dry-run'};
        output("Recycled for $recycle{ore} ore, $recycle{water} water, and $recycle{energy} energy.");
        $left_to_recycle -= $recycle_capacity;
    }
    # TODO $self->cache_invalidate( type => 'body_status', id => $s->{id} );
    return \%recycled;
}
