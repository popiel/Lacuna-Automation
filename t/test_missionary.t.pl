use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

our $script;

BEGIN {
  $script = abs_path(File::Spec->catfile(dirname(__FILE__), '..', 'missionary.pl'));
  unshift @INC, dirname($script);
}
require $script;

our ($noaction, $quiet, $missions_dir, $debug, $copies_goal, $copies_keep, $list_at,
     $client, $empire_name, $essentia_floor, $transmute_cap, $sst_body_id,
     $current_body_name, $server_mission_dir, $server_lib_dir,
     @ore_types, @food_types,
     %buildings_for, %mc_for, %trade_for, %transporter_for, %ports_for, %yards_for,
     %body_coords, %body_name, %glyph_halls_cache);

$noaction = 1;
$quiet    = 1;
$debug    = 0;

subtest 'sanitize_title' => sub {
  plan tests => 5;
  is(sanitize_title('Tyleon Dig (part 1)'), 'Tyleon_Dig__part_1_', 'parens and spaces');
  is(sanitize_title("The Va\x{2019}lox of Tyleon"), 'The_Va_lox_of_Tyleon', 'curly apostrophe bytewise');
  is(sanitize_title('See(d) The Rainbow'), 'See_d__The_Rainbow', 'parens mid-title');
  is(sanitize_title('A-B.C 9'), 'A-B.C_9', 'dash and dot kept');
  is(sanitize_title(''), '', 'empty title');
};

subtest 'ship_type_from_display' => sub {
  plan tests => 4;
  is(ship_type_from_display('Cargo Ship'), 'cargo_ship', 'spaces to underscores');
  is(ship_type_from_display('Supply Pod4'), 'supply_pod4', 'digits kept');
  is(ship_type_from_display('Snark'), 'snark', 'single word');
  is(ship_type_from_display('Short Range Colony Ship'), 'short_range_colony_ship', 'multi word');
};

subtest 'lcot_letter' => sub {
  plan tests => 4;
  is(lcot_letter('Lost City of Tyleon (A)'), 'A', 'display name letter');
  is(lcot_letter('Lost City of Tyleon (I)'), 'I', 'display name letter I');
  is(lcot_letter('LCOTd'), 'D', 'plan_type letter');
  is(lcot_letter('Halls of Vrbansk'), undef, 'non-LCOT plan');
};

subtest 'parse_items objectives' => sub {
  plan tests => 9;
  my $items = parse_items([
    '10,000 essentia.',
    '50,000,000 happiness.',
    '5,000 gold',
    '1 anthracite glyph',
    '2 gold glyphs',
    '    3 Dory (speed >= 1, stealth >= 0, hold size >= 100, combat >= 0, berth >= 1)',
    '    1 Send Probe to Sol (123,-456).',
    '2 Halls of Vrbansk (>= 1) plans',
    '1 Lost City of Tyleon (A) (>= 1) plan',
  ]);
  is($items->{essentia}, 10000, 'essentia decommified');
  is($items->{happiness}, 50000000, 'happiness decommified');
  is($items->{resources}{gold}, 5000, 'resource line');
  is($items->{glyphs}{anthracite}, 1, 'glyph singular');
  is($items->{glyphs}{gold}, 2, 'glyph plural');
  is_deeply($items->{ships}, [{
    type => 'dory', quantity => 3, speed => 1, stealth => 0,
    hold_size => 100, combat => 0, berth_level => 1,
  }], 'ship objective with padded count');
  is_deeply($items->{fleet_movement}, [{
    ship_type => 'probe', target_name => 'Sol', x => 123, y => -456,
  }], 'fleet movement target');
  is_deeply($items->{plans}[0], {
    class_name => 'Halls of Vrbansk', level => 1, extra => 0, quantity => 2,
  }, 'plan objective');
  is_deeply($items->{plans}[1], {
    class_name => 'Lost City of Tyleon (A)', level => 1, extra => 0, quantity => 1,
  }, 'plan objective with parens in class name');
};

subtest 'parse_items rewards and extras' => sub {
  plan tests => 6;
  my $items = parse_items([
    '1 Lost City of Tyleon (A) level 1 plan',
    '    1 Snark (speed: 500, stealth: 250, hold size: 0, combat: 100, berth: 1)',
    '1 Halls of Vrbansk level 1+1 plan',
    '2 Supply Pod4 (speed >= 10, stealth >= 0, hold size >= 1,000, combat >= 0, berth >= 1)',
    '    2 Send Surveyor to ZZ9 Plural Z Alpha (-500,750).',
  ]);
  is_deeply($items->{plans}[0], {
    class_name => 'Lost City of Tyleon (A)', level => 1, extra => 0, quantity => 1,
  }, 'plan reward');
  is_deeply($items->{ships}[0], {
    type => 'snark', quantity => 1, speed => 500, stealth => 250,
    hold_size => 0, combat => 100, berth_level => 1,
  }, 'ship reward with colons');
  is_deeply($items->{plans}[1], {
    class_name => 'Halls of Vrbansk', level => 1, extra => 1, quantity => 1,
  }, 'plan reward with extra build level');
  is_deeply($items->{ships}[1], {
    type => 'supply_pod4', quantity => 2, speed => 10, stealth => 0,
    hold_size => 1000, combat => 0, berth_level => 1,
  }, 'ship objective commified stats and digits in display name');
  is_deeply($items->{fleet_movement}[0], {
    ship_type => 'surveyor', target_name => 'ZZ9 Plural Z Alpha', x => -500, y => 750,
  }, 'negative fleet movement coords');
  is(scalar @{$items->{fleet_movement}}, 1, 'consolidated identical movements are one requirement');
};

subtest 'parse_items ignores junk' => sub {
  plan tests => 2;
  my $items = parse_items([undef, '', '  ', 'Some Description Text', '10,000 essentia.']);
  is($items->{essentia}, 10000, 'only the parseable line counts');
  is(scalar @{$items->{ships}}, 0, 'no ships from prose');
};

