#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
BEGIN {
  @INC = (@INC, $FindBin::RealBin, "$FindBin::RealBin/local/lib/perl5");
}

use Carp;
use Client;
use Exception::Class;
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
our %body_name;
our $current_body_name;

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
  my $prefix  = shift // '';
  my @parts = ("missionary");
  push @parts, $current_body_name if defined($current_body_name) && $current_body_name ne '';
  push @parts, $prefix if $prefix ne '';
  print Client::format_time(time()) . " " . join(": ", @parts) . ": $message\n";
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
  $record{last_seen_epoch}  = time();
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
  return (useful => undef, 'happiness') if $needed->{happiness} && $rewards->{happiness};
  return (useful => undef, 'essentia')  if $needed->{essentia}  && $rewards->{essentia};
  for my $resource (keys %{$rewards->{resources} || {}}) {
    return (useful => undef, "resource $resource") if $needed->{resources}{$resource};
  }
  for my $glyph (keys %{$rewards->{glyphs} || {}}) {
    return (useful => undef, "glyph $glyph") if $needed->{glyphs}{$glyph};
  }
  for my $ship (@{$rewards->{ships} || []}) {
    for my $spec (@{$needed->{ships} || []}) {
      return (useful => undef, "ship $ship->{type}") if ship_meets_spec($ship, $spec);
    }
  }
  for my $plan (@{$rewards->{plans} || []}) {
    for my $spec (@{$needed->{plans} || []}) {
      return (useful => undef, "plan $plan->{class_name}") if plan_meets_spec($plan, $spec);
    }
  }
  return (useless => undef, 'nothing in the needed set');
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

sub online_run {
  my $status = eval { connect_client() };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit($e->error, "rpc error");
    return;
  }
  die $@ if $@;
  my @body_ids = resolve_bodies($status);
  return unless @body_ids;

  my @mcs = locate_mission_commands(\@body_ids);
  emit("no Mission Command on any body; nothing to do"), return unless @mcs;

  my ($vended, $fresh_by_building) = vend_and_record(\@mcs);
  retire_from_lists($vended, $fresh_by_building);

  my %plan_lists = fetch_plan_lists(\@body_ids);
  my $holdings   = lcot_holdings_from_plans(\%plan_lists);
  my ($listed, $trades_active) = sst_listed_copies();
  add_listed_holdings($holdings, $listed);
  my @outstanding = outstanding_letters($holdings, $copies_goal);
  emit_debug("LCOT holdings", $holdings);

  my $needed = needed_set_from_vended($vended);
  $essentia_floor = compute_essentia_floor($needed, $essentia_floor_override || 20);

  my @work = classify_vended($vended, $needed, \@outstanding);
  skip_useless(@work);
  my @todo = grep { ($_->{class} eq 'lcot' || $_->{class} eq 'useful')
                   && ($_->{rec}{status} || 'active') eq 'active' } @work;
  @todo = sort { $a->{rec}{priority} <=> $b->{rec}{priority} } @todo;
  fulfill_missions(\@todo, \%plan_lists);

  sst_sales($holdings, $listed, $trades_active, \%plan_lists) if $sst_body_id;
  summary($holdings);
  return;
}

sub connect_client {
  $client = Client->new(config => $config_name);
  my $status = $client->empire_status;
  $empire_name = $status->{name};
  return $status;
}

sub resolve_bodies {
  my $status = shift;
  my $planets = $status->{planets} || {};
  my @ids;
  if (@body_names) {
    for my $name (@body_names) {
      my $id = eval { $client->match_planet($name) };
      if (my $e = Exception::Class->caught('LacunaRPCException')) {
        emit("$name: " . $e->error, "body");
        next;
      }
      die $@ if $@;
      push @ids, $id;
    }
  }
  else {
    @ids = sort keys %$planets;
  }
  emit("no usable bodies"), return () unless @ids;
  %body_name = %$planets;
  $current_body_name = undef;
  my %id_by_name = reverse %$planets;
  for my $colony (@{$status->{bodies}{colonies} || []}) {
    next unless defined($colony->{x}) && defined($colony->{y});
    next unless ($colony->{empire_id} || '') eq ($status->{id} || '');
    my $id = $id_by_name{$colony->{name}};
    $body_coords{$id} = [$colony->{x}, $colony->{y}] if $id;
  }
  return @ids;
}

sub locate_mission_commands {
  my $body_ids = shift;
  my @mcs;
  for my $body_id (@$body_ids) {
    $current_body_name = $body_name{$body_id} || $body_id;
    my $buildings = eval { $client->body_buildings($body_id) };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("$body_id: " . $e->error, "buildings");
      next;
    }
    die $@ if $@;
    next unless $buildings;
    my @mc = $client->find_building($body_id, "Mission Command");
    unless (@mc) {
      emit("body $body_id has no Mission Command");
      next;
    }
    my ($trade) = $client->find_building($body_id, "Trade Ministry");
    my ($transporter) = $client->find_building($body_id, "Subspace Transporter");
    my @ports = $client->find_building($body_id, "Space Port");
    my @yards = $client->find_building($body_id, "Shipyard");
    push @mcs, {
      body_id => $body_id, building_id => $mc[0]{id}, level => $mc[0]{level},
    };
    $trade_for{$body_id}       = $trade->{id}       if $trade;
    $transporter_for{$body_id} = $transporter->{id} if $transporter;
    $ports_for{$body_id}       = [ map { $_->{level} } @ports ];
    $yards_for{$body_id}       = [ map { $_->{id} } @yards ];
    $sst_body_id = $body_id if $transporter;
  }
  return @mcs;
}

