use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

our $script;

BEGIN {
  $script = abs_path(File::Spec->catfile(dirname(__FILE__), '..', 'missionary.pl'));
  unshift @INC, dirname($script);
}
require $script;

our ($noaction, $quiet, $missions_dir, $debug, $copies_goal, $copies_keep, $list_at);

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

done_testing();
