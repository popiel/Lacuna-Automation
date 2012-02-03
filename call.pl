#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $body_name;

GetOptions(
  "config=s" => \$config_name,
) or die "$0 --config=foo.json\n";

my $client = Client->new(config => $config_name);
my @args = map { $_ =~ /\{/ ? decode_json($_) : $_ } @ARGV;
my $result = $client->call(@args);
print JSON::PP->new->allow_nonref->canonical->pretty->encode($result);