sub vend_and_record {
  my $mcs = shift;
  my $vended;
  my %fresh_by_building;
  for my $mc (@$mcs) {
    my $list = eval { $client->mission_list($mc->{building_id}) };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("mission list $mc->{building_id}: " . $e->error, "vend");
      next;
    }
    die $@ if $@;
    next unless $list && $list->{missions};
    my @missions = @{$list->{missions}};
    $fresh_by_building{$mc->{building_id}} = [ map { $_->{id} } @missions ];
    for my $mission (@missions) {
      my $entry = $vended->{$mission->{id}} ||= { mission => $mission, on => [] };
      push @{$entry->{on}}, { body_id => $mc->{body_id}, building_id => $mc->{building_id} };
      $entry->{rec} = record_instance($missions_dir, $mission, $mc->{body_id}, $mc->{building_id});
    }
  }
  for my $id (sort keys %$vended) {
    my $rec = $vended->{$id}{rec};
    my @planets = map { $body_name{$_->{body_id}} || $_->{body_id} } @{$vended->{$id}{on}};
    $current_body_name = $planets[0];
    write_json_file(record_path($missions_dir, $rec), $rec);
    emit("vended: $rec->{name} (id $id) [" . ($rec->{status} || 'active') . "] on "
         . join(", ", @planets));
  }
  return ($vended, \%fresh_by_building);
}

sub retire_from_lists {
  my ($vended, $fresh_by_building) = @_;
  my @records = all_records($missions_dir);
  my @retired = retire_missing_instances(\@records, $fresh_by_building, time());
  $current_body_name = undef;
  for my $rec (@retired) {
    write_json_file(record_path($missions_dir, $rec), $rec);
    emit("retired from lists: $rec->{name} (id $rec->{id}) [$rec->{status_hint}]");
  }
  return;
}

sub fetch_plan_lists {
  my $body_ids = shift;
  my %plan_lists;
  for my $body_id (@$body_ids) {
    my $plans = eval { $client->body_plans($body_id) };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit_debug("plan fetch failed for $body_id: " . $e->error);
      next;
    }
    die $@ if $@;
    $plan_lists{$body_id} = $plans if $plans;
  }
  return %plan_lists;
}

sub sst_listed_copies {
  return ([], 0) unless $sst_body_id && $transporter_for{$sst_body_id};
  my $market = eval {
    $client->call(transporter => view_my_market => $transporter_for{$sst_body_id}, 1)
  };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit("view_my_market: " . $e->error, "sst");
    return ([], 0);
  }
  die $@ if $@;
  my @listed;
  my $trades = $market->{trades} || [];
  for my $trade (@$trades) {
    my $items = parse_items([$trade->{offer}]);
    push @listed, @{$items->{plans}};
  }
  return (\@listed, scalar @$trades);
}

sub needed_set_from_vended {
  my $vended = shift;
  my @lcot_parsed;
  my $cutoff = time() - $lookback_days * 86400;
  for my $entry (values %$vended) {
    my $rewards = parse_items($entry->{mission}{rewards});
    next unless grep { lcot_letter($_->{class_name}) } @{$rewards->{plans}};
    push @lcot_parsed, parse_items($entry->{mission}{objectives});
  }
  for my $rec (all_records($missions_dir)) {
    my $rewards = parse_items($rec->{rewards});
    next unless grep { lcot_letter($_->{class_name}) } @{$rewards->{plans}};
    next unless ($rec->{last_seen_epoch} || 0) >= $cutoff;
    push @lcot_parsed, parse_items($rec->{objectives});
  }
  return union_needed(@lcot_parsed);
}

sub classify_vended {
  my ($vended, $needed, $outstanding) = @_;
  my %outstanding = map { $_ => 1 } @$outstanding;
  my @work;
  for my $id (sort keys %$vended) {
    my $entry   = $vended->{$id};
    my $rec     = $entry->{rec};
    my $rewards = parse_items($entry->{mission}{rewards});
    my ($class, $detail, $reason) = classify_rewards($rewards, $needed);
    $rec->{classification}         = $class;
    $rec->{classification_reason}  = $reason;
    if ($class eq 'lcot') {
      $rec->{lcot_letter} = $detail;
      $rec->{priority}    = $outstanding{$detail} ? 0 : 1;
    }
    else {
      $rec->{priority} = 2;
    }
    $entry->{class} = $class;
    push @work, $entry;
    write_json_file(record_path($missions_dir, $rec), $rec);
  }
  return @work;
}

