#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Date::Manip;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util qw(max first);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my $body_name;
my $queue_name;
my $debug = 0;
my $quiet_no_body = 0;
my $no_wait = 0;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
  "queue=s"  => \$queue_name,
  "debug"    => \$debug,
  "quiet_no_body"    => \$quiet_no_body,
  "no_wait"  => \$no_wait,
) or die "$0 --config=foo.json --body=Bar --queue=queue.file\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  exit(1) unless $body_id || !$quiet_no_body;
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

$body_name = $client->body_status($body_id)->{name};

my $buildings = $client->body_buildings($body_id);
for my $id (keys(%{$buildings->{buildings}})) { $buildings->{buildings}{$id}{id} = $id; }
my $ready_in;
my @builds = grep($_->{pending_build}, values(%{$buildings->{buildings}}));

$queue_name ||= "$body_name.queue";
$queue_name =~ s/\s+/_/g;

print "Reading build queue $queue_name\n" if $debug;
my $file;
open($file, "<", $queue_name) or die "Couldn't read queue file $queue_name: $!\n";
my @queue = (<$file>);
close $file;

my %foods = (
  "Planetary Command Center",  "algae",
  "Malcud Fungus Farm",        "fungus",
  "Malcud Burger Packer",      "burger",
  "Algae Cropper",             "algae",
  "Algae Syrup Bottler",       "syrup",
  "Amalgus Bean Plantation",   "bean",
  "Amalgus Bean Soup Cannery", "soup",
  "Potato Patch",              "potato",
  "Potato Pancake Factory",    "pancake",
  "Denton Root Patch",         "root",
  "Denton Root Chip Frier",    "chip",
  "Corn Plantation",           "corn",
  "Corn Meal Grinder",         "meal",
  "Wheat Farm",                "wheat",
  "Bread Bakery",              "bread",
  "Beeldeban Herder",          "beetle",
  "Beeldeban Protein Shake Factory", "shake",
  "Apple Orchard",             "apple",
  "Apple Cider Bottler",       "cider",
  "Lapis Orchard",             "lapis",
  "Lapis Pie Bakery",          "pie",
  "Dairy Farm",                "milk",
  "Cheese Maker",              "cheese",
  "Algae Pond",                "algae",
  "Malcud Field",              "fungus",
  "Beeldeban Nest",            "beetle",
  "Lapis Forest",              "lapis",
  "Denton Brambles",           "root",
  "Amalgus Meadow",            "bean",
);

