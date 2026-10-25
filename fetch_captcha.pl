#!/usr/bin/perl
# Fetch one captcha and save it as captcha/<guid>.png.
# Does NOT attempt to solve; the PNG plus run of solver.py is the point.
# Usage: fetch_captcha.pl [--n=COUNT]   (default 1; hard cap 10)

use strict;

BEGIN {
  @INC = (@INC, ".", "local/lib/perl5");
}

use warnings;

use Client;
use LWP::UserAgent;
use Getopt::Long;

my $n = 1;
GetOptions("n=i" => \$n) or die "usage: $0 --n=1\n";
$n = 10 if $n > 10;

my $client = Client->new(config => "config.json");
my $ua = $client->{ua};

-d 'captcha' or mkdir 'captcha';
for my $i (1 .. $n) {
  my $captcha = $client->call(captcha => "fetch");
  my $guid = $captcha->{guid};
  my $file = "captcha/$guid.png";
  if (-f $file) {
    print "skip duplicate $guid\n";
    next;
  }
  my $response = $ua->get($captcha->{url});
  open(my $fh, ">", $file) or die "Couldn't write $file: $!\n";
  binmode $fh;
  print $fh $response->content;
  close($fh);
  print "saved $file\n";
}
