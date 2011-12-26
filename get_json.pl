#!/usr/bin/perl

use strict;

use JSON::XS;

my $path = shift(@ARGV);
my $raw = 0;
if ($path eq "--raw") {
  $raw = 1;
  $path = shift(@ARGV);
}

my @lines = (<>);

my $hash = decode_json(join('', @lines));

if ($path) {
  for my $key (split(/\//, $path)) {
    $hash = $hash->{$key};
  }
}

$hash = $hash + 0 if !ref($hash) && $hash eq ($hash + 0);

if ($raw && !ref($hash)) {
  print $hash;
} else {
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
