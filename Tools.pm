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
    usage
    debug
    verbose
    output
);

our %EXPORT_TAGS = (
    'all' => \@EXPORT_OK,
    'messages' => [qw(usage debug verbose output)],
);

our $VERSION = '0.01';

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

sub usage {
    die $main::usage;
}

sub debug {
    return unless ( grep { $main::opts{$_} } qw( debug d ) );
    output(' ==== ',@_);
}

sub verbose {
    return unless ( grep { $main::opts{$_} } qw( verbose v debug ) );
    output(' -- ',@_);
}

sub output {
    return if ( grep { $main::opts{$_} } qw( quiet q ) );
    print scalar(localtime),': ',@_,"\n";
}

1;