subtest 'record_instance' => sub {
  plan tests => 13;
  my $dir = tempdir(CLEANUP => 1);
  my $mission = {
    id => 42, name => 'Tyleon Dig (part 1)',
    description => 'dig',
    objectives => ['9x Send Probe'], rewards => ['1 thing'],
    max_university_level => 10, date_posted => 'x',
  };
  my $rec = record_instance($dir, $mission, 1, 10);
  my $path = File::Spec->catfile($dir, 'Tyleon_Dig__part_1_', '42.json');
  ok(-f $path, 'sanitized title directory and id file');
  is($rec->{status}, 'active', 'fresh record active');
  is($rec->{first_seen}, $rec->{last_seen}, 'first and last seen equal');
  ok($rec->{first_seen_epoch}, 'epoch bookkeeping');
  is($rec->{seen_on}{1}{10}, $rec->{last_seen}, 'vending recorded');
  is(scalar @{$rec->{actions}}, 0, 'empty actions');

  my $first = $rec->{first_seen};
  $rec->{actions} = [{ time => 't', action => 'send', params => {}, result => 'ok' }];
  write_json_file($path, $rec);
  my $rec2 = record_instance($dir, $mission, 2, 20);
  is($rec2->{first_seen}, $first, 'first_seen preserved on merge');
  is(scalar @{$rec2->{actions}}, 1, 'actions preserved on merge');
  ok(exists $rec2->{seen_on}{2}{20}, 'second building recorded');
  ok(exists $rec2->{seen_on}{1}{10}, 'first building preserved');

  $rec2->{status} = 'completed';
  write_json_file($path, $rec2);
  my $rec3 = record_instance($dir, $mission, 1, 10);
  is($rec3->{status}, 'completed', 'completed is terminal');

  $rec3->{status} = 'no_longer_listed';
  write_json_file($path, $rec3);
  my $rec4 = record_instance($dir, $mission, 1, 10);
  is($rec4->{status}, 'active', 're-vend revives a no_longer_listed record');
  is($rec4->{status_evidence}, 'revend', 're-vend evidence recorded');
};

subtest 'retire_missing_instances' => sub {
  plan tests => 9;
  my $rec_active = {
    id => 1, name => 'One', status => 'active',
    seen_on => { 100 => { 10 => 't' } }, first_seen_epoch => time(),
  };
  my $rec_gone = {
    id => 2, name => 'Two', status => 'active',
    seen_on => { 100 => { 10 => 't' } }, first_seen_epoch => time(),
  };
  my $rec_both = {
    id => 3, name => 'Three', status => 'active',
    seen_on => { 100 => { 10 => 't', 20 => 't' } }, first_seen_epoch => time(),
  };
  my $rec_done = {
    id => 4, name => 'Four', status => 'completed',
    seen_on => { 100 => { 10 => 't' } },
  };
  my @records = ($rec_active, $rec_gone, $rec_both, $rec_done);
  my @retired = retire_missing_instances(\@records, { 10 => [1, 3, 5], 20 => [3] }, time());
  is(scalar @retired, 1, 'only the fully-missing instance retires');
  is($rec_gone->{status}, 'no_longer_listed', 'gone instance retired');
  like($rec_gone->{status_evidence}, qr/^list_diff/, 'evidence recorded');
  is($rec_active->{status}, 'active', 'still-listed instance untouched');
  is($rec_both->{status}, 'active', 'instance listed on one building survives');
  is($rec_done->{status}, 'completed', 'completed records never retire');

  my @retired2 = retire_missing_instances(\@records, { 10 => [1, 3, 5], 20 => [] }, time());
  is(scalar @retired2, 0, 'no retirement without evidence from every vending building');

  $rec_both->{seen_on} = { 100 => { 20 => 't' } };
  @retired2 = retire_missing_instances(\@records, { 10 => [1, 3, 5], 20 => [] }, time());
  is(scalar @retired2, 1, 'retires when all vending buildings drop it');
  is($rec_both->{status_hint}, 'likely_sniped', 'sniped hint for young postings');
};

subtest 'infer_status_hint' => sub {
  plan tests => 3;
  my $old = {
    id => 9, name => 'Old', status => 'active',
    seen_on => { 100 => { 10 => 't' } },
    first_seen_epoch => time() - 80 * 3600,
  };
  my @retired = retire_missing_instances([$old], { 10 => [] }, time());
  is($retired[0]{status_hint}, 'likely_72h_expiry', 'old posting hints expiry');

  my $recent = {
    id => 10, name => 'Old', status => 'active',
    seen_on => { 100 => { 10 => 't' } }, first_seen_epoch => time(),
  };
  @retired = retire_missing_instances([$recent], { 10 => [] }, time());
  is($retired[0]{status_hint}, 'likely_sniped', 'no completed twin falls back to sniped');

  $recent = {
    id => 12, name => 'Old', status => 'active',
    seen_on => { 100 => { 10 => 't' } }, first_seen_epoch => time(),
  };
  my $twin = { id => 11, name => 'Old', status => 'completed' };
  @retired = retire_missing_instances([$recent, $twin], { 10 => [] }, time());
  is($retired[0]{status_hint}, 'title_completed_by_us_recently', 'completed twin hints supersession');
};

subtest 'union_needed' => sub {
  plan tests => 7;
  my $a = parse_items(['10,000 essentia.', '5,000 gold', '1 anthracite glyph']);
  my $b = parse_items(['100 essentia.', '2 gold', '2 gold glyphs']);
  my $c = parse_items(['50,000,000 happiness.']);
  my $needed = union_needed($a, $b, $c);
  is($needed->{essentia}, 10000, 'essentia unions at the max');
  is($needed->{happiness}, 50000000, 'happiness unions at the max');
  is($needed->{resources}{gold}, 5002, 'resources sum');
  is($needed->{glyphs}{anthracite}, 1, 'glyph types union');
  is($needed->{glyphs}{gold}, 2, 'glyph types union again');
  is(scalar @{$needed->{ships}}, 0, 'no ships');
  is(scalar @{$needed->{plans}}, 0, 'no plans');
};

subtest 'classify_rewards' => sub {
  plan tests => 10;
  my $needed = union_needed(
    parse_items(['5,000 gold', '2,000 cheese', '1 gypsum glyph',
                 '    8 Scow (speed >= 1, stealth >= 0, hold size >= 100, combat >= 0, berth >= 1)',
                 '2 Halls of Vrbansk (>= 1) plans']),
    parse_items(['100 essentia.']),
  );
  my ($class, $letter, $reason);

  ($class, $letter, $reason) = classify_rewards(parse_items(['1 Lost City of Tyleon (D) level 1 plan']), $needed);
  is($class, 'lcot', 'LCOT reward classifies lcot');
  is($letter, 'D', 'LCOT letter extracted');
  is($reason, 'LCOT plan D', 'LCOT reason');

  ($class, undef, $reason) = classify_rewards(parse_items(['1,000 gold']), $needed);
  is($class, 'useful', 'needed resource is useful');

  ($class, undef, $reason) = classify_rewards(parse_items(['3,000 lapis']), $needed);
  is($class, 'useless', 'unneeded resource is useless');

  ($class, undef, $reason) = classify_rewards(
    parse_items(['    1 Scow (speed: 10, stealth: 0, hold size: 100, combat: 0, berth: 1)']), $needed);
  is($class, 'useful', 'ship meeting a needed minimum is useful');

  ($class, undef, $reason) = classify_rewards(
    parse_items(['    1 Scow (speed: 10, stealth: 0, hold size: 50, combat: 0, berth: 1)']), $needed);
  is($class, 'useless', 'ship below a needed hold minimum is useless');

  ($class, undef, $reason) = classify_rewards(parse_items(['1 Halls of Vrbansk level 1 plan']), $needed);
  is($class, 'useful', 'plan matching a needed class is useful');

  ($class, undef, $reason) = classify_rewards(parse_items(['1 Halls of Vrbansk level 1+1 plan']), $needed);
  is($class, 'useful', 'plan exceeding a needed level is useful');

  ($class, undef, $reason) = classify_rewards(parse_items(['1 Sand level 5 plan']), $needed);
  is($class, 'useless', 'unneeded plan class is useless');
};

