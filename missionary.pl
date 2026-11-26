#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
BEGIN {
  @INC = (@INC, $FindBin::RealBin, "$FindBin::RealBin/local/lib/perl5");
}

use Carp;
use Client;
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;
use JSON::XS ();
use List::Util qw(first max min sum);

autoflush STDOUT 1;
autoflush STDERR 1;

our $config_name = "config.json";
our @body_names;
our $debug    = 0;
our $noaction = 0;
our $quiet    = 0;
our $help     = 0;

our $transmute_cap = 1;
our $essentia_floor_override;
our $copies_goal = 9;
our $copies_keep = 6;
our $list_at     = 20;
our $missions_dir = "missions";
our $lookback_days = 30;

our $client;
our $empire_name;
our $essentia_floor = 20;

our %buildings_for;
our %mc_for;
our %trade_for;
our %transporter_for;
our %ports_for;
our %yards_for;
our %body_coords;
our $sst_body_id;

sub usage {
  print <<"END";
Usage: $0 [--body Name] [options]
  --body   / -b    Colony name (repeatable; default all colonies)
  --config         Client config file (default config.json)
  --noaction / -n  Once: simulate mutations, reads still happen.
                   Twice: fully offline, no RPC at all, report from disk.
  --debug   / -d   Print debug information (repeatable for more)
  --quiet          Suppress routine output; errors still print
  --transmute      Max 1:1 transporter transmutations per run (default 1)
  --essentia-floor Never transmute below this essentia (default auto)
  --goal           LCOT plan copies to accumulate per letter (default 9)
  --keep           LCOT copies retained before selling surplus (default 6)
  --list-at        SST ask price per surplus plan copy (default 20)
  --help           Show this help
END
}

sub emit {
  return if $quiet;
  my $message = shift;
  my $prefix  = shift // $empire_name // "missionary";
  print Client::format_time(time()) . " missionary: $prefix: $message\n";
}

sub emit_debug {
  return unless $debug;
  my $message = shift;
  my $hash    = shift;
  print Client::format_time(time()) . " $message:\n";
  if (defined $hash) {
    print JSON::XS->new->allow_nonref->canonical->pretty->encode($hash), "\n";
  }
}

sub parse_args {
  GetOptions(
    "config=s"          => \$config_name,
    "body|b=s"          => \@body_names,
    "debug+"            => \$debug,
    "noaction|n+"       => \$noaction,
    "quiet"             => \$quiet,
    "help"              => \$help,
    "transmute=i"       => \$transmute_cap,
    "essentia-floor=i"  => \$essentia_floor_override,
    "goal=i"            => \$copies_goal,
    "keep=i"            => \$copies_keep,
    "list-at=i"         => \$list_at,
  ) or die "Try '$0 --help' for usage.\n";
  usage() and exit 0 if $help;
  return;
}

sub sanitize_title {
  my $title = shift // "";
  $title =~ s/[^A-Za-z0-9\-.]/_/g;
  return $title;
}

sub decommify {
  my $number = shift;
  $number =~ s/,//g;
  return $number + 0;
}

sub ship_type_from_display {
  my $display = shift // "";
  my $type = lc($display);
  $type =~ s/\s+/_/g;
  return $type;
}

sub lcot_letter {
  my $class = shift // "";
  return uc($1) if $class =~ /\(([A-I])\)\s*\z/;
  return uc($1) if $class =~ /^LCOT([a-i])\z/i;
  return;
}