sub skip_useless {
  my @work = @_;
  for my $entry (@work) {
    next unless $entry->{class} eq 'useless';
    my $rec        = $entry->{rec};
    my $objectives = parse_items($entry->{mission}{objectives});
    my $rewards    = parse_items($entry->{mission}{rewards});
    next unless should_skip('useless', $rewards, $objectives);
    my $on = $entry->{on}[0];
    $current_body_name = $body_name{$on->{body_id}} || $on->{body_id};
    emit("skipping useless: $rec->{name} (id $rec->{id})");
    if ($noaction) {
      record_action($rec, { action => 'skip', result => 'simulated' });
      next;
    }
    my $ok = eval { $client->mission_skip($on->{building_id}, $rec->{id}); 1 };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("skip $rec->{id}: " . $e->error, "skip");
      record_action($rec, { action => 'skip', result => 'error: ' . $e->error });
      next;
    }
    die $@ if $@;
    $rec->{status}          = 'skipped';
    $rec->{status_at}       = now_stamp();
    $rec->{status_evidence} = 'rpc:skip_mission';
    record_action($rec, { action => 'skip', result => 'ok' });
    write_json_file(record_path($missions_dir, $rec), $rec);
  }
  return;
}

sub record_action {
  my ($rec, $action) = @_;
  $action->{time} = now_stamp();
  push @{$rec->{actions}}, $action;
  return;
}

sub body_ships {
  my $body_id = shift;
  my $result = eval { $client->port_all_ships($body_id) };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit_debug("ships fetch failed for $body_id: " . $e->error);
    return [];
  }
  die $@ if $@;
  return $result ? $result->{ships} || [] : [];
}

sub fleet_eta_from_actions {
  my ($rec, $mv) = @_;
  my $best;
  for my $action (@{$rec->{actions} || []}) {
    next unless $action->{action} eq 'send';
    next unless defined $action->{x} && defined $action->{y};
    next unless $action->{x} == $mv->{x} && $action->{y} == $mv->{y};
    next unless ($action->{ship_type} || '') eq $mv->{ship_type};
    $best = $action->{eta} if $action->{eta} && (!defined($best) || $action->{eta} > $best);
  }
  return $best;
}

sub transit_to_target {
  my ($ships, $mv) = @_;
  for my $ship (@$ships) {
    next unless ($ship->{task} || '') eq 'Travelling';
    next unless ($ship->{type} || '') eq $mv->{ship_type};
    my $to = $ship->{to} or next;
    next unless defined $to->{x} && defined $to->{y};
    return 1 if $to->{x} == $mv->{x} && $to->{y} == $mv->{y};
    return 1 if ($to->{name} || '') eq $mv->{target_name};
  }
  return 0;
}

sub nearest_body_with_docked {
  my ($ships_by_body, $mv) = @_;
  my ($best_body, $best_ship, $best_dist);
  for my $body_id (keys %$ships_by_body) {
    my $coords = $body_coords{$body_id} or next;
    for my $ship (@{$ships_by_body->{$body_id}}) {
      next unless ($ship->{task} || '') eq 'Docked';
      next unless ($ship->{type} || '') eq $mv->{ship_type};
      my $dist = ($coords->[0] - $mv->{x}) ** 2 + ($coords->[1] - $mv->{y}) ** 2;
      if (!defined($best_dist) || $dist < $best_dist) {
        $best_body = $body_id;
        $best_ship = $ship;
        $best_dist = $dist;
      }
    }
  }
  return ($best_body, $best_ship);
}

sub send_fleet_movement {
  my ($entry, $mv, $ships_by_body) = @_;
  my $rec = $entry->{rec};
  my ($from_body, $ship) = nearest_body_with_docked($ships_by_body, $mv);
  unless ($ship) {
    report_missing_ship_type($mv->{ship_type}, $entry);
    return 'missing_ship';
  }
  emit("sending $mv->{ship_type} to $mv->{target_name} ($mv->{x},$mv->{y}) from $from_body");
  if ($noaction) {
    record_action($rec, {
      action => 'send', ship_type => $mv->{ship_type},
      x => $mv->{x}, y => $mv->{y}, ship_id => $ship->{id},
      result => 'simulated', eta => time() + 3600,
    });
    return 'simulated';
  }
  my $result = eval { $client->send_ship($ship->{id}, { x => $mv->{x}, y => $mv->{y} }) };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit("send $mv->{ship_type} to $mv->{target_name}: " . $e->error, "send");
    record_action($rec, {
      action => 'send', ship_type => $mv->{ship_type}, x => $mv->{x}, y => $mv->{y},
      result => 'error: ' . $e->error,
    });
    return 'error';
  }
  die $@ if $@;
  my $eta = Client::parse_time($result->{ship}{date_arrives}) || (time() + 3600);
  record_action($rec, {
    action => 'send', ship_type => $mv->{ship_type}, x => $mv->{x}, y => $mv->{y},
    ship_id => $ship->{id}, result => 'ok', eta => $eta,
  });
  emit(sprintf("sent ship %d, arrives %s", $ship->{id}, Client::format_time($eta)));
  return 'sent';
}

