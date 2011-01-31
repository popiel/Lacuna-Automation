package Tools;

#use feature ':5.10';

use strict;
use warnings;

use Data::Dumper;
use Carp      qw( croak    );

use Exporter;
use base 'Exporter';

our @EXPORT_OK = qw(
    normalize_planet
);

our $VERSION = '0.01';

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

1;