my $buildable;
my $abort;
# This needs to be the C-like version of for, because I dink around with $j in some cases
for (my $j = $[; $j <= $#queue; $j++) {
  exit(0) if $abort;
  my $command = $queue[$j];
  chomp $command;
  $command =~ s/wait quietly/-wait/;
  my $quiet;
  my $rebuild;
  my $requeue;
  my $retain;
  $quiet = 1 if $command =~ s/^\-//;
  $abort = 1 if $command =~ s/^\!//;
  my $priority = ($abort) ? '!' : '';
  $rebuild = 1 if $command =~ s/^\+\+//;
  $requeue = 1 if $command =~ s/^\+//;
  $retain = 1 if $command =~ s/^\*//;
  my $sleepy = (localtime())[1] % 30;

  print "Inspecting $command\n" if $debug;
  if ($command =~ /^wait *(.*)/) {
    my $until = $1;
    my $date = ParseDate($until);
    if (!$quiet) {
      emit("Waiting until ".UnixDate($date, "%Y-%m-%d %H:%M"));
      splice(@queue, $j, 1, "-$queue[$j]");
      write_queue();
    }
    if (UnixDate($date, "%s") < time()) {
      splice(@queue, $j, 1);
      write_queue();
    } else {
      exit(0);
    }
  }
  if ($command =~ /^demolish (.*)/o) {
    my $name = $1;
    my ($x, $y);
    ($x, $y) = ($1, $2) if $name =~ s/^(-?\d) (-?\d) //;
    my $level;
    $level = $1 if $name =~ s/^(\d+) //;

    next if @builds;

    my @buildings = values(%{$buildings->{buildings}});
    my @targets = sort { $a->{level} <=> $b->{level} } grep { $_->{name} eq $name } @buildings;
    @targets = grep { $_->{level} == $level } @targets if $level;
    @targets = grep { $_->{x} == $x && $_->{y} == $y } @targets if $x || $y;
    my $target = $targets[0];

    unless ($target) {
      emit("Cannot demolish $name: no such building") unless $quiet && $sleepy;
      if (!$quiet) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    $client->building_demolish($target->{url}, $target->{id});
    emit("Demolished $name at $target->{x},$target->{y}");
    splice(@queue, $j, 1);
    @queue = map { s/^\-//; $_; } @queue;
    write_queue();
    $j--;
  }
  if ($command =~ /^build (.*)/o) {
    my $name = $1;
    my ($x, $y);
    ($x, $y) = ($1, $2) if $name =~ s/^(-?\d) (-?\d) //;

    next if @builds;

    $buildable ||= $client->body_buildable($body_id);
    my $reqs = $buildable->{buildable}{$name};
    unless ($reqs && ($reqs->{build}{can} || $reqs->{build}{reason}[1] =~ /Lost City of Tyleon/)) {
      emit("Cannot build $name: $reqs->{build}{reason}[1]") unless $quiet && $sleepy;
      if (!$quiet) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    my $build = eval { $client->body_build($body_id, $name, $x, $y) };
    if ($build) {
      emit("Building $name, complete at ".Client::format_time(Client::parse_time($build->{building}{pending_build}{end})));
      if ($retain) {
        emit("Retaining build command for $name");
      }
      else {
        splice(@queue, $j, 1);
      }
      if ($rebuild) {
        emit("Requeueing $name at the front of the queue");
        unshift(@queue, "$priority++upgrade 1 $name\n");
      }
      elsif ($requeue) {
        emit("Requeueing $name at the back of the queue\n");
        push(@queue, "+upgrade 1 $name\n");
      }
      @queue = map { s/^\-//; $_; } @queue;
      write_queue();
      $j--;
      push(@builds, $name);
    } else {
      if (my $e = Exception::Class->caught('LacunaRPCException')) {
        emit("Couldn't build $name: ".$e->code." ".$e->text);
      } else {
        my $e = Exception::Class->caught();
        ref $e ? $e->rethrow : die $e;
      }
    }
  }
  if ($command =~ /^upgrade (\<?) *(\d+) (.*)/o) {
    my $upTo = $1;
    my $level = $2;
    my $name = $3;
    my $realname = $name;

    next if @builds;

    if ($name eq "Tyleon") {
      my @buildings = values(%{$buildings->{buildings}});
      @buildings = grep { $_->{name} =~ /Tyleon/ } @buildings;
      @buildings = sort { ($a->{level} <=> $b->{level}) || ($a->{name} cmp $b->{name}) } @buildings;
      $name = $buildings[0]{name};
      $level = $buildings[0]{level} if $level && $buildings[0]{level} < $level;
    }
    for my $id (keys %{$buildings->{buildings}}) {
      my $building = $buildings->{buildings}{$id};
      print "Matching against $building->{level} $building->{name}\n" if $debug;
      if ($building->{name} eq $name && $building->{level} < 30 &&
          (!$level || ($upTo ? $building->{level} < $level : $building->{level} == $level))) {
        $building->{id} = $id;
        my $message = upgrade_check($building, 1);
        if ($message) {
          emit("Cannot upgrade $building->{level} $name: $message") unless $quiet && $sleepy;
          if ($queue[$j] !~ /^\-/) {
            splice(@queue, $j, 1, "-$queue[$j]");
            write_queue();
          }
          next;
        }
        my $upgrade = $client->building_upgrade($building->{url}, $id);
        emit("Upgrading $building->{level} $name, complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end})));
        if ($retain) {
          emit("Retaining upgrade command for $upTo$level $realname");
        }
        else {
          splice(@queue, $j, 1);
          if ($rebuild) {
            emit("Requeueing $realname at the front of the queue");
            unshift(@queue, sprintf("%s++upgrade %s %s\n", $priority, ($level ? $level + 1 : 0), $realname));
          }
          elsif ($requeue) {
            emit("Requeueing $realname at the back of the queue");
            push(@queue, sprintf("+upgrade %s %s\n", ($level ? $level + 1 : 0), $realname));
          }
        }
        @queue = map { s/^\-//; $_; } @queue;
        write_queue();
        $j--;
        push(@builds, $name);
        last;
      }
    }
  }
  if ($command =~ /^require (\d+x)? *(\d+) (.*)/o) {
    my $count = $1 || 1;
    my $level = $2;
    my $name = $3;

    $count =~ s/x$//;

    next if @builds;
    my @buildings = sort { $b->{level} <=> $a->{level} } grep { $_->{name} eq $name } values(%{$buildings->{buildings}});
    $#buildings = $count - 1 if @buildings > $count;
    if (@buildings < $count) {
      # Oops, have to build it.
      $buildable ||= $client->body_buildable($body_id);
      my $reqs = $buildable->{buildable}{$name};
      unless ($reqs && ($reqs->{build}{can} || $reqs->{build}{reason}[1] =~ /Lost City of Tyleon/)) {
        emit("Cannot build $name: $reqs->{build}{reason}[1]") unless $quiet && $sleepy;
        if (!$quiet) {
          splice(@queue, $j, 1, "-$queue[$j]");
          write_queue();
        }
        next;
      }
      my $build = eval { $client->body_build($body_id, $name) };
      if ($build) {
        emit("Building $name, complete at ".Client::format_time(Client::parse_time($build->{building}{pending_build}{end})));
        @queue = map { s/^\-//; $_; } @queue;
        write_queue();
        push(@builds, $name);
      } else {
        if (my $e = Exception::Class->caught('LacunaRPCException')) {
          emit("Couldn't build $name: ".$e->code." ".$e->text);
        } else {
          my $e = Exception::Class->caught();
          ref $e ? $e->rethrow : die $e;
        }
      }
    } else {
      my $building = pop(@buildings);
      if ($building->{level} >= $level) {
        $abort = 0;
        next;
      }

      my $message = upgrade_check($building, 1);
      if ($message) {
        emit("Cannot upgrade $building->{level} $name: $message") unless $quiet && $sleepy;
        if ($queue[$j] !~ /^\-/) {
          splice(@queue, $j, 1, "-$queue[$j]");
          write_queue();
        }
        next;
      }
      my $upgrade = $client->building_upgrade($building->{url}, $building->{id});
      emit("Upgrading $building->{level} $name, complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end})));
      @queue = map { s/^\-//; $_; } @queue;
      write_queue();
      push(@builds, $name);
    }
  }
  if ($command =~ /^subsidize (\d+ ?\w*)( limit (\d+))?/o) {
    my $time = $1;
    my $amount = $3;
    $amount ||= 2000;

    $time = $1         if $time =~ /^(\d+) ?s(econds?)?$/;
    $time = $1 * 60    if $time =~ /^(\d+) ?m(inutes?)?$/;
    $time = $1 * 3600  if $time =~ /^(\d+) ?h(ours?)?$/;
    $time = $1 * 86400 if $time =~ /^(\d+) ?d(ays?)?$/;

    next unless @builds;
    my $ready_in = max(map { eval { Client::parse_time($_->{pending_build}{end}) } || 0 } @builds) - time();
    next unless $ready_in > $time;
    next unless $client->empire_status->{essentia} > $amount;

    eval { 
      my $result = $client->body_subsidize($body_id);
      emit("Subsidized build queue for $result->{essentia_spent} essentia, saving ".duration($ready_in));
      @builds = ();
    };
  }
  if ($command =~ /^sacrifice (\<?) *(\d+) (.*)/o) {
    my $upTo = $1;
    my $level = $2;
    my $name = $3;

    next if @builds;

    my @buildings = values(%{$buildings->{buildings}});
    my $target = (grep { $_->{name} eq $name &&
                         ($level
                          ? $upTo ? $_->{level} < $level : $_->{level} == $level
                          : $_->{level} < 30) } @buildings)[0];
    if ($target) {
      my @halls = grep { $_->{name} eq "Halls of Vrbansk" } @buildings;
      my $plans = eval { first { $_->{name} eq "Halls of Vrbansk" } @{$client->body_plans($body_id)->{plans}} }
                  || { quantity => 0 };
      my $combo = @halls + $plans->{quantity};
      if ($combo <= $target->{level}) {
        emit("Insufficient halls to upgrade $name: have $combo, need ".($target->{level}+1)) unless $quiet && $sleepy;
        if ($queue[$j] !~ /^\-/) {
          splice(@queue, $j, 1, "-$queue[$j]");
          write_queue();
        }
        next;
      }
      # if (!@halls) {
      #   if ($no_wait) {
      #     emit("Building Halls of Vrbansk");
      #     my $result = $client->body_build($body_id, "Halls of Vrbansk");
      #     push(@builds, $name);
      #     next;
      #   } else {
      #     emit("Building Halls of Vrbansk, waiting 16 seconds");
      #     my $result = $client->body_build($body_id, "Halls of Vrbansk");
      #     push(@halls, $result->{building});
      #     sleep(16);
      #   }
      # }
      emit("Sacrificing ".($target->{level}+1)." halls to upgrade $name");
      my $upgrade = $client->building_upgrade($target->{url}, $target->{id});
      # $client->halls_sacrifice($halls[0]{id}, $target->{id});
      if ($retain) {
        emit("Retaining sacrifice command for $upTo$level $name");
      }
      else {
        splice(@queue, $j, 1);
      }
      @queue = map { s/^\-//; $_; } @queue;
      write_queue();
      $j--;
      push(@builds, $name);
      next;
    }
  }
  if ($command =~ /^shipbuild (.*)/o) {
    my $name = $1;

    my @buildings = values(%{$buildings->{buildings}});
    my $yard = (grep { $_->{name} eq "Shipyard" } @buildings)[0];

    next unless $yard;
    my $queue = $client->yard_queue($yard->{id});
    # emit(encode_json($queue));
    next if @{$queue->{ships_building}};

    my $buildable = $client->yard_buildable($yard->{id});
    my $ship = $buildable->{buildable}{$name};
    if (!$ship) {
      emit("Unrecognized ship type $name; supported types include: ". join(", ", sort keys(%{$buildable->{buildable}}))) unless $quiet && $sleepy;
      if ($queue[$j] !~ /^\-/) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    if (!$ship->{can}) {
      emit("Cannot build ship $name: $ship->{reason}[1]") unless $quiet && $sleepy;
      if ($queue[$j] !~ /^\-/) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    my $build = eval { $client->yard_build($yard->{id}, $name) };
    if ($build) {
      emit("Building ship $name, complete at ".Client::format_time(Client::parse_time($build->{ships_building}[0]{date_completed})));
      splice(@queue, $j, 1);
      if ($rebuild) {
        emit("Requeueing $name at the front of the queue");
        unshift(@queue, "$priority++shipbuild $name\n");
      }
      elsif ($requeue) {
        emit("Requeueing $name at the back of the queue\n");
        push(@queue, "+shipbuild $name\n");
      }
      @queue = map { s/^\-//; $_; } @queue;
      $j--;
      write_queue();
    }
  }
  if ($command =~ /^resources(.*)/o) {
    my $args = $1;
    my @args = split(/,/, $args);
    grep(s/^\s*//, @args);
    grep(s/\s*$//, @args);

    next if @builds;

    my $focus     = "stored";
    my $max_level = 15;
    my $prod_bias = 24;
    my $balance   = 0;
    my %ignore;
    for my $arg (@args) {
      $focus     = $1 if $arg =~ /focus (store|hour|prod)/;
      $max_level = $1 if $arg =~ /max level (\d+)/;
      $prod_bias = $1 if $arg =~ /production bias (\d+)/;
      $balance   = 1  if $arg =~ /balance/;
      if ($arg =~ /ignore (.+)/) {
        my $stuff = $1;
        $ignore{$_} = 1 for split(/\s+/, $stuff);
      }
    }
    $focus = ($focus =~ /store/) ? "stored" : "hour";

    my @buildings = values(%{$buildings->{buildings}});
    my $status = $client->body_status($body_id);
    my %ratio;
    for my $type (qw(food ore water energy)) {
      $ratio{$type} = $status->{"${type}_stored"} / $status->{"${type}_capacity"};
    }
    my $type = (sort { $ratio{$a} <=> $ratio{$b} } keys %ratio)[0];

    unless (grep { $_ eq 'no storage' } @args) {
      if ($ratio{$type} > 0.05) {
        my @storage = sort { $a->{level} <=> $b->{level} || $b->{name} cmp $a->{name} }
                      grep { $_->{name} =~ /^(Ore|Water|Food|Energy) (Storage|Reserve)/ }
                      @buildings;
        if ($storage[0]{level} < $storage[$#storage]{level}) {
          emit("Equalizing storage levels") unless $quiet && $sleepy;
          my $building = $storage[0];
          my $message = upgrade_check($building, 1);
          if ($message) {
            emit("Cannot upgrade $building->{level} $building->{name}: $message") unless $quiet && $sleepy;
            if ($queue[$j] !~ /^\-/) {
              splice(@queue, $j, 1, "-$queue[$j]");
              write_queue();
            }
            next;
          }
          else {
            my $upgrade = $client->building_upgrade($building->{url}, $building->{id});
            emit("Equalizing storage levels") if $quiet && $sleepy;
            emit("Upgrading $building->{level} $building->{name}, complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end})));
            @queue = map { s/^\-//; $_; } @queue;
            write_queue();
            push(@builds, $building);
            next;
          }
        }

        $type = (sort { $ratio{$b} <=> $ratio{$a} } grep { !$ignore{$_} } keys %ratio)[2];
        if ($ratio{$type} > 0.95) {
          emit("Near storage limit for $type") unless $quiet && $sleepy;
          my @storage = sort { $a->{level} <=> $b->{level} }
                        grep { $_->{name} =~ /^$type (Storage|Reserve)/i }
                        @buildings;
          if (@storage) {
            my $building = $storage[0];
            my $message = upgrade_check($building, 1);
            if ($message) {
              emit("Cannot upgrade $building->{level} $building->{name}: $message") unless $quiet && $sleepy;
              if ($queue[$j] !~ /^\-/) {
                splice(@queue, $j, 1, "-$queue[$j]");
                write_queue();
              }
              next;
            }
            else {
              my $upgrade = $client->building_upgrade($building->{url}, $building->{id});
              emit("Near storage limit for $type") if $quiet && $sleepy;
              emit("Upgrading $building->{level} $building->{name}, complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end})));
              @queue = map { s/^\-//; $_; } @queue;
              write_queue();
              push(@builds, $building);
              next;
            }
          }
        }
      }
    }

    next if grep { $_ eq 'storage only' } @args;

    if ($focus eq "stored") {
      $type = (sort { $ratio{$a} <=> $ratio{$b} } grep { !$ignore{$_} } keys %ratio)[0];
    } else {
      $type = (sort { $status->{"${a}_hour"} <=> $status->{"${b}_hour"} } grep { !$ignore{$_} } keys %ratio)[0];
    }
    emit("Want to upgrade $type production") unless $quiet && $sleepy;

    @buildings = grep { $_->{name} !~ /Algae Pond|Malcud Field|Lapis Forest|Beeldeban Nest|Geo Thermal Vent|Volcano|Natural Spring/ } @buildings;
    @buildings = grep { $_->{"${type}_hour"} >= 0 } map { populate_building_with_production($_, @buildings) } @buildings;
    my %prod;
    if ($balance && $type eq "food") {
      $prod{$foods{$_->{name}}} += $_->{food_hour} for grep { $foods{$_->{name}} } @buildings;
    }
    my $max_prod = List::Util::max(values(%prod));
    for my $building (@buildings) {
      $building->{delay} = List::Util::max(0, map { ($building->{upgrade}{cost}{$_} - $status->{"${_}_stored"}) / ($status->{"${_}_hour"} || 0.001) } qw(food ore water energy));
      $building->{delay} *= 100 if grep { $_ eq 'avoid delay' } @args;
      $building->{cost_time} = List::Util::max($building->{delay} + $building->{upgrade}{cost}{time} / 3600, map { $building->{upgrade}{cost}{$type} / ($status->{"${_}_hour"} || 1) } qw(food ore water energy));
      $building->{payoff} = $building->{upgrade}{production}{"${type}_hour"} - $building->{"${type}_hour"};
      if ($type eq "ore" && $building->{name} eq "Ore Refinery") {
        my $current = List::Util::sum(map { $_->{ore_hour} }
                                      grep { $_->{name} =~ /Volcano|Mine|Planetary Command Center/ } @buildings);
        my $base = $current / (1 + $building->{level} * 0.05);
        $building->{payoff} += $base * 0.05;
      }
      $building->{cost_prod} = $prod_bias * List::Util::sum(
        map {
          my $diff = $building->{"${_}_hour"} - $building->{upgrade}{production}{"${_}_hour"};
          $diff = -$diff if $_ eq "waste";
          $status->{"${_}_hour"} <= $diff ? 10000 : $diff / ($status->{"${_}_hour"} - $diff);
        }
        grep { $_ ne $type } qw(food ore water energy waste)
      );
      $building->{payoff_ratio} = $building->{payoff} / List::Util::max(0.1, List::Util::max($building->{cost_time}, $building->{cost_prod}));
    }
    if ($balance && $type eq "food") {
      $max_prod += 1 + List::Util::max(map { $_->{payoff} } @buildings);
      for my $building (@buildings) {
        $building->{payoff} = $max_prod - $prod{$foods{$building->{name}}} - $building->{payoff};
        $building->{payoff} = 0 unless $foods{$building->{name}};
        $building->{payoff_ratio} = $building->{payoff} / List::Util::max(0.1, List::Util::max($building->{cost_time}, $building->{cost_prod}));
      }
    }

    @buildings = grep { $_->{payoff_ratio} > 0 } @buildings;
    @buildings = grep { $_->{url} !~ /beach/ } @buildings;
    #@buildings = grep { upgrade_check($_) !~ /You can't upgrade.*naturally/ } @buildings;

    @buildings = sort { $b->{payoff_ratio} <=> $a->{payoff_ratio} } @buildings;
    if (!($quiet && $sleepy)) {
      for my $building (@buildings) {
        printf("%s payoff ratio: %7.2f: c_t %5.2f, c_p %5.2f, wait %5.2f: %d %s\n",
               $type, $building->{payoff_ratio},
               $building->{cost_time}, $building->{cost_prod}, $building->{delay},
               $building->{level}, $building->{name});
      }
    }

    @buildings = sort { $b->{level} <=> $a->{level} } @buildings;
    my @pruned;
    for my $building (@buildings) {
      next if grep(/^0x ?$building->{name}/, @args);
      grep(s/^(\d+)x ?$building->{name}/($1 - 1)."x $building->{name}"/e, @args);
      push(@pruned, $building);
    }
    @buildings = @pruned;
    @buildings = grep { $_->{level} < $max_level } @buildings;

    @buildings = sort { $b->{payoff_ratio} <=> $a->{payoff_ratio} } @buildings;
    # my $building = $buildings[0];
    my $building = first { upgrade_check($_) !~ /You can't upgrade.*naturally/ } @buildings;
    unless ($building) {
      emit("No upgradable buildings for resource $type!") unless $quiet && $sleepy;
      if ($queue[$j] !~ /^\-/) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    my $message = upgrade_check($building, 1);
    if ($message) {
      emit("Cannot upgrade $building->{level} $building->{name}: $message") unless $quiet && $sleepy;
      if ($queue[$j] !~ /^\-/) {
        splice(@queue, $j, 1, "-$queue[$j]");
        write_queue();
      }
      next;
    }
    else {
      my $upgrade = $client->building_upgrade($building->{url}, $building->{id});
      if ($quiet && $sleepy) {
        emit("Want to upgrade $type production");
        for my $building (@buildings) {
          printf("%s payoff ratio: %7.2f: c_t %5.2f, c_p %5.2f, wait %5.2f: %d %s\n",
                 $type, $building->{payoff_ratio},
                 $building->{cost_time}, $building->{cost_prod}, $building->{delay},
                 $building->{level}, $building->{name});
        }
      }
      emit("Upgrading $building->{level} $building->{name}, complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end})));
      @queue = map { s/^\-//; $_; } @queue;
      write_queue();
      push(@builds, $building);
    }
  }
}

sub upgrade_check {
  my $building = shift;
  my $side_effects = shift;
  return "Undefined building." unless $building;
  $building = populate_building_with_production($building);
  my @buildings = values(%{$buildings->{buildings}});
  my $depot = List::Util::first { $_->{url} =~ /subspacesupplydepot/ } @buildings;
  my $status = $client->body_status($body_id);
  my @message;
  for (qw(food ore water energy)) {
    push(@message, "$_ (".$status->{"${_}_capacity"}."/".$building->{upgrade}{cost}{$_}.")")
      if $status->{"${_}_capacity"} < $building->{upgrade}{cost}{$_};
  }
  return "Not enough capacity for ".join(", ", @message)." to build this." if @message;
  for (qw(food ore water energy)) {
    while ($side_effects && $depot && $depot->{work}{seconds_remaining} >= 3600 &&
        $status->{"${_}_stored"} < $building->{upgrade}{cost}{$_} &&
        $status->{"${_}_stored"} < $status->{"${_}_capacity"} - 3600) {
      emit("Getting 3600 $_ from depot.");
      my $result = eval { $client->depot_transmit($depot->{id}, $_) };
      last unless $result;
      if ($result && $result->{building}) {
        $depot = { %$depot, %{$result->{building}} };
      }
      $status = $client->body_status($body_id);
    }
    push(@message, "$_ (".$status->{"${_}_stored"}."/".$building->{upgrade}{cost}{$_}.", ".duration(($building->{upgrade}{cost}{$_} - $status->{"${_}_stored"}) * 3600 / $status->{"${_}_hour"}).")")
      if $status->{"${_}_stored"} < $building->{upgrade}{cost}{$_};
  }
  return "Not enough ".join(", ", @message)." in storage to build this." if @message;
  for (qw(food ore water energy)) {
    push(@message, "$_ (".($status->{"${_}_hour"} - $building->{upgrade}{production}{"${_}_hour"} + $building->{"${_}_hour"})."/hour)")
      if $status->{"${_}_hour"} < $building->{upgrade}{production}{"${_}_hour"} - $building->{"${_}_hour"};
  }
  return "Unsustainable. Not enough ".join(", ", @message)." production." if @message;
  my $view = $client->building_view($building->{url}, $building->{id})->{building};
  return $view->{upgrade}{reason}[1] unless $view->{upgrade}{can};
  return;
}

sub duration {
  my $seconds = shift;

  my $result = "";
  if ($seconds >= 86400) { $result .= sprintf("%dd ", int($seconds / 86400)); $seconds = $seconds % 86400; }
  if ($seconds >=  3600) { $result .= sprintf("%dh ", int($seconds /  3600)); $seconds = $seconds %  3600; }
  if ($seconds >=    60) { $result .= sprintf("%dm ", int($seconds /    60)); $seconds = $seconds %    60; }
  if ($seconds >=     1) { $result .= sprintf("%ds ", int($seconds /     1)); $seconds = $seconds %     1; }
  chop $result;
  $result;
}

sub populate_building_with_production {
  my $building = shift;
  my @buildings = @_;
  my ($name,$level) = ($building->{name}, $building->{level});
  # print "Viewing data for $level $name\n";
  unless ($building->{url}) {
    print "No url for building $building->{id}, name $building->{name}\n";
    return $building;
  }
  my $stats = $client->building_stats_for_level($building->{url}, $building->{id}, $building->{level})->{building};
  return { %$building, %$stats };
}

sub emit {
  my $message = shift;
  our $last_message;
  return if $message eq $last_message;
  $last_message = $message;
  print Client::format_time(time())." $body_name: $message\n";
}

sub write_queue {
  my $file;
  open($file, ">", "$queue_name.$$") or croak "Could not write queue file $queue_name.$$: $!";
  print $file join("", @queue);
  close $file;
  rename("$queue_name.$$", $queue_name) or croak "Could not rename queue file $queue_name.$$ to $queue_name: $!";
}