subtest 'should_skip' => sub {
  plan tests => 7;
  my $needed = union_needed(parse_items(['5,000 gold']));
  my ($class) = classify_rewards(parse_items(['1 Lost City of Tyleon (A) level 1 plan']), $needed);
  ok(!should_skip($class, parse_items(['1 Lost City of Tyleon (A) level 1 plan']), parse_items([])),
     'lcot missions are never skipped');

  my $rewards   = parse_items(['5,000 gold']);
  my $objectives = parse_items(['1,000 gold']);
  ($class) = classify_rewards($rewards, $needed);
  ok(!should_skip($class, $rewards, $objectives), 'useful missions are never skipped');

  $rewards = parse_items(['200 lapis']);
  ($class) = classify_rewards($rewards, $needed);
  ok(should_skip($class, $rewards, parse_items(['500 lapis'])),
     'pure-resource mission returning less than it takes is skipped');

  $rewards = parse_items(['200 lapis']);
  ($class) = classify_rewards($rewards, $needed);
  ok(!should_skip($class, $rewards, parse_items(['100 lapis', '1 rutile glyph'])),
     'glyph rewards are standalone value, not skipped');

  $rewards = parse_items([]);
  ($class) = classify_rewards($rewards, $needed);
  ok(should_skip($class, $rewards, parse_items(['100 lapis'])), 'empty rewards are skipped');

  $rewards = parse_items(['2,000 lapis']);
  ($class) = classify_rewards($rewards, $needed);
  ok(!should_skip($class, $rewards, parse_items(['1,000 lapis'])),
     'pure-resource mission that returns more than it takes is kept');

  $rewards = parse_items(['2,000 lapis']);
  my $objs = parse_items(['5,000 lapis', '100 essentia.']);
  ($class) = classify_rewards($rewards, $needed);
  ok(should_skip($class, $rewards, $objs), 'essentia drain with no valuable reward is skipped');
};

subtest 'holdings, sellable, outstanding' => sub {
  plan tests => 10;
  my $plan_lists = {
    573252 => { plans => [ { plan_type => 'LCOTa', quantity => 2 },
                           { plan_type => 'HallsOfVrbansk', quantity => 1 } ] },
    577083 => { plans => [ { plan_type => 'LCOTa', quantity => 3 },
                           { plan_type => 'lcoti', quantity => 1 } ] },
    785996 => { plans => [ { plan_type => 'LCOTA', quantity => 6 } ] },
  };
  my $holdings = lcot_holdings_from_plans($plan_lists);
  is($holdings->{A}, 11, 'case-insensitive LCOTa sums across bodies');
  is($holdings->{I}, 1, 'lowercase plan_type counts');
  is(scalar keys %$holdings, 2, 'non-LCOT plans ignored');

  add_listed_holdings($holdings, parse_items(['1 Lost City of Tyleon (A) level 1 plan'])->{plans});
  is($holdings->{A}, 12, 'SST-listed copies count as ours');

  my $sellable = sellable_copies($holdings, { A => 1 }, 6);
  is($sellable->{A}, 5, 'sellable = holdings - listed - keep');
  ok(!exists $sellable->{I}, 'letters at or below keep are not sellable');

  $sellable = sellable_copies($holdings, { A => 1 }, 20);
  is(scalar keys %$sellable, 0, 'nothing sellable when keep exceeds holdings');

  my @outstanding = outstanding_letters($holdings, 9);
  ok(!grep { $_ eq 'A' } @outstanding, 'letter A at goal is not outstanding');
  ok(grep { $_ eq 'I' } @outstanding, 'letter I below goal is outstanding');
  ok(grep { $_ eq 'B' } @outstanding, 'never-seen letters are outstanding');
};

subtest 'compute_essentia_floor' => sub {
  plan tests => 2;
  is(compute_essentia_floor({ essentia => 100 }, 20), 110, 'floor raised above the objective');
  is(compute_essentia_floor({ essentia => 0 }, 20), 20, 'base floor with no essentia need');
};

sub ship {
  my (%args) = @_;
  return {
    id => delete($args{id}) // 1, name => delete($args{name}) // 'Ship',
    type => delete($args{type}) // 'scow', task => delete($args{task}) // 'Docked',
    speed => delete($args{speed}) // 100, stealth => delete($args{stealth}) // 0,
    hold_size => delete($args{hold}) // 1000, combat => delete($args{combat}) // 0,
    berth_level => delete($args{berth}) // 1, %args,
  };
}

subtest 'mirror_consume' => sub {
  plan tests => 10;
  my @ships = (
    ship(id => 1, name => 'Alpha', hold => 400000),
    ship(id => 2, name => 'Bravo', hold => 40000),
    ship(id => 3, name => 'Caret', hold => 350000),
  );
  my $result = mirror_consume(\@ships, [{ type => 'scow', quantity => 2, hold_size => 40000 }], 'name');
  ok($result->{pass}, 'two scows available');
  is_deeply($result->{ids}, [1, 2], 'alphabetical name order with rows cap');

  $result = mirror_consume(\@ships, [{ type => 'scow', quantity => 2, hold_size => 40000 }], 'stats');
  is_deeply($result->{ids}, [2, 3], 'stat order picks the least qualified first');

  $result = mirror_consume(\@ships, [{ type => 'scow', quantity => 4, hold_size => 40000 }], 'name');
  ok(!$result->{pass}, 'shortfall fails');
  like($result->{messages}[0], qr/^Need 4 of scow/, 'shortfall message');

  my @mixed = (ship(id => 1, name => 'Docked1'), ship(id => 2, name => 'Flying1', task => 'Travelling'));
  $result = mirror_consume(\@mixed, [{ type => 'scow', quantity => 2 }], 'name');
  ok(!$result->{pass}, 'travelling ships are not candidates');

  my @specs = (
    { type => 'scow', quantity => 2, hold_size => 100 },
    { type => 'scow', quantity => 1, hold_size => 300 },
  );
  my @pool = (
    ship(id => 1, name => 'D1', hold => 100),
    ship(id => 2, name => 'D2', hold => 200),
    ship(id => 3, name => 'D3', hold => 300),
  );
  $result = mirror_consume(\@pool, \@specs, 'name');
  ok($result->{pass}, 'multi-spec pass');
  is_deeply([sort { $a <=> $b } @{$result->{ids}}], [1, 2, 3], 'no ship used for two specs');

  my @tight = (
    ship(id => 1, name => 'Alpha', hold => 400000),
    ship(id => 2, name => 'Small', hold => 40000),
  );
  $result = mirror_consume(\@tight, [
    { type => 'scow', quantity => 1, hold_size => 40000 },
    { type => 'scow', quantity => 1, hold_size => 150000 },
  ], 'name');
  is_deeply([sort { $a <=> $b } @{$result->{ids}}], [1, 2], 'tightest spec assigned first');

  my @merged = (
    { type => 'scow', quantity => 1, hold_size => 100 },
    { type => 'scow', quantity => 2, hold_size => 100 },
  );
  is_deeply(merge_specs(\@merged), [{ type => 'scow', quantity => 3, hold_size => 100 }],
            'identical specs merge quantities');
};

