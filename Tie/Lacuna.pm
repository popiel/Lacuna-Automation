package Tie::Lacuna;

use warnings;
use strict;
use Tie::Hash;
use Data::Dumper;

our @ISA = 'Tie::Hash';

=pod

=head1 Description

A hash-like interface for Lacuna data access.
Relies heavily on Client.pm's caching layer.

=head1 Usage

my $lacuna = Tie::Lacuna::get_tie();

# get empire id
my $empire_id = $lacuna->{'empire'}->{id};

#get planet status by id
my $planet_status = $lacuna->{'planets'}->{$planet_id}->{status};
$ or name
my $planet_status = $lacuna->{'planets'}->{'Planet name here'}->{status};

#get hashref of buildings on a planet (keyed by id)
my $buildings = $lacuna->{planets}->{'Planet name here'}->{buildings};

# list of ships on a planet
my @ships = $lacuna->{planets}->{'Planet name here'}->{ships};

=cut


{
	#$lacuna->{planets}->{'foo'}->{ships}
	#$lacuna->{planets}->{'foo'}->{buildings}
	my $prefix = {
		'empire' => { 
			'empire' => '_get_status', 
			'planets' => '_get_planets', 
		}, 
		'planet' => { 
			(map { $_ => '_get_planet' } qw( status buildings body name )),
			'ships' => '_get_ships',
		},
	};

	sub get_tie {
		my ($client, $obj_type, $hash) = @_;
		my %tied_hash;
		$hash ||= {};
		$obj_type ||= 'empire';
		tie %tied_hash, __PACKAGE__, { client => $client, 'ima' => $obj_type };
		$tied_hash{$_} = undef for keys(%{$prefix->{$obj_type}});
		$tied_hash{$_} = $hash->{$_} for keys(%$hash);
		return \%tied_hash;
	}

	sub FETCH {
		my ($self, $key) = @_;
		my $storage = $self->[0];
		my $settings = $self->[1];
		#print "Tied fetch for $key, type $settings->{ima}\n";

		if ($prefix->{$settings->{ima}}) {
			my $lazy_load = $prefix->{$settings->{ima}}->{$key};
			if ($lazy_load) {
				my $return = $self->$lazy_load($key);
				return $return;
			}
		}

		# checking for this last means that the hash updates itself based on
		# the $client cache, but does a lot of extra processing, and relies
		# heavily on that cache working to not consume lots of RPC.
		# Moving this to above the $prefix check would make the hash static,
		# (meaning it would never show updates)
		# if we also took care to assign the laxy_load results to $self.
		return $storage->{$key};

	}
}
# copied from Tie::ExtraHash
sub TIEHASH  { my $p = shift; bless [{}, @_], $p }
sub STORE    { $_[0][0]{$_[1]} = $_[2] }
#sub FETCH    { $_[0][0]{$_[1]} }
sub FIRSTKEY { my $a = scalar keys %{$_[0][0]}; each %{$_[0][0]} }
sub NEXTKEY  { each %{$_[0][0]} }
sub EXISTS   { exists $_[0][0]->{$_[1]} }
sub DELETE   { delete $_[0][0]->{$_[1]} }
sub CLEAR    { %{$_[0][0]} = () }
sub SCALAR   { scalar %{$_[0][0]} }

sub _get_status {
	my ($self, $key) = @_;
	my ($storage, $client) = ($self->[0], $self->[1]->{client});
	return $client->empire_status();
}

sub _get_planets {
	my ($self) = @_;
	my ($storage, $client) = ($self->[0], $self->[1]->{client});
	my $planets_by_id = $client->empire_status()->{'planets'};
	my $planets_by_name = {
		map {
			my $planet = get_tie($client, 'planet', { 'id' => $_, 'name' => $planets_by_id->{$_} });
			( 
				$planets_by_id->{$_} => $planet,
				$_ => $planet
			)
		}
		keys(%$planets_by_id)
	};
	return $planets_by_name;
}

sub _get_planet {
	my ($self, $key) = @_;
	my ($storage, $client) = ($self->[0], $self->[1]->{client});
	my $planet_status = $client->body_buildings($storage->{id});
	# load the results into $self
	$storage->{$_} = $planet_status->{$_} for keys %$planet_status;
	return $storage->{$key};
}

sub _get_ships {
	my ($self) = @_;
	my ($storage, $client) = ($self->[0], $self->[1]->{client});
	my $space_port = eval { $client->find_building($storage->{id}, "Space Port") };
	return [] unless $space_port;
	return $client->port_all_ships($space_port->{id})->{'ships'};
}
1;

