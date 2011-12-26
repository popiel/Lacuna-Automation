#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::XS;
use List::Util qw(first min max sum);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_names;
my $ship_name;
my $equalize = 0;
my $themepark = 0;
my $debug = 0;
my $quiet = 0;
my $noaction = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_names,
  "ship|name=s" => \$ship_name,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
  "noaction!"    => \$noaction,
) or die "$0 --config=foo.json --body=Bar\n";

my @foods = qw(algae apple bean beetle bread burger
               cheese chip cider corn fungus lapis
               meal milk pancake pie potato root
               shake soup syrup wheat);
my @ores = qw(anthracite bauxite beryl chalcopyrite chromite
              fluorite galena goethite gold gypsum
              halite kerogen magnetite methane monazite
              rutile sulfur trona uraninite zircon);
my @resources = (@foods, @ores, qw(water energy waste));
my @categories = qw(food energy ore waste water);

die "Must specify at least two bodies\n" unless @body_names >= 2;
$ship_name ||= join(" ", @body_names);

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};

my %vitals = get_vitals();
emit_json("vitals", \%vitals);
my %ideals = express_desires(%vitals);
emit_json("ideals", \%ideals);
my @moves = find_best_shipping(\%vitals, \%ideals);
emit_json("moves", \@moves);
push_resources(@moves);

sub get_vitals {
  my $cached = $client->cache_read(type => "misc", id => "trade_vitals_@body_names");
  return %{$cached->{vitals}} if $cached;
  my %vitals;
  for my $name (@body_names) {
    my $body_id = first { $planets->{$_} =~ /$name/ } keys %$planets;
    die "No matching planet for name $name\n" unless $body_id;
    my $buildings = $client->body_buildings($body_id)->{buildings};
    my $trade_id = first { $buildings->{$_}{name} eq 'Trade Ministry' } keys %$buildings;
    my $theme_id = first { $buildings->{$_}{name} eq 'Theme Park'     } keys %$buildings;
    my $resources = $client->call(trade => get_stored_resources => $trade_id);
    my $body = $resources->{status}{body};
    my @ships = sort { $b->{hold_size} <=> $a->{hold_size} }
                grep { $_->{name} =~ /$ship_name/ }
                @{$client->call(trade => get_trade_ships => $trade_id)->{ships}};
    exit(1) if $quiet && !@ships;
    die "No ships available for name $ship_name on planet $planets->{$body_id}\n" unless @ships;
    $vitals{$body_id} = {
      body_id => $body_id,
      trade_id => $trade_id,
      theme_id => $theme_id,
      resources => $resources->{resources},
      capacities => { map { $_, int(max($body->{"${_}_capacity"} - $body->{"${_}_hour"} / 2,
                                        $body->{"${_}_capacity"} / 2)) } @categories },
      ship => $ships[0],
    };
  }
  $client->cache_write(type => "misc", id => "trade_vitals_@body_names", invalid => time() + 600, data => { vitals => \%vitals });
  return %vitals;
}