subtest 'scheme names' => sub {
  plan tests => 4;
  is(scheme_name('zzm', ship(hold => 150000, speed => 200)),
     'zzm h0150000 s000200 t00000 c0000 b01', 'keeper name format');
  is(scheme_name('aam', ship(hold => 4000, speed => 200)),
     'aam h0004000 s000200 t00000 c0000 b01', 'sacrifice name format');
  ok(is_scheme_name('zzm h0150000 s000200 t00000 c0000 b01'), 'scheme name recognized');
  ok(!is_scheme_name('Scow 7'), 'ordinary name not recognized');
};

subtest 'choose_rename_plan' => sub {
  plan tests => 12;
  my @ships = (
    ship(id => 1, name => 'B1', hold => 400000),
    ship(id => 2, name => 'W1', hold => 40000),
  );
  my $plan = choose_rename_plan(\@ships, [{ type => 'scow', quantity => 1, hold_size => 40000 }]);
  is($plan->{needed}, 1, 'one rename settles the tie case');
  is($plan->{mode}, 'keep', 'ties prefer the keep plan');
  is($plan->{renames}{1}, 'zzm h0400000 s000100 t00000 c0000 b01', 'keeper renamed by absolute stats');

  my @cascade = (
    (map { ship(id => $_, name => "Keeper $_", hold => 200000 + $_ * 50000) } 1 .. 6),
    ship(id => 7, name => 'W1', hold => 40000),
    ship(id => 8, name => 'W2', hold => 41000),
  );
  $plan = choose_rename_plan(\@cascade, [{ type => 'scow', quantity => 2, hold_size => 40000 }]);
  is($plan->{mode}, 'consume', 'many keepers ahead of few lesser ships: consume plan wins');
  is($plan->{needed}, 2, 'consume plan renames only the two sacrifices');
  is_deeply([sort keys %{$plan->{renames}}], [7, 8], 'sacrifices renamed, keepers untouched');

  my @aligned = (
    ship(id => 1, name => 'aam h0004000 s000100 t00000 c0000 b01', hold => 40000),
    ship(id => 2, name => 'zzm h0400000 s000100 t00000 c0000 b01', hold => 400000),
  );
  $plan = choose_rename_plan(\@aligned, [{ type => 'scow', quantity => 1, hold_size => 40000 }]);
  is($plan->{needed}, 0, 'already-aligned fleet needs no renames');

  my @short = (ship(id => 1, name => 'Only1', hold => 400000));
  $plan = choose_rename_plan(\@short, [{ type => 'scow', quantity => 2, hold_size => 40000 }]);
  is($plan->{needed}, 0, 'unfulfillable ship count means no renames');

  my @keeper_scheme = (
    ship(id => 1, name => 'zzm h0400000 s000100 t00000 c0000 b01', hold => 400000),
    ship(id => 2, name => 'W1', hold => 40000),
    ship(id => 3, name => 'W2', hold => 41000),
  );
  $plan = choose_rename_plan(\@keeper_scheme, [{ type => 'scow', quantity => 2, hold_size => 40000 }]);
  is($plan->{needed}, 0, 'scheme-named keeper already sorts last');

  my @handnamed = (
    ship(id => 1, name => 'B1', hold => 400000),
    ship(id => 2, name => 'Zzzz Guardian', hold => 40000),
  );
  $plan = choose_rename_plan(\@handnamed, [{ type => 'scow', quantity => 1, hold_size => 40000 }]);
  is($plan->{needed}, 1, 'hand-named late ship settles with one rename');
  is($plan->{mode}, 'consume', 'keep cannot sort past zzz, so the plan switches direction');
  is_deeply($plan->{renames}, { 2 => 'aam h0040000 s000100 t00000 c0000 b01' },
            'the lesser ship itself is renamed early and consumed');
};

subtest 'simulate_rename_plan idempotence' => sub {
  plan tests => 4;
  my @ships = (
    ship(id => 1, name => 'zzm h0400000 s000100 t00000 c0000 b01', hold => 400000),
    ship(id => 2, name => 'W1', hold => 40000),
    ship(id => 3, name => 'B3', hold => 500000),
  );
  my $result = simulate_rename_plan(\@ships, [{ type => 'scow', quantity => 2, hold_size => 40000 }], 'keep');
  ok($result->{feasible}, 'keep plan settles');
  is_deeply($result->{renames}, { 3 => 'zzm h0500000 s000100 t00000 c0000 b01' },
            'renames only the non-scheme keeper, stat-based and stable');

  my @settled = map {
    $_->{id} == 3 ? { %{$_}, name => 'zzm h0500000 s000100 t00000 c0000 b01' } : $_
  } @ships;
  $result = simulate_rename_plan(\@settled, [{ type => 'scow', quantity => 2, hold_size => 40000 }], 'keep');
  ok($result->{feasible}, 'settled fleet is feasible');
  is(scalar keys %{$result->{renames}}, 0, 'settled fleet yields no further renames');
};

package FakeClient;

our $AUTOLOAD;

sub new {
  my ($class, %args) = @_;
  return bless {
    calls     => [],
    responses => $args{responses} || {},
    buildings => $args{buildings} || {},
  }, $class;
}

sub calls { return $_[0]->{calls} }

sub calls_for {
  my ($self, $method) = @_;
  return grep { $_->[0] eq $method } @{$self->{calls}};
}

sub call {
  my $self = shift;
  my $api = shift;
  my $method = shift;
  push @{$self->{calls}}, ["$api/$method", @_];
  my $resp = $self->{responses}{"$api/$method"};
  return ref($resp) eq 'CODE' ? $resp->($self, @_) : $resp;
}

sub find_building {
  my ($self, $body_id, $name) = @_;
  my $bh = $self->{buildings}{$body_id};
  return wantarray ? () : undef unless $bh;
  my @found = sort { $a->{level} <=> $b->{level} }
              map { { %{$bh->{$_}}, id => $_ } }
              grep { $bh->{$_}{name} eq $name } keys %$bh;
  return wantarray ? @found : ($found[-1] || undef);
}