sub report_missing_ship_type {
  my ($type, $entry) = @_;
  my $rec = $entry->{rec};
  my $buildable = 0;
  for my $body_id (keys %yards_for) {
    for my $yard_id (@{$yards_for{$body_id}}) {
      my $yb = eval { $client->yard_buildable($yard_id) };
      next unless $yb;
      $buildable = 1 if $yb->{buildable}{$type} && $yb->{buildable}{$type}{can};
    }
  }
  my $note = $buildable
    ? "no docked $type anywhere; add a 'shipbuild $type' queue line to build one"
    : "no docked $type anywhere and it is not buildable; it must come from another mission or the exchange";
  emit("$rec->{name}: $note", "blocker");
  record_action($rec, { action => 'blocker', note => $note });
  return;
}

sub anchor_stored {
  my $anchor_id = shift;
  return {} unless $trade_for{$anchor_id};
  my $result = eval {
    $client->call(trade => get_stored_resources => $trade_for{$anchor_id})
  };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit_debug("stored resources failed for $anchor_id: " . $e->error);
    return {};
  }
  die $@ if $@;
  return $result->{resources} || {};
}

sub haul_resource {
  my ($entry, $resource, $quantity, $anchor_id, $body_ids) = @_;
  my $rec = $entry->{rec};
  my $expiry = ($rec->{first_seen_epoch} || time()) + 72 * 3600;
  for my $body_id (@$body_ids) {
    next unless $body_id != $anchor_id;
    next unless $trade_for{$body_id};
    my $source = eval {
      $client->call(trade => get_stored_resources => $trade_for{$body_id})
    };
    next unless $source && $source->{resources};
    my $surplus = ($source->{resources}{$resource} || 0) - $quantity;
    next unless $surplus > 0;
    my $ships = eval {
      $client->call(trade => get_trade_ships => $trade_for{$body_id}, $anchor_id)
    };
    next unless $ships && @{$ships->{ships} || []};
    my ($ship) = sort { ($b->{hold_size} || 0) <=> ($a->{hold_size} || 0) } @{$ships->{ships}};
    my $load = min($quantity, $ship->{hold_size} || 0, $surplus);
    next unless $load > 0;
    emit("hauling $load $resource from $body_id to $anchor_id on ship $ship->{id}");
    if ($noaction) {
      record_action($rec, { action => 'haul', resource => $resource,
                             quantity => $load, from => $body_id, result => 'simulated' });
      return 'simulated';
    }
    my $result = eval {
      $client->trade_push($trade_for{$body_id}, $anchor_id,
                          [ { type => $resource, quantity => $load } ],
                          { ship_id => $ship->{id} });
    };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("haul $resource: " . $e->error, "haul");
      next;
    }
    die $@ if $@;
    my $eta = Client::parse_time($result->{fleet}{date_arrives});
    record_action($rec, { action => 'haul', resource => $resource, quantity => $load,
                           from => $body_id, result => 'ok', eta => $eta });
    emit("hauled; " . ($eta ? "arrives " . Client::format_time($eta) : 'arrival unknown'));
    emit("note: arrival " . ($eta ? Client::format_time($eta) : '?')
         . " vs posting expiry " . Client::format_time($expiry))
      if $eta && $eta > $expiry;
    return 'hauled';
  }
  return '';
}

sub transmute_resource {
  my ($entry, $anchor_id, $have_res, $want_res, $quantity, $essentia) = @_;
  my $rec = $entry->{rec};
  return '' unless $anchor_id == ($sst_body_id || -1) && $transporter_for{$anchor_id};
  return '' unless $transmute_cap > 0;
  return '' if $essentia - 3 < $essentia_floor;
  my $stored = anchor_stored($anchor_id);
  return '' unless ($stored->{$have_res} || 0) > $quantity;
  emit("transmuting $quantity $have_res into $want_res on $anchor_id (3 essentia)");
  if ($noaction) {
    record_action($rec, { action => 'transmute', have => $have_res, want => $want_res,
                           quantity => $quantity, result => 'simulated' });
    $transmute_cap--;
    return 'simulated';
  }
  my $ok = eval {
    $client->call(transporter => trade_one_for_one =>
                  $transporter_for{$anchor_id}, $have_res, $want_res, $quantity);
    1;
  };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit("transmute: " . $e->error, "transmute");
    record_action($rec, { action => 'transmute', have => $have_res, want => $want_res,
                          quantity => $quantity, result => 'error: ' . $e->error });
    return '';
  }
  die $@ if $@;
  record_action($rec, { action => 'transmute', have => $have_res, want => $want_res,
                        quantity => $quantity, result => 'ok' });
  $transmute_cap--;
  return 'transmuted';
}

sub port_slots_free {
  my ($anchor_id, $ships_by_body) = @_;
  my $slots = 2 * sum(@{$ports_for{$anchor_id} || []});
  my $used  = scalar @{$ships_by_body->{$anchor_id} || []};
  return $slots - $used;
}

