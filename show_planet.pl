#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::PP;

my $config_name = "config.json";
my $body_name;

GetOptions(
  "config=s" => \$config_name,
  "body=s"   => \$body_name,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $result = $client->body_buildings($body_id);

my @foods = (
  "Planetary Command Center",  # 11
  "Malcud Fungus Farm",        # 21
  "Malcud Burger Packer",      # 3
  "Algae Cropper",             # 24
  "Algae Syrup Bottler",       # 3
  "Amalgus Bean Plantation",   # 25
  "Amalgus Bean Soup Cannery", # 3
  "Potato Patch",              # 25
  "Potato Pancake Factory",    # 3
  "Denton Root Patch",         # 26
  "Denton Root Chip Frier",    # 3
  "Corn Plantation",           # 30
  "Corn Meal Grinder",         # 3
  "Wheat Farm",                # 30
  "Bread Bakery",              # 3
  "Beeldeban Herder",          # 36
  "Beeldeban Protein Shake Factory", # 3
  "Apple Orchard",             # 46
  "Apple Cider Bottler",       # 3
  "Lapis Orchard",             # 47
  "Lapis Pie Bakery",          # 3
  "Dairy Farm",                # 66
  "Cheese Maker",              # 3
  "Algae Pond",
  "Malcud Field",
  "Beeldeban Nest",
  "Lapis Forest",
  "Denton Brambles",
  "Amalgus Meadow",
);

my $build_end;
my %buildings;
for my $id (keys %{$result->{buildings}}) {
  my $building = $result->{buildings}{$id};
  if (grep($_ eq $building->{name}, @foods)) {
    # warn "Getting stats for building $building->{name}\n";
    $buildings{$building->{name}}{$building->{level}}{$id} = $client->building_stats_for_level($building->{url}, $id, $building->{level});
  } else {
    $buildings{$building->{name}}{$building->{level}}{$id} = 1;
  }
  if ($building->{pending_build}) {
    my $time = Client::parse_time($building->{pending_build}{end});
    $build_end = $time if $build_end < $time;
  }
}

my $body = $result->{status}{body};
print "$body->{star_name} $body->{orbit}: $body->{name}\n";
print "Invalid after ".format_time($result->{_invalid})."\n";
print "Builds complete at ".format_time($build_end)."\n" if $build_end;
print "\n";
printf ("Food  : %8d / %8d, %6d/hour => %5s at %s\n", resource_info($result->{status}, "food"));
printf ("Ore   : %8d / %8d, %6d/hour => %5s at %s\n", resource_info($result->{status}, "ore"));
printf ("Water : %8d / %8d, %6d/hour => %5s at %s\n", resource_info($result->{status}, "water"));
printf ("Energy: %8d / %8d, %6d/hour => %5s at %s\n", resource_info($result->{status}, "energy"));
printf ("Waste : %8d / %8d, %6d/hour => %5s at %s\n", resource_info($result->{status}, "waste"));
print "\n";
print "Buildings ($body->{building_count} of $body->{size}, with $body->{plots_available} remaining):";
# print "\nStorage:\n";
# list_buildings_for_production(\%buildings, [ qw(food_capacity ore_capacity water_capacity energy_capacity) ]);
# print "\nResources:\n";
# list_buildings_for_production(\%buildings, [ qw(ore_hour water_hour energy_hour) ]);
print "\nFood:\n";

for my $type (@foods) {
  next unless exists($buildings{$type});
  my $rate = 0;
  for my $x (values(%{$buildings{$type}})) {
    for my $y (values(%{$x})) {
      $rate += $y->{building}{food_hour};
    }
  }
  printf("  %-32s%8d/hour ", $type, $rate);
  
  for my $level (sort keys(%{$buildings{$type}})) {
    print " ".scalar(keys(%{$buildings{$type}{$level}}))."x$level";
  }
  print "\n";
}

# print "\nStorage:\n";

print "\nOther:\n";
for my $type (sort keys(%buildings)) {
  next if grep($_ eq $type, @foods);
  printf("  %-32s", $type);
  for my $level (sort keys(%{$buildings{$type}})) {
    print " ".scalar(keys(%{$buildings{$type}{$level}}))."x$level";
  }
  print "\n";
}

sub list_buildings_for_production {
  my $buildings = shift;
  my $products = shift;
  my $order = shift;

  $order ||= [ sort keys %$buildings ];
  my $suffix = "";
  $suffix = "/hour" if $products->[0] =~ /_hour/;

  for my $type (@$order) {
    next unless exists($buildings->{$type});
    my %rate;
    for my $x (values(%{$buildings->{$type}})) {
      for my $y (values(%{$x})) {
        for my $product (@$products) {
          $rate{$product} += $y->{building}{$product};
        }
      }
    }
    my $rates = join("", map { /^([^_]+)/; $rate{$_} > 0 ? sprintf("%8d %-5s%s", $rate{$_}, $1, $suffix) : "" } @$products);
    next unless $rates;
    
    printf("  %-32s%-32s", $type, $rates);
  
    for my $level (sort keys(%{$buildings{$type}})) {
      print " ".scalar(keys(%{$buildings{$type}{$level}}))."x$level";
    }
    print "\n";
  }
}

sub resource_info {
  my $status = shift;
  my $resource = shift;
  my $body = $status->{body};
  my @list;

  push(@list, $body->{"${resource}_stored"});
  push(@list, $body->{"${resource}_capacity"});
  push(@list, $body->{"${resource}_hour"});
  if ($list[2] == 0) {
    push(@list, "stable");
    push(@list, format_time($status->{_time}));
  } elsif ($list[2] > 0) {
    push(@list, "full");
    push(@list, format_time(($list[1] - $list[0]) / $list[2] * 3600 + $status->{_time}));
  } else {
    push(@list, "empty");
    push(@list, format_time((0 - $list[0]) / $list[2] * 3600 + $status->{_time}));
  }
  shift(@list);
  my $current = $body->{"${resource}_stored"} + $body->{"${resource}_hour"} * (time() - $status->{_time}) / 3600;
  $current = 0 if $current < 0;
  $current = $body->{"${resource}_capacity"} if $current > $body->{"${resource}_capacity"};
  unshift(@list, $current);
  return @list;
}

sub format_time {
  my $time = shift;

  my @elems = reverse((localtime($time))[0..5]);
  $elems[0] += 1900;
  $elems[1]++;
  sprintf("%4d-%02d-%02d %02d:%02d:%02d", @elems);
}



# print encode_json($result)."\n";