sub AUTOLOAD {
  my $self = shift;
  my $method = $AUTOLOAD;
  $method =~ s/.*:://;
  return if $method eq 'DESTROY';
  push @{$self->{calls}}, [$method, @_];
  my $resp = $self->{responses}{$method};
  return ref($resp) eq 'CODE' ? $resp->($self, @_) : $resp;
}

package main;

sub future_stamp {
  my $time = shift;
  my @g = gmtime($time);
  return sprintf("%d %d %d %02d:%02d:%02d +0000", $g[3], $g[4] + 1, $g[5] + 1900, $g[2], $g[1], $g[0]);
}

subtest 'online flow with FakeClient' => sub {
  plan tests => 18;
  my $dir = tempdir(CLEANUP => 1);
  my $saved_dir      = $missions_dir;
  my $saved_noaction = $noaction;
  my $saved_quiet    = $quiet;
  my $saved_missions = $server_mission_dir;
  $missions_dir = $dir;
  $server_mission_dir = tempdir(CLEANUP => 1);
  $noaction     = 0;
  $quiet        = 1;
  %mc_for = %trade_for = %transporter_for = ();
  %ports_for = ();
  %yards_for = ();
  %body_coords = ();
  $sst_body_id = undef;

  my %buildings = (
    1 => {
      100 => { name => 'Mission Command',  level => 3 },
      101 => { name => 'Trade Ministry',   level => 5 },
      102 => { name => 'Space Port',       level => 10 },
      103 => { name => 'Shipyard',         level => 5 },
    },
    2 => {
      200 => { name => 'Mission Command',  level => 2 },
      201 => { name => 'Trade Ministry',   level => 4 },
      202 => { name => 'Space Port',       level => 8 },
    },
  );
  my $lcot_mission = {
    id => 7, name => 'Tyleon Water Glyph', description => 'x',
    objectives => [ '    1 Send Probe to Sol (10,-20).' ],
    rewards => [ '1 Lost City of Tyleon (G) level 1 plan' ],
    max_university_level => 10, date_posted => 'y',
  };
  my $junk_mission = {
    id => 8, name => 'Toll Booth', description => 'x',
    objectives => [ '100 gold' ],
    rewards => [ '100 lapis' ],
    max_university_level => 20, date_posted => 'y',
  };
  my $status = {
    name => 'TestEmpire', id => 46, essentia => 500,
    planets => { 1 => 'Alpha', 2 => 'Beta' },
    bodies => { colonies => [
      { empire_id => 46, x => 10,  y => -20, name => 'Alpha' },
      { empire_id => 46, x => 900, y => 900, name => 'Beta' },
    ] },
  };
  $client = FakeClient->new(
    buildings => \%buildings,
    responses => {
      empire_status => $status,
      body_buildings => sub {
        my ($self, $body_id) = @_;
        return { buildings => $self->{buildings}{$body_id} };
      },
      body_plans => { plans => [] },
      body_status => { happiness => 1000 },
      port_all_ships => sub {
        my ($self, $body_id) = @_;
        return { ships => $body_id == 2
                 ? [ { id => 55, name => 'Probe', type => 'probe', task => 'Docked',
                       speed => 100, stealth => 0, hold_size => 0, combat => 0, berth_level => 1 } ]
                 : [] };
      },
      yard_buildable => { buildable => {} },
      mission_list => { missions => [ $lcot_mission, $junk_mission ] },
      mission_skip => { status => {} },
      mission_complete => { status => {} },
      send_ship => { ship => { id => 55, date_arrives => future_stamp(time() + 7200) } },
      'trade/get_stored_resources' => { resources => {} },
    },
  );

  my @body_ids = resolve_bodies($status);
  is(scalar @body_ids, 2, 'both bodies resolved');
  is_deeply($body_coords{1}, [10, -20], 'colony coordinates captured');

  my @mcs = locate_mission_commands(\@body_ids);
  is(scalar @mcs, 2, 'a Mission Command per body');
  is($trade_for{1}, 101, 'trade ministry noted');

  my ($vended, $fresh) = vend_and_record(\@mcs);
  is(scalar keys %$vended, 2, 'two instances vended');
  ok(-f File::Spec->catfile($dir, 'Tyleon_Water_Glyph', '7.json'), 'lcot record written');
  ok(-f File::Spec->catfile($dir, 'Toll_Booth', '8.json'), 'junk record written');
  retire_from_lists($vended, $fresh);

  my $needed = needed_set_from_vended($vended);
  my @work = classify_vended($vended, $needed, ['A' .. 'I'], {});
  my ($lcot_entry) = grep { $_->{rec}{id} == 7 } @work;
  my ($junk_entry) = grep { $_->{rec}{id} == 8 } @work;
  is($lcot_entry->{class}, 'lcot', 'lcot mission classified');
  is($lcot_entry->{rec}{lcot_letter}, 'G', 'lcot letter recorded');
  is($junk_entry->{class}, 'useless', 'junk mission classified');

  skip_useless({}, @work);
  is(scalar $client->calls_for('mission_skip'), 1, 'only the junk mission is skipped');
  my ($skip_call) = $client->calls_for('mission_skip');
  is_deeply([$skip_call->[1], $skip_call->[2]], [100, 8], 'skip via first vending building');

  my %plan_lists = (1 => { plans => [] }, 2 => { plans => [] });
  fulfill_missions([$lcot_entry], \%plan_lists);
  is(scalar $client->calls_for('send_ship'), 1, 'probe sent to the objective target');
  my ($send_call) = $client->calls_for('send_ship');
  is_deeply($send_call->[2], { x => 10, y => -20 }, 'fleet movement sent by coordinates');
  is(scalar $client->calls_for('mission_complete'), 0, 'no completion attempt with ETA pending');

  my $rec_path = File::Spec->catfile($dir, 'Tyleon_Water_Glyph', '7.json');
  my $rec = read_json_file($rec_path);
  $rec->{actions}[0]{eta} = time() - 100;
  write_json_file($rec_path, $rec);
  my $fresh_entry = {
    mission => $lcot_mission,
    rec     => read_json_file($rec_path),
    on      => $lcot_entry->{on},
    class   => 'lcot',
  };

  fulfill_missions([$fresh_entry], \%plan_lists);
  is(scalar $client->calls_for('mission_complete'), 1, 'completion attempted once the ETA passed');
  is(scalar $client->calls_for('send_ship'), 1, 'no duplicate send after arrival recorded');
  $rec = read_json_file($rec_path);
  is($rec->{status}, 'completed', 'record marked completed');

  $missions_dir = $saved_dir;
  $server_mission_dir = $saved_missions;
  $noaction     = $saved_noaction;
  $quiet        = $saved_quiet;
};