sub transfer_ships {
  my ($entry, $specs, $anchor_id, $ships_by_body, $body_ids) = @_;
  my $rec = $entry->{rec};
  my $would = mirror_consume($ships_by_body->{$anchor_id} || [], $specs, 'name');
  return 'ok' unless $would->{pass};
  my $have = scalar @{$would->{ids}};
  my $need = sum(map { $_->{quantity} } @{merge_specs($specs)});
  return 'ok' if $have >= $need;
  my $short  = $need - $have;
  my $free   = port_slots_free($anchor_id, $ships_by_body);
  my $slots  = max(0, min($short, $free));
  my $moved = 0;
  for my $body_id (@$body_ids) {
    last if $slots <= 0;
    next unless $body_id != $anchor_id;
    my @spare = grep {
      ($_->{task} || '') eq 'Docked'
    } @{$ships_by_body->{$body_id} || []};
    my $used_elsewhere = {};
    for my $spec (@$specs) {
      for my $ship (@spare) {
        last if $slots <= 0;
        next unless ship_meets_spec($ship, $spec);
        next if $used_elsewhere->{$ship->{id}};
        $used_elsewhere->{$ship->{id}} = 1;
        emit("transferring $ship->{type} $ship->{id} from $body_id to anchor $anchor_id");
        if ($noaction) {
          record_action($rec, { action => 'transfer', ship_id => $ship->{id},
                                 result => 'simulated', eta => time() + 3600 });
          $moved++;
          $slots--;
          next;
        }
        my $result = eval { $client->send_ship($ship->{id}, { body_id => $anchor_id }) };
        if (my $e = Exception::Class->caught('LacunaRPCException')) {
          emit("transfer $ship->{id}: " . $e->error, "transfer");
          next;
        }
        die $@ if $@;
        my $eta = Client::parse_time($result->{ship}{date_arrives}) || (time() + 3600);
        record_action($rec, { action => 'transfer', ship_id => $ship->{id},
                              result => 'ok', eta => $eta });
        $moved++;
        $slots--;
      }
    }
  }
  return $moved ? 'transferred' : '';
}

sub report_ship_shortfall {
  my ($entry, $specs, $anchor, $ships_by_body) = @_;
  my $rec = $entry->{rec};
  my $would = mirror_consume($ships_by_body->{$anchor} || [], $specs, 'name');
  return if $would->{pass};
  for my $message (@{$would->{messages}}) {
    emit("$rec->{name}: $message", "blocker");
    record_action($rec, { action => 'blocker', note => $message });
    my ($display) = $message =~ /of (\S+) \(/;
    next unless $display;
    report_missing_ship_type(ship_type_from_display($display), $entry);
  }
  return;
}

sub push_cargo {
  my ($entry, $kind, $anchor_id, $body_ids, $find_cargo) = @_;
  my $rec = $entry->{rec};
  for my $body_id (@$body_ids) {
    next unless $body_id != $anchor_id;
    next unless $trade_for{$body_id};
    my $item = $find_cargo->($body_id);
    next unless $item;
    my $ships = eval {
      $client->call(trade => get_trade_ships => $trade_for{$body_id}, $anchor_id)
    };
    next unless $ships && @{$ships->{ships} || []};
    my ($ship) = sort { ($b->{hold_size} || 0) <=> ($a->{hold_size} || 0) } @{$ships->{ships}};
    emit("pushing $kind cargo from $body_id to $anchor_id on ship $ship->{id}");
    if ($noaction) {
      record_action($rec, { action => 'push', kind => $kind, from => $body_id,
                             result => 'simulated' });
      return 'simulated';
    }
    my $result = eval {
      $client->trade_push($trade_for{$body_id}, $anchor_id, [ $item ], { ship_id => $ship->{id} });
    };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("push $kind: " . $e->error, "push");
      next;
    }
    die $@ if $@;
    my $eta = Client::parse_time($result->{fleet}{date_arrives});
    record_action($rec, { action => 'push', kind => $kind, from => $body_id,
                           result => 'ok', eta => $eta });
    return 'pushed';
  }
  return '';
}

