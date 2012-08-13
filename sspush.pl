#!/usr/bin/perl

# tries to top off a space station, calculating just enough to fill it at time of arrival
# doesn't take into account ships in flight (or even the cargo capacity of the ship being sent)
# so not good for higher usage or farther away stations

use strict;
use warnings;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util 'sum';

autoflush STDOUT 1;
autoflush STDERR 1;

my %opt;
GetOptions( \%opt, 'config=s', 'from=s', 'to=s', 'ship=s', 'debug', 'quiet', 'log=s', 'types=s', 'send=i', 'dry-run', 'ore=s@', 'food=s@' )
    or die "$0 --config=foo.json --from=PlanetBar --to=SpaceStationFoo --ship=shipname\n";

$opt{'config'} ||= 'config.json';
$opt{'types'} ||= 'food,ore,water,energy';

my $client = Client->new(config => $opt{'config'});
my $planets = $client->empire_status->{planets};
my $from_id;
my $to_id;
for my $id (keys(%$planets)) {
    $from_id = $id if lc $planets->{$id} eq lc $opt{'from'};
    $to_id = $id if lc $planets->{$id} eq lc $opt{'to'};
}
if ( ! ( $from_id && $to_id ) ) {
    exit(1) if $opt{'quiet'};
    die "No matching planet for name $opt{'from'}\n" unless $from_id;
    die "No matching planet for name $opt{'to'}\n" unless $to_id;
}

my $from_name = $planets->{$from_id};
my $to_name = $planets->{$to_id};

my %resources = (
    'water' => [ qw/water/ ],
    'energy' => [ qw/energy/ ],
    'food' => $opt{'food'} || [ qw/algae apple bean beetle bread burger cheese chip cider corn fungus lapis meal milk pancake pie potato root shake soup syrup wheat/ ],
    'ore' => $opt{'ore'} || [ qw/anthracite bauxite beryl chalcopyrite chromite fluorite galena goethite gold gypsum halite kerogen magnetite methane monazite rutile sulfur trona uraninite zircon/ ],
    'waste' => [ qw/waste/ ],
);

# what ships and resources are available?
my $buildings = $client->body_buildings($from_id);
my %building_types;
for my $building_id ( keys %{ $buildings->{'buildings'} } ) {
    push @{ $building_types{$buildings->{'buildings'}{$building_id}{'name'}} }, $building_id;
}
my $trade_ministry = $building_types{'Trade Ministry'}[0];
if ( ! $trade_ministry ) {
    exit(1) if $opt{'quiet'};
    die "No trade ministry found on $from_name\n";
}
my $have_resources = $client->call('trade', 'get_stored_resources', $trade_ministry)->{'resources'};
my $ships = $client->call('trade', 'get_trade_ships', $trade_ministry, $to_id);
my @ship_list = grep $_->{'name'} eq $opt{'ship'}, @{ $ships->{'ships'} };
my ($example_ship) = @ship_list;
if ( ! $example_ship ) {
    exit(1) if $opt{'quiet'};
    die "Ship $opt{'ship'} not available on $from_name\n";
}

$client->cache_invalidate( type => 'body_status', id => $to_id );
$client->cache_invalidate( type => 'buildings', id => $to_id );

# what do we need to fill up (excluding supply pod capacity)?
my $to_buildings = $client->body_buildings($to_id);
my %supply_pod_capacity;
for my $supply_pod ( grep $to_buildings->{'buildings'}{$_}{'name'} eq 'Supply Pod', keys %{ $to_buildings->{'buildings'} } ) {
    my $capacity = $client->call( $to_buildings->{'buildings'}{$supply_pod}{'url'}, 'view', $supply_pod )->{'building'};
    for my $resource_type ( sort keys %resources ) {
        $supply_pod_capacity{$resource_type} += int( ( $capacity->{ $resource_type . '_capacity' } || 0 ) * ( $capacity->{'efficiency'} / 100 ) );
    }
}

my $to_status = $client->body_status($to_id);
my %need;
for my $resource_type ( split /,/, $opt{'types'} ) {
    $need{$resource_type} = int( $to_status->{ $resource_type . '_capacity' } - $to_status->{ $resource_type . '_stored' } - $to_status->{ $resource_type . '_hour' } * $example_ship->{'estimated_travel_time'} / 3600 ) - ( $supply_pod_capacity{$resource_type} || 0 ) - 1;
#    printf "%s\t%s\t%s/%s\t%s/hr\n", $resource_type, $need{$resource_type}, map $to_status->{$resource_type . "_$_"}, qw/stored capacity hour/;
    delete $need{$resource_type} if $need{$resource_type} <= 0;
}

if ( $opt{'dry-run'} ) {
    print "Resources needed:\n";
    print "$_: $need{$_}\n" for sort keys %need;
    print "total: " . sum( values %need ) . "\n";
}

my $ship_count = ($opt{send} || scalar(@ship_list));
my $max_send = $example_ship->{'hold_size'} * $ship_count;
if ($max_send < sum values %need) {
    my $factor = $max_send / sum values %need;
    $need{$_} *= $factor for keys %need;
}

if ( $opt{'dry-run'} ) {
    print "Ship capacity: $max_send\n";
    exit;
}

$need{$_} = int($need{$_} / $ship_count) for (keys %need);
for my $ship ( @ship_list[0 .. $ship_count - 1] ) {
    my %send;
    for my $resource_type ( sort keys %need ) {
    
        # for each type, take whatever there is most of, leaving them level

        my %available;
        for my $resource ( @{ $resources{$resource_type} } ) {
            if ( $have_resources->{$resource} ) {
                push @{ $available{ $have_resources->{$resource} } }, $resource;
            }
        }

        my $need = $need{$resource_type};
        my @quantities = sort { $b <=> $a } keys %available;
        while ( $need && @quantities ) {
            my $quantity = shift @quantities;
            my $next_quantity = $quantities[0] || 0;
            my @resources = sort @{ $available{$quantity} };

            # take enough of each to bump it down to the next lower occuring quantity
            # (or less, if that's too much)
            my $take = @resources * ( $quantity - $next_quantity );
            if ( $take > $need ) { $take = $need }
            my $take_per_resource = int( $take / @resources );
            my $remainder = $take - @resources * $take_per_resource;
            for my $resource ( @resources ) {
                $send{$resource} += $take_per_resource + ( --$remainder >= 0 );
                push @{ $available{$next_quantity} }, $resource;
            }
            $need -= $take;
        }
    }


    my @items = map { { type => $_, quantity => $send{$_} } } keys %send;
    $have_resources->{$_} -= $send{$_} for keys %send;

    my $result;
    eval {
        $result = $client->trade_push($trade_ministry, $to_id, \@items, { ship_id => $ship->{'id'} });
    } or die "error: $@\n";

    if ($result && ! $opt{'quiet'}) {
        $result = encode_json($result->{ship} || $result);
        if ($opt{'log'}) {
            open STDOUT, '>>', $opt{'log'} or die "Couldn't open logfile: $opt{'log'}\n";
        }
        print $result, "\n";
    }
}