subtest 'plan class keys normalize across formats' => sub {
  plan tests => 5;
  is(plan_class_key('Halls of Vrbansk'), 'hallsofvrbansk', 'display name');
  is(plan_class_key('Lacuna::DB::Result::Building::Permanent::HallsOfVrbansk'),
     'hallsofvrbansk', 'full classname');
  is(plan_class_key('Interdimensional Rift'), 'interdimensionalrift', 'display name with irregular casing');
  is(plan_class_key('Lacuna::DB::Result::Building::Permanent::InterDimensionalRift'),
     'interdimensionalrift', 'classname matches the same key');
  ok(plan_meets_spec(
       { class_name => 'Halls of Vrbansk', level => 1, extra => 0 },
       { class_name => 'Lacuna::DB::Result::Building::Permanent::HallsOfVrbansk', level => 1, extra => 0 },
     ), 'display-name reward meets classname-file spec');
};

subtest 'needed set from mission files' => sub {
  plan tests => 9;
  my $dir = tempdir(CLEANUP => 1);
  my $saved = $server_mission_dir;
  $server_mission_dir = $dir;
  my $lcot_file = File::Spec->catfile($dir, 'fake-tyleon-food.mission');
  open(my $fh, '>', $lcot_file) or die $!;
  print {$fh} <<"END";
# config-file-type: JSON 1
{
   "name" : "Fake Tyleon Food",
   "max_university_level" : "10",
   "mission_objective" : {
      "happiness" : "10000",
      "essentia" : "10",
      "resources" : { "lapis" : 1500, "cheese" : "1500" },
      "glyphs" : [ { "type" : "anthracite", "quantity" : "1" } ],
      "ships" : [ { "type" : "dory", "quantity" : 3, "speed" : "0",
                    "stealth" : "0", "hold_size" : "0", "combat" : "0",
                    "berth_level" : "1", "name" : "" } ],
      "plans" : [ { "classname" : "Lacuna::DB::Result::Building::Permanent::HallsOfVrbansk",
                    "level" : "1", "extra_build_level" : "0", "quantity" : 2 } ]
   },
   "mission_reward" : {
      "plans" : [ { "classname" : "Lacuna::DB::Result::Building::LCOTi",
                    "extra_build_level" : "0", "level" : "1", "quantity" : 1 } ]
   }
}
END
  close $fh;
  open($fh, '>', File::Spec->catfile($dir, 'fake-other.mission')) or die $!;
  print {$fh} "{\"name\":\"Other\",\"mission_objective\":{\"resources\":{\"gold\":9999}},\"mission_reward\":{\"resources\":{\"gold\":10}}}";
  close $fh;
  open($fh, '>', File::Spec->catfile($dir, 'fake-tyleon.part2')) or die $!;
  print {$fh} "{\"name\":\"Fake Part\",\"mission_objective\":{\"resources\":{\"wheat\":40000}},\"mission_reward\":{\"plans\":[{\"classname\":\"Lacuna::DB::Result::Building::LCOTd\",\"level\":\"1\",\"extra_build_level\":\"0\",\"quantity\":1}]}}";
  close $fh;

  my @parsed = lcot_objectives_from_files();
  is(scalar @parsed, 2, 'only LCOT-rewarding files contribute (mission and partN)');
  my $needed = union_needed(@parsed);
  is($needed->{resources}{lapis},   1500, 'resource quantities numified from strings');
  is($needed->{resources}{cheese}, 1500, 'resources merged');
  is($needed->{resources}{gold},  undef, 'non-LCOT file objectives excluded');
  is($needed->{resources}{wheat}, 40000, 'partN files included');
  is($needed->{glyphs}{anthracite}, 1, 'glyphs merged');
  is_deeply($needed->{ships}[0], {
    type => 'dory', quantity => 3, speed => 0, stealth => 0,
    hold_size => 0, combat => 0, berth_level => 1,
  }, 'ship specs normalized');

  my ($class) = classify_rewards(parse_items(['500 lapis']), $needed);
  is($class, 'useful', 'food rewards match the file-seeded needed set');

  ($class) = classify_rewards(
    parse_items(['1 Halls of Vrbansk level 1 plan']), $needed);
  is($class, 'useful', 'display-name plan reward matches a classname-file spec');

  $server_mission_dir = $saved;
};

subtest 'real clone seeds the needed set' => sub {
  plan tests => 3;
  skip 'no local lacuna_server clone', 3 unless -d $server_mission_dir;
  my @parsed = lcot_objectives_from_files();
  ok(scalar @parsed >= 25, 'at least 25 known LCOT missions parsed (' . scalar @parsed . ')');
  my $needed = union_needed(@parsed);
  ok($needed->{resources}{lapis},   'LCOT food objectives include lapis');
  ok($needed->{essentia} >= 100, 'LCOT essentia objective raises the floor to at least 110');
};

sub fake_server_lib {
  my $lib = shift;
  my $result_dir = File::Spec->catfile($lib, 'Lacuna', 'DB', 'Result');
  make_path($result_dir, File::Spec->catfile($result_dir, 'Building', 'Permanent'));
  open(my $fh, '>', File::Spec->catfile($result_dir, 'Plan.pm')) or die $!;
  print {$fh} <<"END";
package Lacuna::DB::Result::Plan;
my \$recipes = {
    'Lacuna::DB::Result::Building::Permanent::Grove'              => [qw(methane)],
    'Lacuna::DB::Result::Building::Permanent::HallsOfVrbansk A'  => [qw(goethite halite gypsum trona)],
#    'Lacuna::DB::Result::Building::Permanent::CommentedOut'      => [qw(bauxite)],
    'Lacuna::DB::Result::Building::Permanent::Sand'               => [qw(bauxite)],
};
END
  close $fh;
  open($fh, '>', File::Spec->catfile($result_dir, 'Building', 'Permanent', 'FakeMeadow.pm')) or die $!;
  print {$fh} "with 'Lacuna::Role::Building::UpgradeWithHalls';\n";
  close $fh;
  open($fh, '>', File::Spec->catfile($result_dir, 'Building', 'Permanent', 'FakeOther.pm')) or die $!;
  print {$fh} "use Moose;\n";
  close $fh;
  return $lib;
}