sub fulfill_missions {
  my ($todo, $plan_lists) = @_;
  my @body_ids = sort keys %$plan_lists;
  my %ships_by_body = map { $_ => body_ships($_) } @body_ids;
  for my $entry (@$todo) {
    my $rec      = $entry->{rec};
    my $on       = $entry->{on}[0];
    my $anchor   = $on->{body_id};
    my $building = $on->{building_id};
    $current_body_name = $body_name{$anchor} || $anchor;
    my $objectives = parse_items($entry->{mission}{objectives});
    emit("fulfilling $rec->{name} (id $rec->{id})");
    my $pending = 0;

    for my $mv (@{$objectives->{fleet_movement}}) {
      my $eta = fleet_eta_from_actions($rec, $mv);
      if ($eta && $eta <= time()) {
        emit_debug("fleet movement $mv->{ship_type} -> $mv->{target_name}: arrival recorded");
        next;
      }
      my $in_transit = 0;
      for my $body_id (@body_ids) {
        $in_transit ||= transit_to_target($ships_by_body{$body_id} || [], $mv);
      }
      if ($in_transit) {
        emit_debug("fleet movement $mv->{ship_type} -> $mv->{target_name}: already in transit");
        next;
      }
      my $result = send_fleet_movement($entry, $mv, \%ships_by_body);
      $pending++ if $result =~ /^(?:sent|simulated|missing_ship)$/;
    }

    my $stored = anchor_stored($anchor);
    my $essentia = $client->empire_status->{essentia} || 0;
    for my $resource (sort keys %{$objectives->{resources}}) {
      my $need = $objectives->{resources}{$resource};
      next if ($stored->{$resource} || 0) >= $need;
      my $short = $need - ($stored->{$resource} || 0);
      emit("$rec->{name}: short $short $resource on $anchor", "shortfall");
      my $result = haul_resource($entry, $resource, $short, $anchor, \@body_ids);
      $pending++ if $result;
      if (!$result && $transmute_cap > 0) {
        my ($have_res) = sort { ($stored->{$b} || 0) <=> ($stored->{$a} || 0) }
                         grep { $_ ne $resource }
                         sort keys %$stored;
        $result = transmute_resource($entry, $anchor, $have_res, $resource,
                                      $short, $essentia)
          if $have_res;
        $pending++ if $result;
      }
      if (!$result) {
        emit("$rec->{name}: cannot cover $short $resource before expiry", "blocker");
        record_action($rec, { action => 'blocker', note => "short $short $resource" });
        $pending++;
      }
    }

    my $anchor_happiness = eval { $client->body_status($anchor)->{happiness} } || 0;
    if ($objectives->{happiness} && $anchor_happiness < $objectives->{happiness}) {
      my $short = $objectives->{happiness} - $anchor_happiness;
      emit("$rec->{name}: short $short happiness on $anchor (not haulable)", "blocker");
      record_action($rec, { action => 'blocker', note => "short $short happiness" });
      $pending++;
    }

    if ($objectives->{essentia}) {
      if ($essentia < $objectives->{essentia}) {
        emit("$rec->{name}: short " . ($objectives->{essentia} - $essentia) . " essentia (not fabricable)",
             "blocker");
        record_action($rec, { action => 'blocker', note => "short essentia" });
        $pending++;
      }
    }

    if (@{$objectives->{ships}}) {
      my $result = transfer_ships($entry, $objectives->{ships}, $anchor, \%ships_by_body, \@body_ids);
      $pending++ if $result && $result ne 'ok';
      report_ship_shortfall($entry, $objectives->{ships}, $anchor, \%ships_by_body);
      $ships_by_body{$anchor} = body_ships($anchor) if $result && $result ne 'ok';
    }

    for my $glyph_type (sort keys %{$objectives->{glyphs}}) {
      my $need = $objectives->{glyphs}{$glyph_type};
      my $have = 0;
      my $anchor_glyphs = eval { $client->glyph_list($anchor) };
      if ($anchor_glyphs) {
        ($have) = map { $_->{quantity} } grep { $_->{name} eq $glyph_type }
                  @{$anchor_glyphs->{glyphs} || []};
        $have //= 0;
      }
      next if $have >= $need;
      my $short = $need - $have;
      emit("$rec->{name}: short $short $glyph_type glyphs", "shortfall");
      my $result = push_cargo($entry, "glyph $glyph_type", $anchor, \@body_ids, sub {
        my $body_id = shift;
        my $glyphs = eval { $client->glyph_list($body_id) };
        return unless $glyphs;
        my ($found) = grep { $_->{name} eq $glyph_type && $_->{quantity} >= $short }
                      @{$glyphs->{glyphs} || []};
        return $found ? { type => 'glyph', name => $glyph_type, quantity => $short } : undef;
      });
      if (!$result) {
        emit("$rec->{name}: no source body has $short $glyph_type glyphs", "blocker");
        record_action($rec, { action => 'blocker', note => "short $short $glyph_type glyphs" });
      }
      $pending++ if $result;
    }

    for my $spec (@{$objectives->{plans}}) {
      my $have = 0;
      my $anchor_plans = $plan_lists->{$anchor} || {};
      for my $plan (@{$anchor_plans->{plans} || []}) {
        next unless ($plan->{name} || '') eq $spec->{class_name};
        next unless ($plan->{level} || 0) >= $spec->{level};
        next unless ($plan->{extra_build_level} || 0) >= $spec->{extra};
        $have += $plan->{quantity} || 0;
      }
      next if $have >= $spec->{quantity};
      my $short = $spec->{quantity} - $have;
      emit("$rec->{name}: short $short $spec->{class_name} plans", "shortfall");
      my $result = push_cargo($entry, "plan $spec->{class_name}", $anchor, \@body_ids, sub {
        my $body_id = shift;
        my $plans = $plan_lists->{$body_id} or return;
        my ($found) = grep {
          ($_->{name} || '') eq $spec->{class_name}
          && ($_->{level} || 0) >= $spec->{level}
          && ($_->{extra_build_level} || 0) >= $spec->{extra}
        } @{$plans->{plans} || []};
        return $found ? { type => 'plan', plan_type => $found->{plan_type},
                          quantity => min($short, $found->{quantity} || 1) } : undef;
      });
      if (!$result) {
        emit("$rec->{name}: no source body holds a sufficient $spec->{class_name} plan", "blocker");
        record_action($rec, { action => 'blocker', note => "short $short $spec->{class_name} plans" });
      }
      $pending++ if $result;
    }

    write_json_file(record_path($missions_dir, $rec), $rec);
    next if $pending;

    if (@{$objectives->{ships}}) {
      my $renames = protective_renames($entry, $objectives->{ships}, $anchor, \%ships_by_body);
      next unless $renames;
    }
    attempt_completion($entry, $building, $objectives, \%ships_by_body, $anchor);
  }
  return;
}