sub express_desires {
  my %vitals = @_;

  my %ideals;
  my %totals;
  my %capacities;

  for my $body_id (keys %vitals) {
    for my $res (@resources) {
      $totals{$res} += $vitals{$body_id}{resources}{$res};
    }
    for my $cat (@categories) {
      $capacities{$cat} += $vitals{$body_id}{capacities}{$cat};
    }
  }

  emit("Distributing waste:") if $debug;
  # Distribute waste proportionally
  for my $body_id (keys %vitals) {
    $ideals{$body_id}{waste} = int($totals{waste} * $vitals{$body_id}{capacities}{waste} / $capacities{waste});
  }
  emit("Waste: ".join(", ", map { "$planets->{$_} $ideals{$_}{waste}" } keys %vitals)) if $debug;

  # Split water and energy as evenly as possible, maxing out the smaller capacities.
  for my $res (qw(water energy)) {
    emit("Distributing $res:") if $debug;
    my @ids = sort { $vitals{$a}{capacities}{$res} <=> $vitals{$b}{capacities}{$res} } keys %vitals;
    my $remain = $totals{$res};
    while (@ids) {
      $ideals{$ids[0]}{$res} = min(int($remain / @ids), $vitals{$ids[0]}{capacities}{$res});
      $remain -= $ideals{$ids[0]}{$res};
      shift @ids;
    } 
    emit("$res: ".join(", ", map { "$planets->{$_} $ideals{$_}{$res}" } keys %vitals)) if $debug;
    emit("$res: Original total $totals{$res}, distributed total ".sum(map { $ideals{$_}{$res} } keys %vitals)) if $debug;
  }

  # Split ores as evenly as possible, except where that overfills capacity.
  # Where capacity is filled, take equal amounts of ores up to the equal distribution above.
  {
    my @ids = sort { $vitals{$a}{capacities}{ore} <=> $vitals{$b}{capacities}{ore} } keys %vitals;
    my %remain = map { $_, $totals{$_} } grep { $totals{$_} } @ores;
    while (@ids) {
      my %partial = map { $_, int($remain{$_} / @ids) } grep { $remain{$_} >= @ids } keys %remain;
      if (sum(values %partial) > $vitals{$ids[0]}{capacities}{ore}) {
        my $space = $vitals{$ids[0]}{capacities}{ore};
        my @res = sort { $partial{$a} <=> $partial{$b} } keys %partial;
        while (@res) {
          $ideals{$ids[0]}{$res[0]} = min(int($space / @res), $partial{$res[0]});
          $remain{$res[0]} -= $ideals{$ids[0]}{$res[0]};
          $space -= $ideals{$ids[0]}{$res[0]};
          shift @res;
        }
      } else {
        for my $res (keys %partial) {
          $ideals{$ids[0]}{$res} = $partial{$res};
          $remain{$res} -= $ideals{$ids[0]}{$res};
        }
      }
      shift @ids;
    }
  }

  # If there is a theme park on the planet, try for 1010 of each food,
  #   and split remaining capacity among 5 foods.
  # Otherwise, split foods as evenly as possible, except where that overfills capacity.
  # Where capacity is filled, take equal amounts of foods up to the equal distribution above.
  {
    my @ids = sort { !$vitals{$a}{theme_id} <=> !$vitals{$b}{theme_id} ||
                     $vitals{$a}{capacities}{food} <=> $vitals{$b}{capacities}{food} } keys %vitals;
    my %remain = map { $_, $totals{$_} } grep { $totals{$_} } @foods;
    while (@ids) {
      if ($vitals{$ids[0]}{theme_id}) {
        my @res = sort { $remain{$b} <=> $remain{$a} } grep { $remain{$_} >= 1010 } keys %remain;
        my @head = splice(@res, 0, 5);
        my $space = $vitals{$ids[0]}{capacities}{food};
        while (@res) {
          last if $space < 1010;
          $ideals{$ids[0]}{$res[0]} = 1010;
          $remain{$res[0]} -= 1010;
          $space -= 1010;
          shift @res;
        }
        @res = reverse @head;
        while (@res) {
          $ideals{$ids[0]}{$res[0]} = min(int($space / @res), $remain{$res[0]});
          $remain{$res[0]} -= $ideals{$ids[0]}{$res[0]};
          $space -= $ideals{$ids[0]}{$res[0]};
          shift @res;
        }
      } else {
        my %partial = map { $_, int($remain{$_} / @ids) } grep { $remain{$_} >= @ids } keys %remain;
        if (sum(values %partial) > $vitals{$ids[0]}{capacities}{food}) {
          my $space = $vitals{$ids[0]}{capacities}{food};
          my @res = sort { $partial{$a} <=> $partial{$b} } keys %partial;
          while (@res) {
            $ideals{$ids[0]}{$res[0]} = min(int($space / @res), $partial{$res[0]});
            $remain{$res[0]} -= $ideals{$ids[0]}{$res[0]};
            $space -= $ideals{$ids[0]}{$res[0]};
            shift @res;
          }
        } else {
          for my $res (keys %partial) {
            $ideals{$ids[0]}{$res} = $partial{$res};
            $remain{$res} -= $ideals{$ids[0]}{$res};
          }
        }
      }
      shift @ids;
    }
  }

  return %ideals;
}

sub find_best_shipping {
  my %vitals = %{shift()};
  my %ideals = %{shift()};

  my @bodies = keys %vitals;
  my $first = shift @bodies;

  my @moves = order_helper(\%vitals, \%ideals, [ $first ], [ @bodies ]);
  my $amount = sum(map { sum values %{$_->{items}} } @moves);
  emit("Best total $amount with order ".join(", ", map { $planets->{$_->{source_id}} } @moves));
  return @moves;
}

sub order_helper {
  my $vitals = shift;
  my $ideals = shift;
  my $order  = shift;
  my $remain = shift;

  return shipping_for_order($vitals, $ideals, $order) unless @$remain;

  my $best_amount = 0;
  my @best_moves = ();

  for my $next (@$remain) {
    next if grep { $next eq $_ } @$order;
    my @moves = order_helper($vitals, $ideals, [ @$order, $next ], [ grep { $next ne $_ } @$remain ]);
    my $amount = sum(map { sum values %{$_->{items}} } @moves);

    if ($best_amount < $amount) {
      $best_amount = $amount;
      @best_moves  = @moves;
    }
  }

  return @best_moves;
}

