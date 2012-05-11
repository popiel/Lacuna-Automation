
use File::Basename qw(dirname);
my $script_path = dirname(__FILE__);
use lib "$script_path/..";
use Test::More;
use Data::Dumper;
#use Test::Mock::LWP;

BEGIN {
	use_ok('Client');
	use_ok('Tie::Lacuna');
}

my $client;
eval {
	$client = Client->new(config => "$script_path/test_config.json");
	#$client->{ua} = $Mock_ua;
};
isa_ok($client, 'Client');

my $lacuna;
eval {
	$lacuna = Tie::Lacuna::get_tie($client);
};
isa_ok($lacuna, 'HASH');

is_deeply([sort keys %$lacuna ], [ 'empire', 'planets' ]);
ok($lacuna->{empire}->{id}, 'autofetch $lacuna->{empire}->{id}');
cmp_ok($lacuna->{empire}->{essentia}, '>=', 0, 'can get empire data');
isa_ok($lacuna->{planets}, 'HASH', 'autofetch $lacuna->{planets}');

my $planet_name = [keys %{ $lacuna->{planets} }]->[0];
my $planet = $lacuna->{planets}->{ $planet_name };
diag("Using planet: $planet_name ($planet->{id})");
is_deeply([sort keys %$planet], [ qw( body buildings id ships status ) ], 'planet has the right keys');

my $buildings = $planet->{'buildings'};
isa_ok($buildings, 'HASH', 'autofetch $lacuna->{planets}->{"'.$planet_name.'"}->{buildings}');
ok(scalar(grep { $buildings->{$_}->{name} =~ /Planetary Command/ } keys %$buildings) == 1, 'found PCC');

is_deeply($lacuna->{planets}->{$planet->{id}}->{buildings}, $buildings, 'autofetch $lacuna->{planets}->{'.$planet->{id}.'}->{buildings}');

my $ships = $planet->{ships};
isa_ok($ships, 'ARRAY', 'autofetch $lacuna->{empire}->{"The Beginning"}->{ships}');


done_testing(13);

