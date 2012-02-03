#!/usr/bin/perl

use strict;

use Getopt::Long;
use JSON::PP;
use List::Util;
use Time::Local;

my $config_name = "config.json";
my $body_name;
my $initial_name;

GetOptions(
  "config=s"        => \$config_name,
  "body=s"          => \$body_name,
  "initial|start=s" => \$initial_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $options = "";
$options .= " --config $config_name" if $config_name;
$options .= " --body $body_name" if $body_name;

my $info = decode_json(`get_buildable_info $options`);

my $initial;
if ($initial_name) {
  $initial = decode_json(`cat $initial_name`);
} else {
  $initial = decode_json(`get_planetary_state $options`);
}

my @buildings = @{$initial->{buildings}};
my %stocks    = %{$initial->{stored}};
my $time      =   $initial->{time};

my %production;
my %capacity;

sub format_time {
  my $time = shift;

  my @elems = reverse((localtime($time))[0..5]);
  $elems[0] += 1900;
  $elems[1]++;
  sprintf("%4d-%02d-%02d %02d:%02d:%02d", @elems);
}

sub emit {
  my $message = shift;
  print format_time($time)." $message\n";
}

sub compute_production {
  %production = ();
  %capacity   = ();
  for my $building (@buildings) {
    for my $resource (qw(food ore water energy waste)) {
      $production{$resource} += $info->{$building->{name}}{$building->{level}}{production}{$resource};
      $capacity  {$resource} += $info->{$building->{name}}{$building->{level}}{capacity  }{$resource};
    }
  }
  emit("production: ".join("; ", map { "$_ $production{$_}" } qw(food ore water energy waste)));
  for my $resource (qw(food ore water energy)) {
    die "Unsustainable! Production of $resource is less than 1!\n" if $production{$resource} < 1;
  }
  die "Unsustainable! Stock of waste is less than 1!\n" if $production{waste} < 1 && $stocks{waste} < 1;
}

sub time_until {
  my $amount = shift;
  my $act = shift;

  my $wait = 0;
  my $on;
  for my $resource (qw(food ore water energy)) {
    my $target = $amount->{$resource} + $production{$resource} / 10;
    die "Cannot $act: Insufficient capacity for $resource: need $amount->{$resource}, capacity $capacity{$resource}\n"
      if $target > $capacity{$resource};
    
    if ($target > $stocks{$resource}) {
      my $delay = int(($target - $stocks{$resource}) / $production{$resource} * 3600 + 1);
      if ($wait < $delay) {
        $wait = $delay;
        $on = int($target - $stocks{$resource}) . " $resource";
      }
    }
  }
  emit("waiting $wait seconds for $on") if $on;
  return $wait;
}

sub subtract {
  my $amount = shift;
  for my $resource (qw(food ore water energy)) {
    $stocks{$resource} -= $amount->{$resource};
  }
  $stocks{waste} += $amount->{waste};
}

sub project {
  my $delta = shift;

  for my $resource (qw(food ore water energy waste)) {
    $stocks{$resource} += $production{$resource} * $delta / 3600;
    $stocks{$resource} = 0 if $stocks{$resource} < 0;
    $stocks{$resource} = $capacity{$resource} if $stocks{$resource} > $capacity{$resource};
  }
  $time += $delta;
  emit(join("; ", map { sprintf("%s %d/%d", $_, $stocks{$_}, $capacity{$_}) } qw(food ore water energy waste)));
}

compute_production();
my $line;
while ($line = <>) {
  if ($line =~ /^build (.*)/) {
    my $name = $1;

    project(time_until($info->{$name}{1}{cost}, "build $name"));
    emit("Starting build $name");
    subtract($info->{$name}{1}{cost});
    project($info->{$name}{1}{cost}{time});
    emit("Finished build $name");

    push(@buildings, { name => $name, level => 1 });
    compute_production();
  }
  if ($line =~ /^upgrade (\d+) (.*)/) {
    my $level = $1;
    my $name = $2;

    my $index;
    while ($index < @buildings && ($buildings[$index]{name} ne $name || $buildings[$index]{level} != $level)) {
      $index++;
    }
    die "No $level $name to upgrade\n" unless $index < @buildings;

    project(time_until($info->{$name}{$level}{upgrade}, "upgrade $level $name"));
    emit("Starting upgrade $level $name");
    subtract($info->{$name}{$level}{upgrade});
    project($info->{$name}{$level}{upgrade}{time});
    emit("Finished upgrade $level $name");
    
    $buildings[$index]{level}++;
    compute_production();
  }
  if ($line =~ /^recycle (\d+) (.*)/) {
    my $amount = $1;
    my $resource = $2;

    emit("Starting recycle $amount $resource");
    subtract({ waste => -$amount });
    project($amount / 1578 * 3600);
    emit("Finished recycle $amount $resource");
    subtract({ $resource => -$amount });
  }
}