sub protective_renames {
  my ($entry, $specs, $anchor, $ships_by_body) = @_;
  my $ships = $ships_by_body->{$anchor} || [];
  my $plan = choose_rename_plan($ships, $specs);
  if ($plan->{blocked}) {
    my $rec = $entry->{rec};
    emit("$rec->{name}: cannot align ship consumption without eating keepers; deferring hand-in",
         "blocker");
    record_action($rec, { action => 'blocker', note => 'rename plans infeasible' });
    write_json_file(record_path($missions_dir, $rec), $rec);
    return 0;
  }
  return 1 if !$plan->{needed};
  my $rec = $entry->{rec};
  emit(sprintf("%s: %d renames (%s plan) before hand-in",
               $rec->{name}, $plan->{needed}, $plan->{mode}));
  for my $id (sort keys %{$plan->{renames}}) {
    my $name = $plan->{renames}{$id};
    my ($ship) = grep { ($_->{id} || 0) == $id } @$ships;
    if ($noaction) {
      record_action($rec, { action => 'rename', ship_id => $id, name => $name,
                             result => 'simulated' });
      next;
    }
    my $ok = eval { $client->name_ship($anchor, $id, $name); 1 };
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      emit("rename $id: " . $e->error, "rename");
      record_action($rec, { action => 'rename', ship_id => $id, name => $name,
                             result => 'error: ' . $e->error });
      next;
    }
    die $@ if $@;
    record_action($rec, { action => 'rename', ship_id => $id, name => $name, result => 'ok' });
    ($ship) = grep { ($_->{id} || 0) == $id } @$ships;
    $ship->{name} = $name if $ship;
  }
  write_json_file(record_path($missions_dir, $rec), $rec);
  return 1;
}

sub attempt_completion {
  my ($entry, $building_id, $objectives, $ships_by_body, $anchor) = @_;
  my $rec = $entry->{rec};
  my $eta_pending;
  for my $action (@{$rec->{actions} || []}) {
    $eta_pending = 1 if $action->{eta} && $action->{eta} > time();
  }
  if ($eta_pending) {
    emit_debug("$rec->{name}: waiting for in-flight ships/cargo");
    return;
  }
  if (@{$objectives->{ships}}) {
    my $would = mirror_consume($ships_by_body->{$anchor} || [], $objectives->{ships}, 'name');
    unless ($would->{pass}) {
      emit_debug("$rec->{name}: ship objective still short, not attempting");
      return;
    }
  }
  emit("attempting completion of $rec->{name} (id $rec->{id})");
  if ($noaction) {
    record_action($rec, { action => 'complete', result => 'simulated' });
    write_json_file(record_path($missions_dir, $rec), $rec);
    return;
  }
  my $result = eval { $client->mission_complete($building_id, $rec->{id}) };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    my $text = $e->error;
    if ($e->code == 1013) {
      emit("$rec->{name}: not yet completable: $text", "complete");
      record_action($rec, { action => 'complete', result => "1013: $text" });
      handle_fleet_shortfall($entry, $text, $ships_by_body);
    }
    elsif ($e->code == 1002) {
      emit("$rec->{name}: gone from the server: $text", "complete");
      $rec->{status}          = 'no_longer_listed';
      $rec->{status_at}       = now_stamp();
      $rec->{status_evidence} = 'rpc:complete_mission:1002';
      $rec->{status_hint}     = 'likely_sniped_or_expired';
      record_action($rec, { action => 'complete', result => "1002: $text" });
    }
    else {
      emit("$rec->{name}: completion failed: $text", "complete");
      record_action($rec, { action => 'complete', result => $e->code . ": $text" });
    }
    write_json_file(record_path($missions_dir, $rec), $rec);
    return;
  }
  die $@ if $@;
  $rec->{status}          = 'completed';
  $rec->{status_at}       = now_stamp();
  $rec->{status_evidence} = 'rpc:complete_mission:ok';
  record_action($rec, { action => 'complete', result => 'ok' });
  write_json_file(record_path($missions_dir, $rec), $rec);
  emit("completed: $rec->{name} (id $rec->{id})", "success");
  return;
}