sub parse_items {
  my $lines = shift;
  my $items = {
    essentia        => 0,
    happiness       => 0,
    resources       => {},
    glyphs          => {},
    ships           => [],
    fleet_movement  => [],
    plans           => [],
  };
  my %moved;
  for my $line (@{$lines || []}) {
    next unless defined $line;
    (my $work = $line) =~ s/^\s+//;
    $work =~ s/\s+$//;
    next unless length $work;
    my ($count, $rest) = $work =~ /^([\d,]+)\s+(.+)$/ or next;
    $count = decommify($count);

    if ($rest =~ /^essentia\.$/) {
      $items->{essentia} += $count;
    }
    elsif ($rest =~ /^happiness\.$/) {
      $items->{happiness} += $count;
    }
    elsif ($rest =~ /^([a-z_]+) glyphs?$/) {
      $items->{glyphs}{$1} += $count;
    }
    elsif ($rest =~ /^(.+?) \(speed >= ([\d,]+), stealth >= ([\d,]+), hold size >= ([\d,]+), combat >= ([\d,]+), berth >= (\d+)\)$/) {
      push @{$items->{ships}}, {
        type        => ship_type_from_display($1),
        quantity    => $count,
        speed       => decommify($2),
        stealth     => decommify($3),
        hold_size   => decommify($4),
        combat      => decommify($5),
        berth_level => $6 + 0,
      };
    }
    elsif ($rest =~ /^(.+?) \(speed: ([\d,]+), stealth: ([\d,]+), hold size: ([\d,]+), combat: ([\d,]+), berth: (\d+)\)$/) {
      push @{$items->{ships}}, {
        type        => ship_type_from_display($1),
        quantity    => $count,
        speed       => decommify($2),
        stealth     => decommify($3),
        hold_size   => decommify($4),
        combat      => decommify($5),
        berth_level => $6 + 0,
      };
    }
    elsif ($rest =~ /^Send (.+?) to (.+?) \((-?\d+),(-?\d+)\)\.$/) {
      my $movement = {
        ship_type   => ship_type_from_display($1),
        target_name => $2,
        x           => $3 + 0,
        y           => $4 + 0,
      };
      my $key = "$movement->{ship_type}\@$movement->{x},$movement->{y}";
      next if $moved{$key}++;
      push @{$items->{fleet_movement}}, $movement;
    }
    elsif ($rest =~ /^(.+?) \(>= (\d+)(?:\+(\d+))?\) plans?$/) {
      push @{$items->{plans}}, {
        class_name => $1,
        level      => $2 + 0,
        extra      => ($3 // 0) + 0,
        quantity   => $count,
      };
    }
    elsif ($rest =~ /^(.+?) level (\d+)(?:\+(\d+))? plans?$/) {
      push @{$items->{plans}}, {
        class_name => $1,
        level      => $2 + 0,
        extra      => ($3 // 0) + 0,
        quantity   => $count,
      };
    }
    elsif ($rest =~ /^([a-z_]+)$/) {
      $items->{resources}{$1} += $count;
    }
  }
  return $items;
}

sub read_json_file {
  my $path = shift;
  return unless -f $path;
  open(my $fh, '<', $path) or return;
  local $/;
  my $blob = <$fh>;
  close $fh;
  return unless defined $blob && length $blob;
  return eval { JSON::XS->new->decode($blob) };
}

sub write_json_file {
  my ($path, $data) = @_;
  my ($vol, $dir, $file) = File::Spec->splitpath($path);
  make_path($vol ? File::Spec->catpath($vol, $dir, '') : $dir);
  open(my $fh, '>', $path) or die "Can't write $path: $!\n";
  print {$fh} JSON::XS->new->allow_nonref->canonical->pretty->encode($data);
  close $fh;
}

sub mission_payload_keys { qw(id name description objectives rewards max_university_level date_posted) }

sub record_path {
  my ($dir, $mission) = @_;
  return File::Spec->catfile($dir, sanitize_title($mission->{name}), "$mission->{id}.json");
}

sub now_stamp { Client::format_time(time()) }

sub record_instance {
  my ($dir, $mission, $body_id, $building_id) = @_;
  my $path = record_path($dir, $mission);
  my $old  = read_json_file($path) || {};
  my $now  = now_stamp();
  my %payload;
  $payload{$_} = $mission->{$_} for mission_payload_keys();
  my $seen = $old->{seen_on} || {};
  $seen->{$body_id}{$building_id} = $now;
  my %record = (%$old, %payload);
  $record{first_seen}       = $old->{first_seen} || $now;
  $record{first_seen_epoch} = $old->{first_seen_epoch} || time();
  $record{last_seen}        = $now;
  $record{seen_on}          = $seen;
  my $prev_status = $old->{status} || 'active';
  if ($prev_status =~ /^(?:completed|skipped)\z/) {
    $record{status} = $prev_status;
  }
  else {
    $record{status}           = 'active';
    $record{status_evidence}  = 'revend' if $prev_status eq 'no_longer_listed';
  }
  $record{actions}          = $old->{actions} || [];
  write_json_file($path, \%record);
  return \%record;
}

sub all_records {
  my $dir = shift;
  my @records;
  my $title_dir;
  return @records unless -d $dir;
  opendir(my $dh, $dir) or return @records;
  while (my $title = readdir($dh)) {
    next if $title =~ /^\./;
    $title_dir = File::Spec->catfile($dir, $title);
    next unless -d $title_dir;
    opendir(my $th, $title_dir) or next;
    while (my $file = readdir($th)) {
      next unless $file =~ /\.json\z/;
      my $rec = read_json_file(File::Spec->catfile($title_dir, $file));
      push @records, $rec if $rec && $rec->{id};
    }
    closedir $th;
  }
  closedir $dh;
  return @records;
}

sub infer_status_hint {
  my ($record, $records, $now_epoch) = @_;
  my $age = $now_epoch - ($record->{first_seen_epoch} || $now_epoch);
  return 'likely_72h_expiry' if $record->{first_seen_epoch} && $age > 72 * 3600;
  for my $rec (@{$records || []}) {
    next unless $rec->{name} eq $record->{name};
    next unless ($rec->{status} || '') eq 'completed';
    return 'title_completed_by_us_recently';
  }
  return 'likely_sniped';
}

sub retire_missing_instances {
  my ($records, $fresh_ids_by_building, $now_epoch) = @_;
  my @retired;
  for my $record (@$records) {
    next unless ($record->{status} || 'active') eq 'active';
    my $seen = $record->{seen_on} || {};
    my @buildings = map { keys %$_ } values %$seen;
    next unless @buildings;
    my ($evidence, $missing) = (0, 0);
    for my $building_id (@buildings) {
      my $fresh = $fresh_ids_by_building->{$building_id};
      next unless $fresh;
      $evidence++;
      $missing++ unless grep { $_ == $record->{id} } @$fresh;
    }
    next unless $evidence && $missing == $evidence;
    $record->{status}          = 'no_longer_listed';
    $record->{status_at}       = now_stamp();
    $record->{status_evidence} = "list_diff:all_vending_buildings";
    $record->{status_hint}     = infer_status_hint($record, $records, $now_epoch);
    push @retired, $record;
  }
  return @retired;
}

sub union_needed {
  my @parsed = @_;
  my $needed = {
    essentia  => 0,
    happiness => 0,
    resources => {},
    glyphs    => {},
    ships     => [],
    plans     => [],
  };
  for my $items (@parsed) {
    next unless $items;
    $needed->{essentia}  = max($needed->{essentia},  $items->{essentia}  || 0);
    $needed->{happiness} = max($needed->{happiness}, $items->{happiness} || 0);
    $needed->{resources}{$_} += $items->{resources}{$_} for keys %{$items->{resources} || {}};
    $needed->{glyphs}{$_}    += $items->{glyphs}{$_}    for keys %{$items->{glyphs}    || {}};
    push @{$needed->{ships}}, @{$items->{ships} || []};
    push @{$needed->{plans}}, @{$items->{plans} || []};
  }
  return $needed;
}

sub ship_meets_spec {
  my ($ship, $spec) = @_;
  return 0 unless ($ship->{type} || '') eq ($spec->{type} || '');
  return 0 unless ($ship->{speed}       || 0) >= ($spec->{speed}       || 0);
  return 0 unless ($ship->{stealth}     || 0) >= ($spec->{stealth}     || 0);
  return 0 unless ($ship->{hold_size}   || 0) >= ($spec->{hold_size}   || 0);
  return 0 unless ($ship->{combat}      || 0) >= ($spec->{combat}      || 0);
  return 0 unless ($ship->{berth_level} || 0) >= ($spec->{berth_level} || 0);
  return 1;
}

sub plan_meets_spec {
  my ($plan, $spec) = @_;
  return 0 unless ($plan->{class_name} || '') eq ($spec->{class_name} || '');
  return 0 unless ($plan->{level} || 0) >= ($spec->{level} || 0);
  return 0 unless ($plan->{extra} || 0) >= ($spec->{extra} || 0);
  return 1;
}

sub classify_rewards {
  my ($rewards, $needed) = @_;
  for my $plan (@{$rewards->{plans} || []}) {
    my $letter = lcot_letter($plan->{class_name});
    return (lcot => $letter, "LCOT plan $letter") if $letter;
  }
  return (useful => 'happiness') if $needed->{happiness} && $rewards->{happiness};
  return (useful => 'essentia')  if $needed->{essentia}  && $rewards->{essentia};
  for my $resource (keys %{$rewards->{resources} || {}}) {
    return (useful => "resource $resource") if $needed->{resources}{$resource};
  }
  for my $glyph (keys %{$rewards->{glyphs} || {}}) {
    return (useful => "glyph $glyph") if $needed->{glyphs}{$glyph};
  }
  for my $ship (@{$rewards->{ships} || []}) {
    for my $spec (@{$needed->{ships} || []}) {
      return (useful => "ship $ship->{type}") if ship_meets_spec($ship, $spec);
    }
  }
  for my $plan (@{$rewards->{plans} || []}) {
    for my $spec (@{$needed->{plans} || []}) {
      return (useful => "plan $plan->{class_name}") if plan_meets_spec($plan, $spec);
    }
  }
  return (useless => 'nothing in the needed set');
}

sub should_skip {
  my ($class, $rewards, $objectives) = @_;
  return 0 unless $class eq 'useless';
  my $valuable = @{$rewards->{plans} || []} || @{$rewards->{ships} || []}
              || %{$rewards->{glyphs} || {}} || $rewards->{essentia} || $rewards->{happiness};
  return 0 if $valuable;
  my $rew_res = sum(values %{$rewards->{resources} || {}});
  my $obj_res = sum(values %{$objectives->{resources} || {}});
  return 1 if !$rew_res;
  return 1 if $rew_res <= $obj_res;
  return 1 if ($objectives->{essentia} || 0) > ($rewards->{essentia} || 0);
  return 0;
}

sub lcot_holdings_from_plans {
  my ($plan_lists) = @_;
  my %holdings;
  for my $key (keys %{$plan_lists || {}}) {
    my $entry  = $plan_lists->{$key};
    my $plans  = ref($entry) eq 'ARRAY' ? $entry : ($entry->{plans} || []);
    for my $plan (@$plans) {
      next unless ($plan->{plan_type} || '') =~ /^LCOT([a-i])\z/i;
      $holdings{uc($1)} += ($plan->{quantity} || 0);
    }
  }
  return \%holdings;
}

sub add_listed_holdings {
  my ($holdings, $offer_items) = @_;
  for my $plan (@{$offer_items || []}) {
    my $letter = lcot_letter($plan->{class_name});
    next unless $letter;
    $holdings->{$letter} += ($plan->{quantity} || 0);
  }
  return $holdings;
}

sub sellable_copies {
  my ($holdings, $listed, $keep) = @_;
  my %sellable;
  for my $letter (keys %$holdings) {
    my $copies = $holdings->{$letter} - ($listed->{$letter} || 0);
    my $excess = $copies - $keep;
    $sellable{$letter} = $excess if $excess > 0;
  }
  return \%sellable;
}

sub outstanding_letters {
  my ($holdings, $goal) = @_;
  return grep { ($holdings->{$_} || 0) < $goal } 'A' .. 'I';
}

sub compute_essentia_floor {
  my ($needed, $base) = @_;
  return max($base || 20, ($needed->{essentia} || 0) + 10);
}

sub spec_key {
  my $spec = shift;
  return sprintf("%s#%05d#%05d#%05d#%05d",
                 $spec->{type},
                 $spec->{combat}    || 0,
                 $spec->{speed}     || 0,
                 $spec->{stealth}   || 0,
                 $spec->{hold_size} || 0);
}

sub merge_specs {
  my $specs = shift;
  my %merged;
  for my $spec (@{$specs || []}) {
    my $key = spec_key($spec);
    if ($merged{$key}) {
      $merged{$key}{quantity} += $spec->{quantity} || 1;
    }
    else {
      my %copy = %$spec;
      $copy{quantity} ||= 1;
      $merged{$key} = \%copy;
    }
  }
  return [values %merged];
}

sub stat_order_key {
  my $ship = shift;
  return sprintf("%07d%06d%05d%04d%02d",
                 $ship->{hold_size}   || 0,
                 $ship->{speed}       || 0,
                 $ship->{stealth}     || 0,
                 $ship->{combat}      || 0,
                 $ship->{berth_level} || 0);
}

sub ship_name_order {
  return lc($a->{name} // '') cmp lc($b->{name} // '')
      || ($a->{id} || 0) <=> ($b->{id} || 0);
}

sub ship_stat_order {
  return stat_order_key($a) cmp stat_order_key($b)
      || ($a->{id} || 0) <=> ($b->{id} || 0);
}

sub mirror_consume {
  my ($ships, $specs, $order) = @_;
  my $merged = merge_specs($specs);
  my $total_needed = sum(map { $_->{quantity} } @$merged);
  my %by_key;
  my $pass = 1;
  my @messages;
  for my $spec (@$merged) {
    my @candidates = grep {
      ship_meets_spec($_, $spec) && (($_->{task} || 'Docked') eq 'Docked')
    } @$ships;
    my $cmp = $order eq 'stats' ? \&ship_stat_order : \&ship_name_order;
    @candidates = sort $cmp @candidates;
    splice(@candidates, $total_needed) if @candidates > $total_needed;
    if (@candidates < $spec->{quantity}) {
      $pass = 0;
      push @messages, sprintf("Need %d of %s (speed >= %s, stealth >= %s, hold size >= %s, combat >= %s, berth >= %s)",
                              $spec->{quantity}, $spec->{type},
                              $spec->{speed} || 0, $spec->{stealth} || 0,
                              $spec->{hold_size} || 0, $spec->{combat} || 0,
                              $spec->{berth_level} || 0);
    }
    $by_key{spec_key($spec)} = {
      spec        => $spec,
      candidates  => \@candidates,
      total_found => scalar @candidates,
    };
  }
  my @id_list;
  if ($pass) {
    my %pending = %by_key;
    while (%pending) {
      my ($key) = sort {
        ($pending{$a}{total_found} - $pending{$a}{spec}{quantity})
        <=>
        ($pending{$b}{total_found} - $pending{$b}{spec}{quantity})
        || $a cmp $b
      } keys %pending;
      my $entry = $pending{$key};
      my @taken;
      for my $ship (@{$entry->{candidates}}) {
        last if scalar @taken >= $entry->{spec}{quantity};
        next if grep { $_ == ($ship->{id} || 0) } @id_list;
        push @taken, $ship->{id};
      }
      push @id_list, @taken;
      delete $pending{$key};
      for my $lkey (keys %pending) {
        $pending{$lkey}{candidates} = [ grep {
          my $id = $_->{id} || 0;
          !grep { $_ == $id } @taken;
        } @{$pending{$lkey}{candidates}} ];
        $pending{$lkey}{total_found} = scalar @{$pending{$lkey}{candidates}};
      }
    }
    if ($total_needed > scalar @id_list) {
      $pass = 0;
      push @messages, "Total qualifying ships, came up short.";
    }
  }
  return { pass => $pass, messages => \@messages, ids => \@id_list };
}

sub scheme_name {
  my ($prefix, $ship) = @_;
  return sprintf("%s h%07d s%06d t%05d c%04d b%02d",
                 $prefix,
                 $ship->{hold_size}   || 0,
                 $ship->{speed}       || 0,
                 $ship->{stealth}     || 0,
                 $ship->{combat}      || 0,
                 $ship->{berth_level} || 0);
}

sub is_scheme_name {
  my $name = shift // '';
  return $name =~ /\A(?:zz|aa)m h\d{7} s\d{6} t\d{5} c\d{4} b\d{2}\z/ ? 1 : 0;
}

sub simulate_rename_plan {
  my ($ships, $specs, $mode) = @_;
  my $prefix = $mode eq 'keep' ? 'zzm' : 'aam';
  my $desired = mirror_consume($ships, $specs, 'stats');
  return { feasible => 0, renames => {} } unless $desired->{pass};
  my @desired_ids = @{$desired->{ids}};
  my %renames;
  my @working = map { { %{$_} } } @$ships;
  my $guard = scalar(@working) + 1;
  while ($guard-- > 0) {
    for my $ship (@working) {
      $ship->{name} = $renames{$ship->{id}} if exists $renames{$ship->{id}};
    }
    my $would = mirror_consume(\@working, $specs, 'name');
    my @consumed_undesired = grep { my $id = $_; !grep { $_ == $id } @desired_ids } @{$would->{ids}};
    my @desired_missed     = grep { my $id = $_; !grep { $_ == $id } @{$would->{ids}} } @desired_ids;
    my @primary   = $mode eq 'keep' ? @consumed_undesired : @desired_missed;
    my @secondary = $mode eq 'keep' ? @desired_missed     : @consumed_undesired;
    return { feasible => 1, renames => \%renames, ids => $would->{ids} }
      unless @primary || @secondary;
    my $progress = rename_stragglers(\@primary, \%renames, \@working, $prefix);
    $progress = rename_stragglers(\@secondary, \%renames, \@working, $prefix) unless $progress;
    last unless $progress;
  }
  return { feasible => 0, renames => \%renames };
}

sub rename_stragglers {
  my ($ids, $renames, $working, $prefix) = @_;
  my $progress = 0;
  for my $id (@$ids) {
    next if exists $renames->{$id};
    my ($ship) = grep { ($_->{id} || 0) == $id } @$working;
    next unless $ship;
    my $new = scheme_name($prefix, $ship);
    next if ($ship->{name} // '') eq $new;
    $renames->{$id} = $new;
    $progress++;
  }
  return $progress;
}

sub choose_rename_plan {
  my ($ships, $specs) = @_;
  my $would = mirror_consume($ships, $specs, 'name');
  return { needed => 0, mode => '', renames => {} } unless $would->{pass};
  my $desired = mirror_consume($ships, $specs, 'stats');
  return { needed => 0, mode => '', renames => {} } unless $desired->{pass};
  my %want = map { $_ => 1 } @{$desired->{ids}};
  return { needed => 0, mode => '', renames => {} } unless grep { !$want{$_} } @{$would->{ids}};
  my $keep    = simulate_rename_plan($ships, $specs, 'keep');
  my $consume = simulate_rename_plan($ships, $specs, 'consume');
  my $keep_n    = $keep->{feasible}    ? scalar keys %{$keep->{renames}}    : undef;
  my $consume_n = $consume->{feasible} ? scalar keys %{$consume->{renames}} : undef;
  return { needed => 0, mode => '', renames => {}, blocked => 1 }
    unless defined $keep_n || defined $consume_n;
  if (defined $keep_n && (!defined $consume_n || $keep_n <= $consume_n)) {
    return { needed => $keep_n, mode => 'keep', renames => $keep->{renames}, plan => $keep };
  }
  return { needed => $consume_n, mode => 'consume', renames => $consume->{renames}, plan => $consume };
}

sub run {
  parse_args();
  return offline_report() if $noaction >= 2;
  online_run();
  return;
}

sub online_run {
  emit("online flow not yet implemented; use --noaction --noaction for the offline report");
  return;
}

sub offline_report {
  my @records = all_records($missions_dir);
  return emit("offline: no mission records under $missions_dir yet") unless @records;
  my %by_status;
  push @{$by_status{$_->{status} || 'active'}}, $_ for @records;
  emit(sprintf("offline report: %d records (%s)",
              scalar(@records),
              join(", ", map { "$_: " . scalar @{$by_status{$_}} } sort keys %by_status)));
  for my $rec (@records) {
    my $letter = $rec->{lcot_letter} ? " plan $rec->{lcot_letter}" : "";
    emit(sprintf("  [%s] %s (id %s)%s", $rec->{status} || 'active', $rec->{name}, $rec->{id}, $letter));
    for my $action (@{$rec->{actions} || []}) {
      my $eta = $action->{eta} ? " eta $action->{eta}" : "";
      emit(sprintf("    %s %s%s%s", $action->{time} || '?', $action->{action},
                   defined $action->{result} ? " -> $action->{result}" : "", $eta))
        if $action->{action} =~ /^(?:send|complete|skip)\b/;
    }
  }
  return 1;
}

run() unless caller;

1;