sub shipping_for_order {
  my %vitals = %{shift()};
  my %ideals = %{shift()};
  my @order  = @{shift()};

  # For each resource, find planet with most of it
  # my %max = map { $_, (sort { $ideals{$b}{$_} - $vitals{$b}{resources}{$_} <=>
  #                             $ideals{$a}{$_} - $vitals{$a}{resources}{$_} } keys %vitals)[0] } @resources;
  my %max = map { $_, (sort { $vitals{$b}{resources}{$_} <=>
                              $vitals{$a}{resources}{$_} } keys %vitals)[0] } @resources;

  # Map the order
  my %next = map { $order[$_], $order[($_+1) % @order] } 0..$#order;
  my %prev = reverse %next;

  # Walk backwards through order, determining shipping quantities based on want and availability
  my %moves;
  for my $res (@resources) {
    my $pos = $max{$res};
    $moves{$prev{$pos}}{$res} = max(0, min($vitals{$prev{$pos}}{resources}{$res} - 10, $ideals{$pos}{$res} - $vitals{$pos}{resources}{$res}));
    for ($pos = $prev{$max{$res}}; $pos ne $max{$res}; $pos = $prev{$pos}) {
      $moves{$prev{$pos}}{$res} = max(0, min($vitals{$prev{$pos}}{resources}{$res} - 10, $ideals{$pos}{$res} - $vitals{$pos}{resources}{$res} + $moves{$pos}{$res}));
    }
  }
  emit_json("first pass", \%moves);

  # For each leg, detect over capacity for transport
  for (;;) {
    my %totals = map { $_, sum(values(%{$moves{$_}})) } keys %moves;
    my %deltas = map { $_, $vitals{$_}{ship}{hold_size} - $totals{$_} } keys %totals;
    my @violations = sort { $deltas{$a} <=> $deltas{$b} } grep { $deltas{$_} < 0 } keys %deltas;
    last unless @violations;

    my $bad = $violations[0];
    my %stuff = %{$moves{$bad}};
    $moves{$bad} = {};
    my $limit = $vitals{$bad}{ship}{hold_size};

    emit("Over shipping limit on $planets->{$bad}: want to move $totals{$bad}, limit $limit") unless $quiet;

    # Transport resources evenly up to previously computed levels
    my @res = sort { $stuff{$a} <=> $stuff{$b} } keys %stuff;
    while (@res) {
      $moves{$bad}{$res[0]} = min(int($limit / @res), $stuff{$res[0]});
      $limit -= $moves{$bad}{$res[0]};
      shift @res;
    }

    # Adjust cascaded shipping quantities as needed
    for my $res (@resources) {
      for (my $pos = $bad; $pos ne $next{$bad}; $pos = $prev{$pos}) {
        $moves{$prev{$pos}}{$res} = max(0, min($moves{$prev{$pos}}{$res}, $vitals{$prev{$pos}}{resources}{$res} - 10, $ideals{$pos}{$res} - $vitals{$pos}{resources}{$res} + $moves{$pos}{$res}));
      }
    }
    emit_json("after reduction pass", \%moves);
  }

  my $total_moves = sum(map { sum values %$_ } values %moves);
  emit("Total $total_moves moved for order ".join(", ", map { $planets->{$_} } @order)) unless $quiet;

 # Convert to move structure
  my @moves = map {
    {
      source_id => $_,
      target_id => $next{$_},
      trade_id  => $vitals{$_}{trade_id},
      ship      => $vitals{$_}{ship},
      items     => { %{$moves{$_}} },
    }
  } @order;

  return @moves;
}

sub push_resources {
  my @moves = @_;
  for my $move (@moves) {
    my @items = map { { type => $_, quantity => int($move->{items}{$_}) } } grep { $move->{items}{$_} } keys %{$move->{items}};
    if (@items) {
      my $item_text = join(", ", map { "$_->{quantity} $_->{type}" } @items);
      emit(($noaction ? "Would send" : "Sending")." $item_text to $planets->{$move->{target_id}} on $move->{ship}{name}",
           $planets->{$move->{source_id}});
      my $result = eval {
        $client->trade_push($move->{trade_id}, $move->{target_id}, \@items, { ship_id => $move->{ship}{id} }) unless $noaction;
      };
    } else {
      emit("Nothing to send to $planets->{$move->{target_id}} on $move->{ship}{name}",
           $planets->{$move->{source_id}});
    }
  }
}

sub emit {
  my $message = shift;
  my $name = shift;
  print Client::format_time(time())." $name: $message\n";
}

sub emit_json {
  return unless $debug;
  my $message = shift;
  my $hash = shift;
  print Client::format_time(time())." $message:\n";
  print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash);
}
