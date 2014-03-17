#!/usr/bin/perl

use strict;
use warnings;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $name = "storage";

GetOptions(
  "config=s" => \$config_name,
  "name=s"   => \$name,
) or die "$0 --config=foo.json --name=storage\n";

my $client = Client->new(config => $config_name);

my $boosts = $client->boost_view();
my $expire = Client::parse_time($boosts->{boosts}{$name});
if ($expire < time() + (3600 * 2)) {
  $client->boost_aspect($name);
  $boosts = $client->boost_view();
}

print Client::format_time(time())." booster: $name boost until ".Client::format_time(Client::parse_time($boosts->{boosts}{$name}))."\n";