sub handle_fleet_shortfall {
  my ($entry, $text, $ships_by_body) = @_;
  return unless $text =~ /No (\S+) has arrived at (.*?) \((-?\d+),(-?\d+)\)/;
  my $mv = {
    ship_type   => ship_type_from_display($1),
    target_name => $2,
    x           => $3 + 0,
    y           => $4 + 0,
  };
  my $rec = $entry->{rec};
  my $eta = fleet_eta_from_actions($rec, $mv);
  return unless $eta && $eta <= time();
  emit("resending a $mv->{ship_type} to $mv->{target_name} after a passed-ETA arrival was not counted",
       "complete");
  send_fleet_movement($entry, $mv, $ships_by_body);
  return;
}

sub sst_sales {
  my ($holdings, $listed, $trades_active, $plan_lists) = @_;
  $current_body_name = $body_name{$sst_body_id} || $sst_body_id;
  my $listed_by_letter = {};
  $listed_by_letter->{lcot_letter($_->{class_name})} += $_->{quantity} || 0 for @$listed;
  my $sellable = sellable_copies($holdings, $listed_by_letter, $copies_keep);
  return unless keys %$sellable;
  if ($trades_active) {
    emit("SST market already has an active listing; will list more after it sells");
    return;
  }
  my ($letter) = sort keys %$sellable;
  my $bld = $transporter_for{$sst_body_id} or return;
  my $sst_plans = $plan_lists->{$sst_body_id} || {};
  my ($copy) = grep {
    ($_->{plan_type} || '') =~ /^LCOT\Q$letter\E\z/i && ($_->{quantity} || 0) > 0
  } @{$sst_plans->{plans} || []};
  if (!$copy) {
    SOURCE: for my $body_id (sort keys %$plan_lists) {
      next unless $body_id != $sst_body_id;
      next unless $trade_for{$body_id};
      my ($source) = grep {
        ($_->{plan_type} || '') =~ /^LCOT\Q$letter\E\z/i && ($_->{quantity} || 0) > 0
      } @{$plan_lists->{$body_id}{plans} || []};
      next unless $source;
      my $ships = eval {
        $client->call(trade => get_trade_ships => $trade_for{$body_id}, $sst_body_id)
      };
      next unless $ships && @{$ships->{ships} || []};
      my ($ship) = sort { ($b->{hold_size} || 0) <=> ($a->{hold_size} || 0) } @{$ships->{ships}};
      emit("hauling LCOT$letter plan copy from $body_id to $sst_body_id for listing");
      if ($noaction) {
        emit("simulated: would push plan LCOT$letter to $sst_body_id");
        return;
      }
      my $ok = eval {
        $client->trade_push($trade_for{$body_id}, $sst_body_id,
                            [ { type => 'plan', plan_type => $source->{plan_type}, quantity => 1 } ],
                            { ship_id => $ship->{id} });
        1;
      };
      if (my $e = Exception::Class->caught('LacunaRPCException')) {
        emit("plan haul for listing: " . $e->error, "sst");
        return;
      }
      die $@ if $@;
      emit("plan hauled; listing next run");
      return;
    }
    emit("sellable LCOT$letter copy exists but none is on the SST anchor or haulable to it", "sst");
    return;
  }
  emit("listing one LCOT$letter plan copy on the SST market at $list_at essentia");
  return if $noaction;
  my $ok = eval {
    $client->call(transporter => add_to_market => $bld,
                  [ { type => 'plan', plan_type => $copy->{plan_type}, quantity => 1 } ],
                  sprintf("%0.1f", $list_at));
    1;
  };
  if (my $e = Exception::Class->caught('LacunaRPCException')) {
    emit("add_to_market: " . $e->error, "sst");
    return;
  }
  die $@ if $@;
  emit("listed LCOT$letter at $list_at essentia (1 essentia listing fee)", "success");
  return;
}

sub summary {
  my $holdings = shift;
  $current_body_name = undef;
  my @records = all_records($missions_dir);
  my %by_status;
  push @{$by_status{$_->{status} || 'active'}}, $_ for @records;
  my @outstanding = outstanding_letters($holdings || {}, $copies_goal);
  emit(sprintf("summary: %d records (%s); outstanding LCOT letters: %s",
               scalar(@records),
               join(", ", map { "$_ " . scalar @{$by_status{$_}} } sort keys %by_status),
               @outstanding ? join("", @outstanding) : 'none'));
  return;
}

sub run {
  parse_args();
  return offline_report() if $noaction >= 2;
  online_run();
  return;
}

sub offline_report {
  my @records = all_records($missions_dir);
  $current_body_name = undef;
  return emit("offline: no mission records under $missions_dir yet") unless @records;
  my %by_status;
  push @{$by_status{$_->{status} || 'active'}}, $_ for @records;
  emit(sprintf("offline report: %d records (%s)",
              scalar(@records),
              join(", ", map { "$_: " . scalar @{$by_status{$_}} } sort keys %by_status)));
  for my $rec (@records) {
    my $letter = $rec->{lcot_letter} ? " plan $rec->{lcot_letter}" : "";
    my @planets = map { $body_name{$_} || $_ } keys %{$rec->{seen_on} || {}};
    emit(sprintf("  [%s] %s (id %s)%s on %s", $rec->{status} || 'active', $rec->{name}, $rec->{id},
                 $letter, @planets ? join(", ", @planets) : 'unknown planet'));
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