subtest 'glyph and halls plan keys' => sub {
  plan tests => 8;
  my $saved_lib   = $server_lib_dir;
  my $saved_cache = \%glyph_halls_cache;
  $server_lib_dir = fake_server_lib(tempdir(CLEANUP => 1));
  %glyph_halls_cache = ();

  my %keys = glyph_halls_plan_keys();
  ok($keys{grove},            'glyph recipe classes are included');
  ok($keys{hallsofvrbansk},   'HallsOfVrbansk recipe variants normalize to one key');
  ok($keys{fakemeadow},       'UpgradeWithHalls consumers are included');
  ok($keys{fakeother} // 0 == 0, 'plain buildings are not included');
  is($keys{commentedout}, undef, 'commented-out recipes are skipped');

  my $hit = rewards_glyph_halls(parse_items(['1 Grove level 1 plan']));
  is($hit, 'Grove', 'display-name reward matched by normalized key');

  $hit = rewards_glyph_halls(parse_items(['1 Halls of Vrbansk level 1 plan']));
  is($hit, 'Halls of Vrbansk', 'Halls plans themselves qualify');

  $hit = rewards_glyph_halls(parse_items(['1 Lapis Pie Bakery level 1+4 plan']));
  is($hit, undef, 'unknown plan classes do not qualify');

  %glyph_halls_cache = %$saved_cache;
  $server_lib_dir = $saved_lib;
};

subtest 'classification priorities' => sub {
  plan tests => 9;
  my $saved_dir     = $missions_dir;
  my $saved_lib     = $server_lib_dir;
  my $saved_missions = $server_mission_dir;
  my $saved_cache   = \%glyph_halls_cache;
  $missions_dir = tempdir(CLEANUP => 1);
  $server_lib_dir = fake_server_lib(tempdir(CLEANUP => 1));
  $server_mission_dir = tempdir(CLEANUP => 1);
  %glyph_halls_cache = ();

  my %vended = (
    1 => { mission => { id => 1, name => 'LCOT One',
                        objectives => [], rewards => ['1 Lost City of Tyleon (A) level 1 plan'] },
           rec => { id => 1, name => 'LCOT One', status => 'active',
                    actions => [], seen_on => {} },
           on => [{ body_id => 10, building_id => 100 }] },
    2 => { mission => { id => 2, name => 'Glyph Two',
                        objectives => [], rewards => ['1 Grove level 1 plan'] },
           rec => { id => 2, name => 'Glyph Two', status => 'active',
                    actions => [], seen_on => {} },
           on => [{ body_id => 10, building_id => 100 }] },
    3 => { mission => { id => 3, name => 'Plain Three',
                        objectives => [], rewards => ['5,000 gold'] },
           rec => { id => 3, name => 'Plain Three', status => 'active',
                    actions => [], seen_on => {} },
           on => [{ body_id => 10, building_id => 100 }] },
    4 => { mission => { id => 4, name => 'Junk Four',
                        objectives => ['5,000 gold'], rewards => [] },
           rec => { id => 4, name => 'Junk Four', status => 'active',
                    actions => [], seen_on => {} },
           on => [{ body_id => 10, building_id => 100 }] },
  );
  for my $id (keys %vended) {
    $vended{$id}{rec} = record_instance($missions_dir, $vended{$id}{mission}, 10, 100);
  }
  my $needed = union_needed(parse_items(['10,000 gold']));
  my @work = classify_vended(\%vended, $needed, ['A' .. 'I'], {});
  my ($lcot)  = grep { $_->{rec}{id} == 1 } @work;
  my ($glyph) = grep { $_->{rec}{id} == 2 } @work;
  my ($plain) = grep { $_->{rec}{id} == 3 } @work;
  my ($junk)  = grep { $_->{rec}{id} == 4 } @work;

  is($lcot->{rec}{priority}, 0, 'outstanding LCOT is top priority');
  is($lcot->{class}, 'lcot', 'LCOT class');
  is($glyph->{rec}{priority}, 2, 'glyph/halls plan rewards sit one step below LCOT');
  is($glyph->{class}, 'useful', 'glyph/halls mission is kept as useful');
  like($glyph->{rec}{classification_reason}, qr/^glyph\/halls plan Grove/, 'reason names the plan');
  is($plain->{rec}{priority}, 3, 'plain useful missions come last');
  is($plain->{class}, 'useful', 'plain useful class');
  is($junk->{class}, 'useless', 'junk stays useless');
  is($junk->{rec}{priority}, 9, 'useless missions are never prioritized');

  $missions_dir = $saved_dir;
  $server_lib_dir = $saved_lib;
  $server_mission_dir = $saved_missions;
  %glyph_halls_cache = %$saved_cache;
};

subtest 'refresh_classifications' => sub {
  plan tests => 8;
  my $saved_dir = $missions_dir;
  $missions_dir = tempdir(CLEANUP => 1);

  my $ore = { id => 51, name => 'Buried in Ore', objectives => ['30,000 water'],
              rewards => ['45,000 magnetite'], max_university_level => 20,
              description => 'x', date_posted => 'y' };
  my $ore_rec = record_instance($missions_dir, $ore, 1, 10);
  $ore_rec->{classification} = 'useless';
  $ore_rec->{priority} = 9;
  $ore_rec->{classification_reason} = 'nothing in the needed set';
  write_json_file(record_path($missions_dir, $ore_rec), $ore_rec);

  my $lcot = { id => 52, name => 'Old Tyleon Thing', objectives => [],
               rewards => ['1 Lost City of Tyleon (F) level 1 plan'], max_university_level => 20,
               description => 'x', date_posted => 'y' };
  my $lcot_rec = record_instance($missions_dir, $lcot, 1, 10);
  $lcot_rec->{classification} = 'useless';
  $lcot_rec->{priority} = 9;
  write_json_file(record_path($missions_dir, $lcot_rec), $lcot_rec);

  my $needed = union_needed(parse_items(['5,000 magnetite']));
  my $changed = refresh_classifications($needed, ['A' .. 'I'], {});
  is($changed, 2, 'both stale records reclassified');

  $ore_rec = read_json_file(record_path($missions_dir, $ore_rec));
  is($ore_rec->{classification}, 'useful', 'ore mission now useful against the seeded needed set');
  is($ore_rec->{priority}, 3, 'ore mission at plain-useful priority');
  is($ore_rec->{classification_reason}, 'resource magnetite', 'reason names the match');

  $lcot_rec = read_json_file(record_path($missions_dir, $lcot_rec));
  is($lcot_rec->{classification}, 'lcot', 'retired LCOT record reclassified as lcot');
  is($lcot_rec->{priority}, 0, 'outstanding letter priority');
  is($lcot_rec->{lcot_letter}, 'F', 'letter recorded');

  $changed = refresh_classifications($needed, ['A' .. 'I'], {});
  is($changed, 0, 'second pass is a no-op');

  $missions_dir = $saved_dir;
};

sub fake_constants_lib {
  my $lib = shift;
  make_path(File::Spec->catfile($lib, 'Lacuna'));
  open(my $fh, '>', File::Spec->catfile($lib, 'Lacuna', 'Constants.pm')) or die $!;
  print {$fh} "use constant FOOD_TYPES => (qw(cheese algae));\n";
  print {$fh} "use constant ORE_TYPES => (qw(magnetite gold));\n";
  close $fh;
  return $lib;
}

subtest 'resource categories and the trade rule' => sub {
  plan tests => 10;
  my $saved_lib = $server_lib_dir;
  my (@saved_ore, @saved_food);
  $server_lib_dir = fake_constants_lib(tempdir(CLEANUP => 1));
  @saved_ore  = @ore_types;
  @saved_food = @food_types;
  @ore_types  = ();
  @food_types = ();

  is(resource_category('magnetite'), 'ore',  'ore type categorized');
  is(resource_category('cheese'),    'food', 'food type categorized');
  is(resource_category('water'),     'water', 'water categorized');
  is(resource_category('unobtanium'), undef, 'unknown resource uncategorized');

  my %context = (
    prioritized_consumed => { water => 1, cheese => 1 },
    rates => { water => 500, ore => 2000, food => 5000, energy => 0, waste => 0 },
  );

  ok(trade_useless(parse_items(['45,000 magnetite']), parse_items(['30,000 water']), \%context),
     'water-for-ore trade is bad when ore outproduces water');
  ok(!trade_useless(parse_items(['45,000 magnetite']), parse_items(['30,000 water']),
      { %context, rates => { water => 5000, ore => 200, food => 500, energy => 0, waste => 0 } }),
     'same trade is fine when water is the faster category');
  ok(!trade_useless(parse_items(['45,000 magnetite']), parse_items(['30,000 gold']), \%context),
     'unprioritized consumed resource leaves the rule inert');
  ok(!trade_useless(
      parse_items(['45,000 magnetite', '    1 Dory (speed: 1, stealth: 0, hold size: 0, combat: 0, berth: 1)']),
      parse_items(['30,000 water']), \%context),
     'ship rewards make it not a pure trade');
  ok(!trade_useless(parse_items(['5,000 algae']), parse_items(['5,000 cheese']), \%context),
     'same-category trades are never slower');
  ok(trade_useless(parse_items(['5,000 cheese']), parse_items(['30,000 water']), \%context),
     'water-for-food trade is bad when food outproduces water');

  @ore_types  = @saved_ore;
  @food_types = @saved_food;
  $server_lib_dir = $saved_lib;
};

subtest 'prioritized consumed resources' => sub {
  plan tests => 4;
  my $saved_missions = $server_mission_dir;
  my $saved_lib      = $server_lib_dir;
  my $saved_cache    = \%glyph_halls_cache;
  $server_mission_dir = tempdir(CLEANUP => 1);
  $server_lib_dir = fake_server_lib(tempdir(CLEANUP => 1));
  %glyph_halls_cache = ();

  open(my $fh, '>', File::Spec->catfile($server_mission_dir, 'lcot-water.mission')) or die $!;
  print {$fh} '{"name":"LCOT Water","mission_objective":{"resources":{"water":25000}},'
            . '"mission_reward":{"plans":[{"classname":"Lacuna::DB::Result::Building::LCOTd","level":"1","extra_build_level":"0","quantity":1}]}}';
  close $fh;
  open($fh, '>', File::Spec->catfile($server_mission_dir, 'grove-cheese.mission')) or die $!;
  print {$fh} '{"name":"Grove Cheese","mission_objective":{"resources":{"cheese":40000}},'
            . '"mission_reward":{"plans":[{"classname":"Lacuna::DB::Result::Building::Permanent::Grove","level":"1","extra_build_level":"0","quantity":1}]}}';
  close $fh;
  open($fh, '>', File::Spec->catfile($server_mission_dir, 'plain-gold.mission')) or die $!;
  print {$fh} '{"name":"Plain Gold","mission_objective":{"resources":{"gold":10000}},'
            . '"mission_reward":{"resources":{"cheese":10}}}';
  close $fh;

  my $consumed = prioritized_consumed_resources({});
  ok($consumed->{water},  'LCOT mission resources are prioritized consumption');
  ok($consumed->{cheese}, 'glyph/halls mission resources are prioritized consumption');
  ok(!$consumed->{gold},   'plain missions do not mark their resources');

  my %vended = (
    9 => { mission => { id => 9, name => 'Live LCOT',
                       objectives => ['1,000 lapis'],
                       rewards => ['1 Lost City of Tyleon (B) level 1 plan'] } },
  );
  $consumed = prioritized_consumed_resources(\%vended);
  ok($consumed->{lapis}, 'vended LCOT instances add their consumed resources');

  $server_mission_dir = $saved_missions;
  $server_lib_dir = $saved_lib;
  %glyph_halls_cache = %$saved_cache;
};

subtest 'bad trade classifies useless and skips' => sub {
  plan tests => 8;
  my $saved_dir      = $missions_dir;
  my $saved_missions = $server_mission_dir;
  my $saved_lib      = $server_lib_dir;
  $missions_dir = tempdir(CLEANUP => 1);
  $server_mission_dir = tempdir(CLEANUP => 1);
  $server_lib_dir = fake_constants_lib(fake_server_lib(tempdir(CLEANUP => 1)));
  @ore_types = ();
  @food_types = ();
  %glyph_halls_cache = ();

  my %vended = (
    7 => { mission => { id => 7, name => 'Buried in Ore',
                        objectives => ['30,000 water'],
                        rewards => ['45,000 magnetite'],
                        max_university_level => 20, description => 'x', date_posted => 'y' },
           rec => undef, on => [{ body_id => 10, building_id => 100 }] },
  );
  $vended{7}{rec} = record_instance($missions_dir, $vended{7}{mission}, 10, 100);
  my $needed = union_needed(parse_items(['5,000 magnetite']));
  my $context = {
    prioritized_consumed => { water => 1 },
    rates => { water => 500, ore => 2000, food => 5000, energy => 0, waste => 0 },
  };
  my @work = classify_vended(\%vended, $needed, ['A' .. 'I'], $context);
  my ($entry) = @work;
  is($entry->{class}, 'useless', 'needed-reward trade still useless when it drains a scarcer needed resource');
  is($entry->{rec}{priority}, 9, 'bad trade never prioritized');
  like($entry->{rec}{classification_reason}, qr/^bad trade: consumes needed water/,
       'reason names the trade imbalance');

  ok(should_skip('useless', parse_items(['45,000 magnetite']), parse_items(['30,000 water']), $context),
     'bad trades are skippable');
  ok(!should_skip('useless', parse_items(['45,000 magnetite']), parse_items(['30,000 water']),
      { %$context, rates => { water => 5000, ore => 200, food => 500, energy => 0, waste => 0 } }),
     'good trades are not skipped');

  my $rec_path = record_path($missions_dir, { name => 'Buried in Ore', id => 7 });
  my $stale = read_json_file($rec_path);
  $stale->{classification} = 'useful';
  $stale->{priority} = 3;
  $stale->{classification_reason} = 'resource magnetite';
  write_json_file($rec_path, $stale);

  my $changed = refresh_classifications($needed, ['A' .. 'I'], $context);
  is($changed, 1, 'record refresh also applies the trade rule');
  my $rec = read_json_file($rec_path);
  is($rec->{classification}, 'useless', 'refreshed record is useless');
  is($rec->{classification_reason}, $entry->{rec}{classification_reason},
     'refreshed record carries the bad-trade reason');

  $missions_dir = $saved_dir;
  $server_mission_dir = $saved_missions;
  $server_lib_dir = $saved_lib;
};

done_testing();
