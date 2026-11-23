use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);
use File::Temp qw(tempfile);

our $script;

BEGIN {
  $script = abs_path(File::Spec->catfile(dirname(__FILE__), '..', 'build_queue.pl'));
  unshift @INC, dirname($script);
}
require $script;

our ($config_name, $body_name, $queue_name, $debug, $quiet_no_body, $no_wait,
     $client, $body_id, $buildings, $buildable, $abort, $sleepy,
     @queue, @builds, %foods);

# --- FakeClient --------------------------------------------------------------

package FakeClient;

our $AUTOLOAD;

sub new {
  my ($class, %args) = @_;
  my $self = bless { calls => [], responses => $args{responses} || {} }, $class;
  return $self;
}

sub calls {
  my $self = shift;
  return $self->{calls};
}

sub calls_for {
  my ($self, $method) = @_;
  return grep { $_->[0] eq $method } @{$self->{calls}};
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

# --- helpers -------------------------------------------------------------------

sub capture (&) {
  my $code = shift;
  my $buf = '';
  open(my $out, '>', \$buf) or die "Can't capture output: $!";
  my $old = select $out;
  $code->();
  select $old;
  close $out;
  return $buf;
}

sub reset_state {
  my (%args) = @_;
  $abort = undef;
  @builds = ();
  $buildable = undef;
  $body_id = 'testbody42';
  $body_name = 'TestBody';
  $sleepy = 0;
  $debug = 0;
  $main::last_message = undef;
  my ($fh, $name) = tempfile();
  close $fh;
  $queue_name = $name;
  @queue = @{$args{queue} || []};
  write_queue();
  return $name;
}

sub read_queue_file {
  open(my $in, '<', $queue_name) or die "Can't read $queue_name: $!";
  my $content = do { local $/; <$in> };
  close $in;
  return $content;
}

sub default_status {
  return {
    food_stored   => 10000, food_hour   => 100, food_capacity   => 20000,
    ore_stored    => 10000, ore_hour    => 100, ore_capacity    => 20000,
    water_stored  => 10000, water_hour  => 100, water_capacity  => 20000,
    energy_stored => 0,     energy_hour => 10,  energy_capacity => 20000,
    waste_hour    => 5,
  };
}

sub make_building {
  my (%args) = @_;
  my $b = {
    id         => $args{id},
    name       => $args{name},
    level      => $args{level} // 1,
    x          => $args{x} // 0,
    y          => $args{y} // 0,
    url        => $args{url} // "/$args{name}",
    efficiency => $args{efficiency} // 100,
    upgrade    => $args{upgrade},
  };
  for my $type (qw(food ore water energy waste)) {
    $b->{"${type}_hour"} = $args{"${type}_hour"} // 0;
  }
  return $b;
}

sub modest_cost {
  my (%args) = @_;
  return { food => $args{food} // 100, ore => $args{ore} // 100,
           water => $args{water} // 100, energy => $args{energy} // 0,
           time => $args{time} // 3600 };
}

sub stats_client {
  my (%args) = @_;
  my $stats = $args{stats};
  return FakeClient->new(responses => {
    body_status => sub { $args{status} },
    building_stats_for_level => sub {
      my (undef, $url, $id, $level) = @_;
      return { building => $stats->{$id} || {} };
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
    building_upgrade => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });
}

sub denied_client {
  my (%args) = @_;
  my $stats = $args{stats};
  return FakeClient->new(responses => {
    body_status => sub { $args{status} },
    building_stats_for_level => sub {
      my (undef, $url, $id, $level) = @_;
      return { building => $stats->{$id} || {} };
    },
    building_view_cached => { building => { upgrade => { can => 0, reason => ['code', 'It forms naturally.'] } } },
  });
}

sub end_after {
  my $seconds = shift;
  my @t = gmtime(time() + $seconds);
  return sprintf('%02d %02d %04d %02d:%02d:%02d +0000',
                 $t[3], $t[4] + 1, $t[5] + 1900, $t[2], $t[1], $t[0]);
}

ok(defined &main::run_queue, 'script loads without running the main flow');

# --- parse_command_flags ----------------------------------------------------------

subtest 'parse_command_flags' => sub {
  $abort = undef;
  my ($cmd, $f) = parse_command_flags("upgrade <9 University\n");
  is($cmd, 'upgrade <9 University', 'plain command');
  ok(!$f->{quiet} && !$f->{retain} && !$f->{rebuild} && !$f->{requeue}, 'no flags');
  is($f->{priority}, '', 'plain command has no priority');

  ($cmd, $f) = parse_command_flags("-upgrade <9 University\n");
  is($cmd, 'upgrade <9 University', 'dash stripped');
  ok($f->{quiet}, '- prefix sets quiet');

  ($cmd, $f) = parse_command_flags("*upgrade <9 Capitol\n");
  ok($f->{retain}, '* prefix sets retain');

  ($cmd, $f) = parse_command_flags("++build Capitol\n");
  ok($f->{rebuild}, '++ prefix sets rebuild');
  ok(!$f->{requeue}, '++ does not set requeue');

  ($cmd, $f) = parse_command_flags("+build Capitol\n");
  ok($f->{requeue}, '+ prefix sets requeue');
  ok(!$f->{rebuild}, '+ does not set rebuild');

  $abort = undef;
  ($cmd, $f) = parse_command_flags("!build Capitol\n");
  ok($abort, '! prefix sets the shared abort flag');
  is($f->{priority}, '!', 'abort command carries priority');

  ($cmd, $f) = parse_command_flags("-*upgrade <9 University\n");
  ok($f->{quiet} && $f->{retain}, 'combined -* prefixes');

  ($cmd, $f) = parse_command_flags("wait quietly until 2099\n");
  ok($f->{quiet}, 'wait quietly alias becomes a quiet wait');
  is($cmd, 'wait until 2099', 'wait quietly leaves the until clause');

  # flag order does not matter
  ($cmd, $f) = parse_command_flags("-!build Capitol\n");
  is($cmd, 'build Capitol', '-! both stripped');
  ok($f->{quiet}, '-! sets quiet');

  $abort = undef;
  ($cmd, $f) = parse_command_flags("!-build -4 1 Water Reclamation Facility\n");
  is($cmd, 'build -4 1 Water Reclamation Facility', '!- both stripped');
  ok($f->{quiet}, '!- sets quiet');
  ok($abort, '!- sets abort');
  is($f->{priority}, '!', '!- carries priority');

  $abort = undef;
  ($cmd, $f) = parse_command_flags("++!build Capitol\n");
  is($cmd, 'build Capitol', '++! all stripped');
  ok($f->{rebuild} && !$f->{requeue} && $abort, '++! sets rebuild and abort');

  $abort = undef;
  ($cmd, $f) = parse_command_flags("!++build Capitol\n");
  is($cmd, 'build Capitol', '!++ all stripped');
  ok($f->{rebuild} && !$f->{requeue} && $abort, '!++ sets rebuild and abort');

  ($cmd, $f) = parse_command_flags("*+build Capitol\n");
  is($cmd, 'build Capitol', '*+ all stripped');
  ok($f->{retain} && $f->{requeue} && !$f->{rebuild}, '*+ sets retain and requeue');

  ($cmd, $f) = parse_command_flags("+*build Capitol\n");
  is($cmd, 'build Capitol', '+* all stripped');
  ok($f->{retain} && $f->{requeue} && !$f->{rebuild}, '+* sets retain and requeue');

  ($cmd, $f) = parse_command_flags("--build Capitol\n");
  is($cmd, 'build Capitol', 'repeated dashes stripped');
  ok($f->{quiet}, 'repeated dashes set quiet once');

  $abort = undef;
  ($cmd, $f) = parse_command_flags("!-!build Capitol\n");
  is($cmd, 'build Capitol', 'repeated flags stripped');
  ok($f->{quiet} && $abort, 'repeated flags set quiet and abort');

  # a prefixed wait quietly no longer double-dashes into a dead line
  ($cmd, $f) = parse_command_flags("-wait quietly until 2099\n");
  ok($f->{quiet}, 'prefixed wait quietly stays a quiet wait');
  is($cmd, 'wait until 2099', 'prefixed wait quietly parses');
  done_testing();
};

# --- duration -----------------------------------------------------------------------

subtest 'duration' => sub {
  is(duration(0), '', 'zero renders empty');
  is(duration(45), '45s', 'seconds only');
  is(duration(3661), '1h 1m 1s', 'hours minutes seconds');
  is(duration(90061), '1d 1h 1m 1s', 'days hours minutes seconds');
  is(duration(main::EFFECTIVELY_NEVER()), '60d', 'sixty day sentinel');
  is(duration(-5), '', 'negative renders empty (historical)');
  done_testing();
};

# --- emit ---------------------------------------------------------------------------

subtest 'emit' => sub {
  $body_name = 'TestBody';
  $main::last_message = undef;
  my $out = capture { emit('hello'); emit('hello'); emit('world'); };
  my $hello = () = $out =~ /: hello/g;
  my $world = () = $out =~ /: world/g;
  is($hello, 1, 'duplicate message suppressed');
  is($world, 1, 'changed message emitted');
  like($out, qr/^.*TestBody: hello/, 'message carries body name');
  done_testing();
};

# --- write_queue ----------------------------------------------------------------------

subtest 'write_queue' => sub {
  my $name = reset_state(queue => ["one\n", "-two\n", "three\n"]);
  is(read_queue_file(), "one\n-two\nthree\n", 'queue written verbatim');
  ok(!-e "$name.$$", 'temporary queue file renamed away');
  done_testing();
};

# --- upgrade_check ----------------------------------------------------------------------

subtest 'upgrade_check' => sub {
  my $cost = modest_cost(energy => 100);
  my $building = make_building(
    id => 1, name => 'Mine', level => 5, energy_hour => 0,
    upgrade => { cost => $cost, production => { energy_hour => 0 } });

  is(upgrade_check(undef), 'Undefined building.', 'undefined building');

  $building->{efficiency} = 80;
  like(upgrade_check($building), qr/repair before upgrading/, 'low efficiency blocks');

  my $status = default_status();
  $client = stats_client(status => $status,
                         stats => { 1 => { upgrade => $building->{upgrade} } });
  $buildings = { buildings => { 1 => { %$building } } };
  $building->{efficiency} = 100;

  $status->{energy_capacity} = 50;
  like(upgrade_check($building), qr/^Not enough capacity.*energy \(50\/100\)/, 'capacity shortfall reported');

  $status->{energy_capacity} = 20000;
  $status->{energy_stored} = 40;
  $status->{energy_hour} = 10;
  like(upgrade_check($building), qr/energy \(40\/100, 6h\)/, 'wait computed from hourly rate');

  $status->{energy_hour} = 0;
  like(upgrade_check($building), qr/energy \(40\/100, 60d\)/, 'zero rate marked as 60 days');

  $status->{energy_hour} = -5;
  like(upgrade_check($building), qr/energy \(40\/100, 60d\)/, 'negative rate marked as 60 days');

  # depot fills the shortfall when side effects are allowed
  $status->{energy_hour} = 10;
  my $cost_big = modest_cost(energy => 8000);
  $building->{upgrade} = { cost => $cost_big, production => { energy_hour => 0 } };
  my $transmits = 0;
  $client = FakeClient->new(responses => {
    body_status => sub {
      my %s = (%$status);
      $s{energy_stored} += 3600 * $transmits;
      return \%s;
    },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => $cost_big, production => { energy_hour => 0 } } } }
    },
    depot_transmit => sub {
      $transmits++;
      return { building => { work => { seconds_remaining => 7200 } } };
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
  });
  $buildings = { buildings => {
    1 => { %$building },
    99 => { id => 99, url => '/subspacesupplydepot', work => { seconds_remaining => 7200 } },
  } };
  my $message = upgrade_check($building, 1);
  is($transmits, 3, 'depot called until stored covers the cost');
  unlike($message, qr/Not enough/, 'depot transmissions satisfied the shortfall');

  # depot with under an hour of work left: no transmissions, shortfall reported
  $transmits = 0;
  $client = FakeClient->new(responses => {
    body_status => sub {
      my %s = (%$status);
      $s{energy_stored} += 3600 * $transmits;
      return \%s;
    },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => $cost_big, production => { energy_hour => 0 } } } }
    },
    depot_transmit => sub {
      $transmits++;
      return { building => { work => { seconds_remaining => 7200 } } };
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
  });
  $buildings = { buildings => {
    1 => { %$building },
    99 => { id => 99, url => '/subspacesupplydepot', work => { seconds_remaining => 100 } },
  } };
  $message = upgrade_check($building, 1);
  is($transmits, 0, 'no depot pull with under an hour of work left');
  like($message, qr/energy \(40\/8000,/, 'shortfall reported without the depot');

  # storage too full for a depot pull: shortfall reported without transmitting
  $status->{energy_capacity} = 4000;
  $status->{energy_stored} = 3600;
  my $cost_mid = modest_cost(energy => 3900);
  $building->{upgrade} = { cost => $cost_mid, production => { energy_hour => 0 } };
  $transmits = 0;
  $buildings = { buildings => {
    1 => { %$building },
    99 => { id => 99, url => '/subspacesupplydepot', work => { seconds_remaining => 7200 } },
  } };
  $client = FakeClient->new(responses => {
    body_status => sub { $status },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => $cost_mid, production => { energy_hour => 0 } } } }
    },
    depot_transmit => sub {
      $transmits++;
      return { building => { work => { seconds_remaining => 7200 } } };
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
  });
  $message = upgrade_check($building, 1);
  is($transmits, 0, 'no depot pull when storage is near capacity');
  like($message, qr/energy \(3600\/3900,/, 'shortfall reported despite the depot');

  # depot work running low mid-fill: partial pulls then the shortfall reported
  $status->{energy_capacity} = 25000;
  $status->{energy_stored} = 40;
  my $cost_huge = modest_cost(energy => 20000);
  $building->{upgrade} = { cost => $cost_huge, production => { energy_hour => 0 } };
  $transmits = 0;
  $buildings = { buildings => {
    1 => { %$building },
    99 => { id => 99, url => '/subspacesupplydepot', work => { seconds_remaining => 7200 } },
  } };
  $client = FakeClient->new(responses => {
    body_status => sub {
      my %s = (%$status);
      $s{energy_stored} += 3600 * $transmits;
      return \%s;
    },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => $cost_huge, production => { energy_hour => 0 } } } }
    },
    depot_transmit => sub {
      $transmits++;
      return { building => { work => { seconds_remaining => 7200 - 1800 * $transmits } } };
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
  });
  $message = upgrade_check($building, 1);
  is($transmits, 3, 'depot pulls stop when the work runs low');
  like($message, qr/energy \(10840\/20000,/, 'partial depot fill still reports the shortfall');

  # unsustainability pre-check
  my $drain = make_building(
    id => 2, name => 'Ore Storage Tanks', level => 5, energy_hour => 10,
    upgrade => { cost => modest_cost(energy => 1), production => { energy_hour => -5 } });
  $client = stats_client(status => $status, stats => { 2 => { upgrade => $drain->{upgrade} } });
  $buildings = { buildings => { 2 => { %$drain } } };
  like(upgrade_check($drain), qr/Unsustainable \(local pre-check\).*energy \(-5\/hour post-upgrade\)/,
        'post-upgrade drain reported');

  # server-side denial passthrough
  $client = FakeClient->new(responses => {
    body_status => sub { default_status() },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => modest_cost(), production => {} } } }
    },
    building_view_cached => { building => { upgrade => { can => 0, reason => ['code', 'It forms naturally.'] } } },
  });
  $buildings = { buildings => { 1 => { %$building } } };
  is(upgrade_check($building), 'It forms naturally.', 'building_view denial returned verbatim');
  done_testing();
};

# --- attempt_upgrade ---------------------------------------------------------------------

subtest 'attempt_upgrade' => sub {
  reset_state();
  my $b = make_building(id => 5, name => 'Mine', level => 5, url => '/mine',
    upgrade => { cost => modest_cost(), production => {} });

  $client = stats_client(status => default_status(), stats => {});
  $buildings = { buildings => { 5 => $b } };
  my ($up, $msg) = attempt_upgrade($b);
  ok($up && !$msg, 'successful upgrade returns the result');
  my @c = $client->calls_for('building_upgrade');
  is_deeply($c[0], ['building_upgrade', '/mine', 5], 'upgrade called with url and id');

  $client = FakeClient->new(responses => {
    body_status => sub { default_status() },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => modest_cost(), production => {} } } }
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
    building_upgrade => sub { LacunaRPCException->throw(code => 1005, text => 'Not enough resources.') },
  });
  ($up, $msg) = attempt_upgrade($b);
  is($msg, 'Not enough resources.', 'denial text returned');
  my @cache_calls = $client->calls_for('cache_building_denial');
  is_deeply($cache_calls[0], ['cache_building_denial', 5, 1005, 'Not enough resources.'], 'denial cached');

  $client = FakeClient->new(responses => {
    body_status => sub { default_status() },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => modest_cost(), production => {} } } }
    },
    building_view_cached => { building => { upgrade => { can => 1 } } },
    building_upgrade => sub { die "boom\n" },
  });
  my $died = '';
  eval { attempt_upgrade($b); 1 } or $died = $@;
  like($died, qr/boom/, 'non-RPC exceptions rethrown');
  done_testing();
};

# --- cmd_wait ------------------------------------------------------------------------------

subtest 'cmd_wait' => sub {
  reset_state(queue => ["wait 2000-01-01\n", "build Capitol\n"]);
  is(cmd_wait(0, '2000-01-01', { quiet => 0 }), 'advance', 'past wait advances');
  is_deeply(\@queue, ["build Capitol\n"], 'expired wait removed');
  is(read_queue_file(), "build Capitol\n", 'queue file rewritten');

  reset_state(queue => ["wait 2099-01-01\n", "build Capitol\n"]);
  is(cmd_wait(0, '2099-01-01', { quiet => 0 }), 'stop', 'future wait stops the run');
  is_deeply(\@queue, ["-wait 2099-01-01\n", "build Capitol\n"], 'future wait marked quiet');
  is(read_queue_file(), "-wait 2099-01-01\nbuild Capitol\n", 'marked wait persisted');

  reset_state(queue => ["wait 2099-01-01\n"]);
  is(cmd_wait(0, '2099-01-01', { quiet => 1 }), 'stop', 'quiet future wait stops the run');
  is($queue[0], "wait 2099-01-01\n", 'quiet wait leaves the queue line alone');

  # unparseable date behaves as expired: marked then removed
  reset_state(queue => ["wait flobschnizzle\n", "build Capitol\n"]);
  is(cmd_wait(0, 'flobschnizzle', { quiet => 0 }), 'advance', 'unparseable date treated as expired');
  is_deeply(\@queue, ["build Capitol\n"], 'garbage wait removed after marking');
  done_testing();
};

# --- cmd_demolish --------------------------------------------------------------------------

subtest 'cmd_demolish' => sub {
  reset_state();
  $client = FakeClient->new();

  $buildings = { buildings => {} };
  @queue = ("demolish Mine\n");
  is(cmd_demolish(0, 'Mine', { quiet => 0 }), 'advance', 'missing target advances');
  is($queue[0], "-demolish Mine\n", 'failed demolish marked quiet');

  my $mine = make_building(id => 7, name => 'Mine', level => 5, x => 3, y => 4, url => '/mine');
  $buildings = { buildings => { 7 => $mine } };
  @queue = ("-demolish Mine\n", "-upgrade <9 University\n");
  is(cmd_demolish(0, 'Mine', { quiet => 1 }), 'reprocess', 'successful demolish reprocesses');
  is_deeply(\@queue, ["upgrade <9 University\n"], 'command removed and other lines unmarked');
  my @c = $client->calls_for('building_demolish');
  is_deeply($c[0], ['building_demolish', '/mine', 7], 'demolish called with url and id');

  @builds = ('Mine');
  @queue = ("demolish Mine\n");
  is(cmd_demolish(0, 'Mine', { quiet => 0 }), 'advance', 'building in progress skips demolish');
  is($queue[0], "demolish Mine\n", 'queue untouched while building');

  @builds = ();
  my $low  = make_building(id => 8, name => 'Mine', level => 3, x => 1, y => 1, url => '/mine3');
  my $high = make_building(id => 9, name => 'Mine', level => 5, x => -1, y => -2, url => '/mine5');
  $buildings = { buildings => { 8 => $low, 9 => $high } };
  $client = FakeClient->new();
  @queue = ("demolish 3 Mine\n");
  cmd_demolish(0, '3 Mine', { quiet => 1 });
  is(($client->calls_for('building_demolish'))[0]->[2], 8, 'level filter picks the level 3 mine');

  $client = FakeClient->new();
  @queue = ("demolish -1 -2 Mine\n");
  cmd_demolish(0, '-1 -2 Mine', { quiet => 1 });
  is(($client->calls_for('building_demolish'))[0]->[2], 9, 'coordinate filter picks the matching mine');

  # zero coordinates are treated as no filter at all
  my $far = make_building(id => 50, name => 'Mine', level => 3, x => 5, y => 5, url => '/mineA');
  my $near = make_building(id => 51, name => 'Mine', level => 7, x => 6, y => 6, url => '/mineB');
  $buildings = { buildings => { 50 => $far, 51 => $near } };
  $client = FakeClient->new();
  @queue = ("demolish 0 0 Mine\n");
  cmd_demolish(0, '0 0 Mine', { quiet => 1 });
  is(($client->calls_for('building_demolish'))[0]->[2], 50, 'zero coordinates leave the level sort to pick');
  done_testing();
};

# --- cmd_build ------------------------------------------------------------------------------

subtest 'cmd_build' => sub {
  reset_state();
  $client = FakeClient->new(responses => {
    body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });

  $buildable = { buildable => { 'Capitol' => { build => { can => 0, reason => ['x', 'Needs a body.'] } } } };
  @queue = ("build Capitol\n");
  is(cmd_build(0, 'Capitol', { quiet => 0 }), 'advance', 'denied build advances');
  is($queue[0], "-build Capitol\n", 'denied build marked quiet');
  is(scalar $client->calls_for('body_build'), 0, 'no build RPC when denied');

  $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
  @queue = ("build Capitol\n");
  is(cmd_build(0, 'Capitol', { quiet => 0 }), 'reprocess', 'successful build reprocesses');
  is_deeply(\@queue, [], 'built command removed');
  my @c = $client->calls_for('body_build');
  is_deeply($c[-1], ['body_build', 'testbody42', 'Capitol', undef, undef], 'build called with body and name, no coords');
  is_deeply(\@builds, ['Capitol'], 'build recorded');

  @builds = ();
  @queue = ("*build Capitol\n");
  cmd_build(0, 'Capitol', { quiet => 0, retain => 1 });
  is_deeply(\@queue, ["*build Capitol\n"], 'retained build command kept');

  @builds = ();
  @queue = ("++build Capitol\n");
  cmd_build(0, 'Capitol', { quiet => 0, rebuild => 1, priority => '' });
  is_deeply(\@queue, ["++upgrade 1 Capitol\n"], 'rebuild requeues an upgrade at the front');

  @builds = ();
  @queue = ("+build Capitol\n");
  cmd_build(0, 'Capitol', { quiet => 0, requeue => 1 });
  is_deeply(\@queue, ["+upgrade 1 Capitol\n"], 'requeue appends an upgrade to the back');

  @builds = ('Mine');
  @queue = ("build Capitol\n");
  cmd_build(0, 'Capitol', { quiet => 0 });
  is(scalar $client->calls_for('body_build'), 4, 'no further builds while a build is in progress');

  $buildable = { buildable => { 'Temple of Tyleon' => { build => { can => 0, reason => [undef, 'Lost City of Tyleon requires all 11 buildings.'] } } } };
  @builds = ();
  @queue = ("build Temple of Tyleon\n");
  cmd_build(0, 'Temple of Tyleon', { quiet => 1 });
  is(scalar $client->calls_for('body_build'), 5, 'Tyleon reason permits the build attempt');

  $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
  $client = FakeClient->new(responses => {
    body_build => sub { LacunaRPCException->throw(code => 1010, text => 'Too many requests today.') },
  });
  @builds = ();
  @queue = ("build Capitol\n");
  my $out = capture { cmd_build(0, 'Capitol', { quiet => 0 }) };
  like($out, qr/Couldn't build Capitol: 1010/, 'RPC failure reported');
  is_deeply(\@queue, ["build Capitol\n"], 'failed build command retained');

  # unknown building name reports instead of crashing the run
  $buildable = { buildable => {} };
  @builds = ();
  @queue = ("build Flurb Factory\n");
  my $sig = cmd_build(0, 'Flurb Factory', { quiet => 0 });
  is($sig, 'advance', 'unknown building advances');
  is($queue[0], "-build Flurb Factory\n", 'unknown build marked quiet');
  is(scalar $client->calls_for('body_build'), 1, 'no build RPC for an unknown name');

  # buildable is fetched once and cached across commands
  $buildable = undef;
  $client = FakeClient->new(responses => {
    body_buildable => { buildable => { 'Capitol' => { build => { can => 1 } } } },
    body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });
  for (1, 2) {
    @builds = ();
    @queue = ("build Capitol\n");
    cmd_build(0, 'Capitol', { quiet => 1 });
  }
  is(scalar $client->calls_for('body_buildable'), 1, 'buildable fetched once and cached');

  # coordinate variant passes x and y through to the RPC
  $buildable = { buildable => { 'Park' => { build => { can => 1 } } } };
  @builds = ();
  @queue = ("build 3 4 Park\n");
  cmd_build(0, '3 4 Park', { quiet => 1 });
  my @xy = $client->calls_for('body_build');
  is_deeply($xy[-1], ['body_build', 'testbody42', 'Park', 3, 4], 'coordinates parsed and passed');
  done_testing();
};

# --- cmd_upgrade -----------------------------------------------------------------------------

subtest 'cmd_upgrade' => sub {
  reset_state();
  my $mine = make_building(id => 7, name => 'Mine', level => 5, url => '/mine',
    upgrade => { cost => modest_cost(), production => { ore_hour => 10 } });
  $buildings = { buildings => { 7 => $mine } };
  $client = stats_client(status => default_status(), stats => { 7 => { upgrade => $mine->{upgrade} } });

  @queue = ("upgrade 5 Mine\n");
  is(cmd_upgrade(0, '', 5, 'Mine', { quiet => 0 }), 'reprocess', 'exact level match succeeds');
  is_deeply(\@queue, [], 'completed upgrade removed');
  is_deeply(\@builds, ['Mine'], 'build recorded');
  my @c = $client->calls_for('building_upgrade');
  is_deeply($c[-1], ['building_upgrade', '/mine', 7], 'upgrade called for the matched building');

  @builds = ();
  @queue = ("upgrade <9 Mine\n");
  cmd_upgrade(0, '<', 9, 'Mine', { quiet => 0 });
  ok((grep { $_->[0] eq 'building_upgrade' } @{$client->calls}), 'upTo matches lower levels');

  @builds = ();
  $client = FakeClient->new(responses => {
    body_status => sub { default_status() },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => modest_cost(), production => { ore_hour => 10 } } } }
    },
    building_view_cached => { building => { upgrade => { can => 0, reason => ['c', 'It forms naturally.'] } } },
  });
  @queue = ("upgrade 5 Mine\n");
  is(cmd_upgrade(0, '', 5, 'Mine', { quiet => 0 }), 'advance', 'denied upgrade advances');
  is($queue[0], "-upgrade 5 Mine\n", 'denied upgrade marked');

  $mine->{level} = 30;
  @queue = ("upgrade 30 Mine\n");
  is(cmd_upgrade(0, '', 30, 'Mine', { quiet => 0 }), 'advance', 'level 30 buildings never match');
  is($queue[0], "upgrade 30 Mine\n", 'unmatched upgrade left alone');
  $mine->{level} = 5;

  $client = stats_client(status => default_status(), stats => { 7 => { upgrade => $mine->{upgrade} } });
  @builds = ();
  @queue = ("*upgrade <9 Mine\n");
  cmd_upgrade(0, '<', 9, 'Mine', { quiet => 0, retain => 1 });
  is_deeply(\@queue, ["*upgrade <9 Mine\n"], 'retained upgrade kept');

  @builds = ();
  @queue = ("+upgrade 5 Mine\n");
  cmd_upgrade(0, '', 5, 'Mine', { quiet => 0, requeue => 1 });
  is_deeply(\@queue, ["+upgrade 6 Mine\n"], 'requeue targets the next level');

  my $temple = make_building(id => 11, name => 'Temple of Tyleon', level => 3, url => '/temple',
    upgrade => { cost => modest_cost(), production => {} });
  my $lost = make_building(id => 12, name => 'Lost City of Tyleon', level => 1, url => '/lost',
    upgrade => { cost => modest_cost(), production => {} });
  $buildings = { buildings => { 11 => $temple, 12 => $lost } };
  $client = stats_client(status => default_status(),
                         stats => { 11 => { upgrade => $temple->{upgrade} },
                                    12 => { upgrade => $lost->{upgrade} } });
  @builds = ();
  @queue = ("upgrade 5 Tyleon\n");
  cmd_upgrade(0, '', 5, 'Tyleon', { quiet => 0 });
  my @tc = $client->calls_for('building_upgrade');
  is($tc[-1]->[2], 12, 'Tyleon alias upgrades the lowest Tyleon building');

  # with an upTo marker the alias rewrites the level to the lowest building's
  # own level, which can never satisfy the < test: the command no-ops
  @builds = ();
  @queue = ("upgrade <5 Tyleon\n");
  cmd_upgrade(0, '<', 5, 'Tyleon', { quiet => 0 });
  is_deeply(\@queue, ["upgrade <5 Tyleon\n"], 'upTo Tyleon alias with no match leaves the queue alone');

  # falsy level matches any building below 30
  $buildings = { buildings => { 7 => $mine } };
  $client = stats_client(status => default_status(), stats => { 7 => { upgrade => $mine->{upgrade} } });
  @builds = ();
  @queue = ("upgrade 0 Mine\n");
  cmd_upgrade(0, '', 0, 'Mine', { quiet => 1 });
  my @zc = $client->calls_for('building_upgrade');
  ok(@zc && $zc[-1]->[2] == 7, 'falsy level matches the only mine');

  # Tyleon alias with no Tyleon buildings silently no-ops
  $buildings = { buildings => { 7 => $mine } };
  @builds = ();
  @queue = ("upgrade 5 Tyleon\n");
  is(cmd_upgrade(0, '', 5, 'Tyleon', { quiet => 1 }), 'advance', 'missing Tyleon buildings no-op');
  is_deeply(\@queue, ["upgrade 5 Tyleon\n"], 'queue untouched without Tyleon buildings');
  done_testing();
};

# --- cmd_require --------------------------------------------------------------------------

subtest 'cmd_require' => sub {
  reset_state();
  my @mines = (
    make_building(id => 1, name => 'Mine', level => 7, url => '/mine7',
      upgrade => { cost => modest_cost(), production => {} }),
    make_building(id => 2, name => 'Mine', level => 6, url => '/mine6',
      upgrade => { cost => modest_cost(), production => {} }),
    make_building(id => 3, name => 'Mine', level => 5, url => '/mine5',
      upgrade => { cost => modest_cost(), production => {} }),
  );
  $buildings = { buildings => { map { $_->{id} => $_ } @mines } };

  $client = FakeClient->new(responses => {
    body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });
  $buildable = { buildable => { 'Mine' => { build => { can => 1 } } } };
  @builds = ();
  @queue = ("require 5x 5 Mine\n");
  is(cmd_require(0, '5x', 5, 'Mine', { quiet => 0 }), 'advance', 'deficient count advances');
  is_deeply(\@queue, ["require 5x 5 Mine\n"], 'require command retained while deficient');
  is_deeply(\@builds, ['Mine'], 'new build recorded');
  is(scalar $client->calls_for('body_build'), 1, 'deficiency triggers a build');

  @builds = ();
  $abort = 1;
  @queue = ("require 5 Mine\n");
  is(cmd_require(0, undef, 5, 'Mine', { quiet => 0 }), 'advance', 'satisfied require advances');
  ok(!$abort, 'satisfied require clears the abort flag');

  $mines[2]{level} = 3;
  @builds = ();
  $client = stats_client(status => default_status(), stats => { 3 => { upgrade => $mines[2]{upgrade} } });
  @queue = ("require 3x 5 Mine\n");
  is(cmd_require(0, '3x', 5, 'Mine', { quiet => 0 }), 'advance', 'upgrade path advances');
  my @c = $client->calls_for('building_upgrade');
  is_deeply($c[-1], ['building_upgrade', '/mine5', 3], 'lowest mine below target upgraded');

  # unknown building name reports instead of crashing the run
  $buildable = { buildable => {} };
  @builds = ();
  @queue = ("require 2x 5 Flurb Factory\n");
  is(cmd_require(0, '2x', 5, 'Flurb Factory', { quiet => 0 }), 'advance', 'unknown require target advances');
  is($queue[0], "-require 2x 5 Flurb Factory\n", 'unknown require target marked');
  is(scalar $client->calls_for('body_build'), 0, 'no build RPC for an unknown require target');

  # known but unbuildable: the build path is denied and the command marked
  $buildable = { buildable => { 'Mine' => { build => { can => 0, reason => ['x', 'Needs a body.'] } } } };
  @builds = ();
  @queue = ("require 5x 5 Mine\n");
  is(cmd_require(0, '5x', 5, 'Mine', { quiet => 0 }), 'advance', 'denied require build advances');
  is($queue[0], "-require 5x 5 Mine\n", 'denied require build marked');
  is(scalar $client->calls_for('body_build'), 0, 'no build RPC when the require build is denied');

  # more buildings than the count: the lowest of the top count is the target
  my @five = map {
    make_building(id => 40 + $_, name => 'Mine', level => 9 - $_, url => '/mine' . (9 - $_),
      upgrade => { cost => modest_cost(), production => {} })
  } (0 .. 4);
  $buildings = { buildings => { map { $_->{id} => $_ } @five } };
  $buildable = { buildable => { 'Mine' => { build => { can => 1 } } } };
  @builds = ();
  $client = stats_client(status => default_status(),
                         stats => { map { $_->{id} => { upgrade => $_->{upgrade} } } @five });
  @queue = ("require 3x 8 Mine\n");
  is(cmd_require(0, '3x', 8, 'Mine', { quiet => 0 }), 'advance', 'truncated require advances');
  my @tc = $client->calls_for('building_upgrade');
  is($tc[-1]->[2], 42, 'lowest of the top three mines upgraded');

  # upgrade target denied: command marked, no upgrade
  $buildings = { buildings => { map { $_->{id} => $_ } @mines } };
  $mines[2]{level} = 3;
  @builds = ();
  $client = FakeClient->new(responses => {
    body_status => sub { default_status() },
    building_stats_for_level => sub {
      { building => { upgrade => { cost => modest_cost(), production => {} } } }
    },
    building_view_cached => { building => { upgrade => { can => 0, reason => ['c', 'It forms naturally.'] } } },
  });
  @queue = ("require 3x 5 Mine\n");
  is(cmd_require(0, '3x', 5, 'Mine', { quiet => 0 }), 'advance', 'denied require upgrade advances');
  is($queue[0], "-require 3x 5 Mine\n", 'denied require upgrade marked');
  is(scalar $client->calls_for('building_upgrade'), 0, 'no upgrade RPC for a denied require');
  done_testing();
};

# --- cmd_subsidize --------------------------------------------------------------------------

subtest 'cmd_subsidize' => sub {
  reset_state();

  @builds = ();
  $client = FakeClient->new(responses => { body_subsidize => { essentia_spent => 10 } });
  is(cmd_subsidize('30m', undef, {}), 'advance', 'no pending builds, no subsidy');
  is(scalar $client->calls_for('body_subsidize'), 0, 'no subsidy RPC without builds');

  @builds = ({ pending_build => { end => end_after(100) } });
  $client = FakeClient->new(responses => {
    empire_status => { essentia => 3000 },
    body_subsidize => { essentia_spent => 10 },
  });
  is(cmd_subsidize('30m', undef, {}), 'advance', 'build nearly done, no subsidy');
  is(scalar $client->calls_for('body_subsidize'), 0, 'no subsidy RPC when the wait is shorter');

  @builds = ({ pending_build => { end => end_after(3700) } });
  is(cmd_subsidize('2h', undef, {}), 'advance', 'build too soon for a two hour subsidy');
  is(scalar $client->calls_for('body_subsidize'), 0, 'no subsidy RPC past the two hour mark');

  $client = FakeClient->new(responses => {
    empire_status => { essentia => 100 },
    body_subsidize => { essentia_spent => 10 },
  });
  is(cmd_subsidize('30m', '500', {}), 'advance', 'limit above the essentia balance');
  is(scalar $client->calls_for('body_subsidize'), 0, 'no subsidy RPC with a custom limit unmet');

  @builds = ({ pending_build => { end => end_after(3700) } });
  $client = FakeClient->new(responses => {
    empire_status => { essentia => 3000 },
    body_subsidize => { essentia_spent => 20 },
  });
  is(cmd_subsidize('45 seconds', undef, {}), 'advance', 'subsidy succeeds');
  my @c = $client->calls_for('body_subsidize');
  is_deeply($c[0], ['body_subsidize', 'testbody42'], 'subsidize called for the body');
  is_deeply(\@builds, [], 'pending builds cleared after subsidizing');

  @builds = ({ pending_build => { end => end_after(3700) } });
  cmd_subsidize('61m', undef, {});
  is(scalar $client->calls_for('body_subsidize'), 2, '61 minute gate lets a one hour build through');

  @builds = ({ pending_build => { end => end_after(3700) } });
  cmd_subsidize('62m', undef, {});
  is(scalar $client->calls_for('body_subsidize'), 2, '62 minute gate holds a one hour build back');

  # days unit parsing via the gates
  @builds = ({ pending_build => { end => end_after(3 * 86400 + 3600) } });
  cmd_subsidize('3d', undef, {});
  is(scalar $client->calls_for('body_subsidize'), 3, 'three day gate lets a three day build through');

  @builds = ({ pending_build => { end => end_after(3 * 86400 + 3600) } });
  cmd_subsidize('4d', undef, {});
  is(scalar $client->calls_for('body_subsidize'), 3, 'four day gate holds a three day build back');

  # multiple pending builds: the longest governs
  @builds = ({ pending_build => { end => end_after(600) } },
             { pending_build => { end => end_after(3700) } });
  cmd_subsidize('30m', undef, {});
  is(scalar $client->calls_for('body_subsidize'), 4, 'longest pending build governs the subsidy');

  # a failing subsidize RPC is swallowed, the pending build survives
  $client = FakeClient->new(responses => {
    empire_status => { essentia => 3000 },
    body_subsidize => sub { die "boom\n" },
  });
  @builds = ({ pending_build => { end => end_after(3700) } });
  is(cmd_subsidize('30m', undef, {}), 'advance', 'failing subsidy advances');
  is(scalar @builds, 1, 'pending builds survive a failed subsidy');
  done_testing();
};

# --- cmd_sacrifice --------------------------------------------------------------------------

subtest 'cmd_sacrifice' => sub {
  reset_state();
  my $mine = make_building(id => 7, name => 'Mine', level => 5, url => '/mine',
    upgrade => { cost => modest_cost(), production => {} });
  my $halls1 = make_building(id => 8, name => 'Halls of Vrbansk', level => 1, url => '/halls1');
  $buildings = { buildings => { 7 => $mine, 8 => $halls1 } };
  $client = FakeClient->new(responses => {
    body_plans => { plans => [ { name => 'Halls of Vrbansk', quantity => 2 } ] },
  });

  @queue = ("sacrifice 5 Mine\n");
  is(cmd_sacrifice(0, '', 5, 'Mine', { quiet => 0 }), 'advance', 'insufficient halls advances');
  is($queue[0], "-sacrifice 5 Mine\n", 'insufficient halls marked quiet');

  my $halls2 = make_building(id => 9, name => 'Halls of Vrbansk', level => 1, url => '/halls2');
  my $halls3 = make_building(id => 10, name => 'Halls of Vrbansk', level => 1, url => '/halls3');
  $buildings = { buildings => { 7 => $mine, 8 => $halls1, 9 => $halls2, 10 => $halls3 } };
  $client = FakeClient->new(responses => {
    body_plans => { plans => [ { name => 'Halls of Vrbansk', quantity => 5 } ] },
    building_upgrade => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });
  @queue = ("sacrifice 5 Mine\n");
  is(cmd_sacrifice(0, '', 5, 'Mine', { quiet => 0 }), 'reprocess', 'sufficient halls sacrifices');
  my @c = $client->calls_for('building_upgrade');
  is_deeply($c[0], ['building_upgrade', '/mine', 7], 'sacrifice upgrades the target');
  is_deeply(\@queue, [], 'sacrifice command removed');
  is_deeply(\@builds, ['Mine'], 'sacrifice recorded as a build');

  @builds = ();
  @queue = ("sacrifice 5 Nonexistent\n");
  is(cmd_sacrifice(0, '', 5, 'Nonexistent', { quiet => 0 }), 'advance', 'no target advances silently');

  # falsy level matches any building below 30
  $buildings = { buildings => { 7 => $mine, 8 => $halls1, 9 => $halls2, 10 => $halls3 } };
  $client = FakeClient->new(responses => {
    body_plans => { plans => [ { name => 'Halls of Vrbansk', quantity => 5 } ] },
    building_upgrade => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
  });
  @builds = ();
  @queue = ("sacrifice 0 Mine\n");
  is(cmd_sacrifice(0, '', 0, 'Mine', { quiet => 0 }), 'reprocess', 'falsy level matches any level target');

  # upTo variant matches levels below the marker
  @builds = ();
  @queue = ("sacrifice <7 Mine\n");
  is(cmd_sacrifice(0, '<', 7, 'Mine', { quiet => 0 }), 'reprocess', 'upTo sacrifice matches lower levels');

  # retained sacrifice command stays in the queue
  @builds = ();
  @queue = ("*sacrifice 5 Mine\n");
  is(cmd_sacrifice(0, '', 5, 'Mine', { quiet => 0, retain => 1 }), 'reprocess', 'retained sacrifice reprocesses');
  is_deeply(\@queue, ["*sacrifice 5 Mine\n"], 'retained sacrifice kept in the queue');

  # body_plans failure counts buildings only
  $client = FakeClient->new(responses => {
    body_plans => sub { die "boom\n" },
  });
  @builds = ();
  @queue = ("sacrifice 5 Mine\n");
  is(cmd_sacrifice(0, '', 5, 'Mine', { quiet => 0 }), 'advance', 'plans failure counts buildings only');
  is($queue[0], "-sacrifice 5 Mine\n", 'halls from buildings alone marked insufficient');
  done_testing();
};

# --- cmd_shipbuild --------------------------------------------------------------------------

subtest 'cmd_shipbuild' => sub {
  reset_state();
  my $yard = make_building(id => 30, name => 'Shipyard', level => 5, url => '/shipyard');

  $buildings = { buildings => {} };
  @queue = ("shipbuild probe\n");
  is(cmd_shipbuild(0, 'probe', { quiet => 0 }), 'advance', 'no yard advances');
  is($queue[0], "shipbuild probe\n", 'queue untouched with no yard');

  $buildings = { buildings => { 30 => $yard } };
  $client = FakeClient->new(responses => { yard_queue => { ships_building => [ { type => 'probe' } ] } });
  is(cmd_shipbuild(0, 'probe', { quiet => 0 }), 'advance', 'busy yard advances');
  is(scalar $client->calls_for('yard_build'), 0, 'no build RPC while the yard is busy');

  $client = FakeClient->new(responses => {
    yard_queue => { ships_building => [] },
    yard_buildable => { buildable => {} },
  });
  @queue = ("shipbuild snark\n");
  cmd_shipbuild(0, 'snark', { quiet => 0 });
  is($queue[0], "-shipbuild snark\n", 'unknown ship type marked');

  $client = FakeClient->new(responses => {
    yard_queue => { ships_building => [] },
    yard_buildable => { buildable => { snark => { can => 0, reason => ['c', 'Not enough resources.'] } } },
  });
  @queue = ("shipbuild snark\n");
  cmd_shipbuild(0, 'snark', { quiet => 0 });
  is($queue[0], "-shipbuild snark\n", 'unbuildable ship marked');

  $client = FakeClient->new(responses => {
    yard_queue => { ships_building => [] },
    yard_buildable => { buildable => { probe => { can => 1 } } },
    yard_build => { ships_building => [ { date_completed => '01 01 2099 00:00:00 +0000' } ] },
  });
  @queue = ("+shipbuild probe\n");
  is(cmd_shipbuild(0, 'probe', { quiet => 0, requeue => 1 }), 'reprocess', 'successful ship build reprocesses');
  is_deeply(\@queue, ["+shipbuild probe\n"], 'requeued ship build appended');

  # rebuild variant requeues at the front
  $client = FakeClient->new(responses => {
    yard_queue => { ships_building => [] },
    yard_buildable => { buildable => { probe => { can => 1 } } },
    yard_build => { ships_building => [ { date_completed => '01 01 2099 00:00:00 +0000' } ] },
  });
  @queue = ("++shipbuild probe\n");
  is(cmd_shipbuild(0, 'probe', { quiet => 0, rebuild => 1, priority => '' }), 'reprocess', 'rebuild ship reprocesses');
  is_deeply(\@queue, ["++shipbuild probe\n"], 'rebuild requeues the ship build at the front');

  # a failing yard build is swallowed silently, the command survives
  $client = FakeClient->new(responses => {
    yard_queue => { ships_building => [] },
    yard_buildable => { buildable => { probe => { can => 1 } } },
    yard_build => sub { die "boom\n" },
  });
  @queue = ("shipbuild probe\n");
  is(cmd_shipbuild(0, 'probe', { quiet => 0 }), 'advance', 'failing yard build advances');
  is($queue[0], "shipbuild probe\n", 'failing yard build leaves the queue alone');
  done_testing();
};

# --- parse_resources_args -------------------------------------------------------------------

subtest 'parse_resources_args' => sub {
  my $o = parse_resources_args('');
  is($o->{focus}, 'stored', 'default focus');
  is($o->{max_level}, 15, 'default max level');
  is($o->{prod_bias}, 24, 'default production bias');
  ok(!$o->{balance} && !$o->{no_storage} && !$o->{storage_only} && !$o->{avoid_delay}, 'no options by default');

  $o = parse_resources_args(' focus hour, max level 20, production bias 48, balance');
  is($o->{focus}, 'hour', 'focus hour');
  is($o->{max_level}, 20, 'max level parsed');
  is($o->{prod_bias}, 48, 'production bias parsed');
  ok($o->{balance}, 'balance parsed');

  $o = parse_resources_args(' focus prod');
  is($o->{focus}, 'hour', 'focus prod maps to hour ranking');

  $o = parse_resources_args(' ignore food ore, no storage');
  ok($o->{ignore}{food} && $o->{ignore}{ore}, 'ignored resources collected');
  ok(!$o->{ignore}{water}, 'unlisted resources not ignored');
  ok($o->{no_storage}, 'no storage parsed');

  $o = parse_resources_args(' storage only, avoid delay');
  ok($o->{storage_only} && $o->{avoid_delay}, 'storage only and avoid delay parsed');
  done_testing();
};

# --- resource_ratios --------------------------------------------------------------------------

subtest 'resource_ratios' => sub {
  my %ratio = resource_ratios(default_status());
  is(sprintf('%.2f', $ratio{food}), '0.50', 'food ratio');
  is(sprintf('%.2f', $ratio{energy}), '0.00', 'energy ratio');
  done_testing();
};

# --- compute_building_payoffs ----------------------------------------------------------------

subtest 'compute_building_payoffs' => sub {
  my $status = default_status();

  my $gep = make_building(id => 1, name => 'Geo Energy Plant', level => 5, energy_hour => 10,
    upgrade => { cost => modest_cost(energy => 0, time => 7200), production => { energy_hour => 15 } });
  my ($prod, $max_prod) = compute_building_payoffs([$gep], 'energy', $status,
    { avoid_delay => 0, prod_bias => 24, balance => 0 });
  is($gep->{delay}, 0, 'no shortfall means no delay');
  is($gep->{cost_time}, 2, 'cost time from build seconds plus rate ceilings');
  is($gep->{payoff}, 5, 'payoff from the production delta');
  is($gep->{cost_prod}, 0, 'no other-rate change means no production cost');
  is($gep->{payoff_ratio}, 2.5, 'ratio divides payoff by the larger cost');
  ok(!%$prod && !defined $max_prod, 'no food totals when unbalanced');

  # avoid delay inflates the delay a hundredfold
  my $gep2 = make_building(id => 1, name => 'Geo Energy Plant', level => 5, energy_hour => 0,
    upgrade => { cost => modest_cost(energy => 5, time => 3600), production => { energy_hour => 40 } });
  compute_building_payoffs([$gep2], 'energy', $status, { avoid_delay => 1, prod_bias => 24, balance => 0 });
  is($gep2->{delay}, 50, 'avoid delay multiplies a half hour wait');
  is(sprintf('%.2f', $gep2->{cost_time}), '51.00', 'avoid delay multiplies the wait');
  is(sprintf('%.4f', $gep2->{payoff_ratio}), sprintf('%.4f', 40 / 51), 'ratio reflects the inflated delay');

  # zero hourly rate divides by the epsilon guard, not zero
  my $norage = make_building(id => 1, name => 'Geo Energy Plant', level => 5, energy_hour => 0,
    upgrade => { cost => modest_cost(energy => 100, time => 3600), production => { energy_hour => 30 } });
  my $status0 = default_status();
  $status0->{energy_hour} = 0;
  compute_building_payoffs([$norage], 'energy', $status0, { avoid_delay => 0, prod_bias => 24, balance => 0 });
  is($norage->{delay}, 100000, 'zero rate falls back to the epsilon divisor');
  is(sprintf('%.6f', $norage->{payoff_ratio}), sprintf('%.6f', 30 / 100001), 'no division by zero');

  # Ore Refinery bonus from the ore production base
  my $mine = make_building(id => 2, name => 'Mine', level => 5, ore_hour => 100,
    upgrade => { cost => modest_cost(), production => { ore_hour => 110 } });
  my $refinery = make_building(id => 3, name => 'Ore Refinery', level => 10, ore_hour => 0,
    upgrade => { cost => modest_cost(), production => { ore_hour => 0 } });
  my $status_ore = default_status();
  $status_ore->{ore_hour} = 100;
  compute_building_payoffs([$mine, $refinery], 'ore', $status_ore, { avoid_delay => 0, prod_bias => 24, balance => 0 });
  is(sprintf('%.3f', $refinery->{payoff}), sprintf('%.3f', 100 / (1 + 10 * 0.05) * 0.05),
     'refinery payoff includes the ore base bonus');

  # production bias scales the other-rate cost
  my $farm = make_building(id => 4, name => 'Wheat Farm', level => 5, food_hour => 100,
    upgrade => { cost => modest_cost(), production => { food_hour => 90 } });
  my $status_food = default_status();
  compute_building_payoffs([$farm], 'ore', $status_food, { avoid_delay => 0, prod_bias => 24, balance => 0 });
  is(sprintf('%.4f', $farm->{cost_prod}), sprintf('%.4f', 24 * 10 / 90), 'default bias prices the food slowdown');
  compute_building_payoffs([$farm], 'ore', $status_food, { avoid_delay => 0, prod_bias => 48, balance => 0 });
  is(sprintf('%.4f', $farm->{cost_prod}), sprintf('%.4f', 48 * 10 / 90), 'production bias option doubles the price');

  # balance collects the food totals
  my $apple = make_building(id => 11, name => 'Apple Orchard', level => 5, food_hour => 50,
    upgrade => { cost => modest_cost(food => 10), production => { food_hour => 55 } });
  my $wheat = make_building(id => 12, name => 'Wheat Farm', level => 5, food_hour => 100,
    upgrade => { cost => modest_cost(food => 10), production => { food_hour => 105 } });
  my ($prod2, $max2) = compute_building_payoffs([$apple, $wheat], 'food', $status_food,
    { avoid_delay => 0, prod_bias => 24, balance => 1 });
  is($prod2->{apple}, 50, 'apple production total');
  is($prod2->{wheat}, 100, 'wheat production total');
  is($max2, 100, 'max production total');
  done_testing();
};

# --- apply_food_balance -----------------------------------------------------------------------

subtest 'apply_food_balance' => sub {
  my $apple = make_building(id => 11, name => 'Apple Orchard', level => 5, food_hour => 50,
    upgrade => { cost => modest_cost(food => 10), production => { food_hour => 55 } });
  my $wheat = make_building(id => 12, name => 'Wheat Farm', level => 5, food_hour => 100,
    upgrade => { cost => modest_cost(food => 10), production => { food_hour => 105 } });
  my $oremine = make_building(id => 13, name => 'Ore Mine', level => 5,
    upgrade => { cost => modest_cost(), production => {} });
  $apple->{payoff} = 5; $apple->{cost_time} = 1; $apple->{cost_prod} = 0;
  $wheat->{payoff} = 5; $wheat->{cost_time} = 1; $wheat->{cost_prod} = 0;
  $oremine->{payoff} = 0; $oremine->{cost_time} = 1; $oremine->{cost_prod} = 0;

  apply_food_balance([$apple, $wheat, $oremine], { apple => 50, wheat => 100 }, 100);
  is($apple->{payoff}, 51, 'apple payoff rebalanced above the wheat total');
  is($wheat->{payoff}, 1, 'wheat payoff rebalanced at the margin');
  is($oremine->{payoff}, 0, 'non-food buildings zeroed out');
  is($apple->{payoff_ratio}, 51, 'apple ratio from the rebalanced payoff');
  is($wheat->{payoff_ratio}, 1, 'wheat ratio from the rebalanced payoff');

  # no food producers at all: totals start empty and non-food buildings zero out
  my $rock = make_building(id => 50, name => 'Ore Mine', level => 5,
    upgrade => { cost => modest_cost(), production => {} });
  $rock->{payoff} = 3; $rock->{cost_time} = 1; $rock->{cost_prod} = 0;
  apply_food_balance([$rock], {}, undef);
  is($rock->{payoff}, 0, 'non-food building zeroed when no food producers exist');
  done_testing();
};

# --- prune_count_args --------------------------------------------------------------------------

subtest 'prune_count_args' => sub {
  my @bld = (
    { name => 'Geo Energy Plant', level => 7, payoff_ratio => 1 },
    { name => 'Geo Energy Plant', level => 5, payoff_ratio => 1 },
    { name => 'Geo Energy Plant', level => 3, payoff_ratio => 1 },
  );

  my @args = ('2x Geo Energy Plant');
  my @kept = prune_count_args([@bld], \@args, 15);
  is(scalar @kept, 2, 'Nx keeps the highest level allowance');
  is($kept[0]{level}, 7, 'highest level kept first');
  is($kept[1]{level}, 5, 'second highest kept');
  is($args[0], '0x Geo Energy Plant', 'allowance decremented per passing building');

  @args = ('0x Geo Energy Plant');
  @kept = prune_count_args([@bld], \@args, 15);
  is(scalar @kept, 0, '0x prunes every matching building');

  @args = ();
  @kept = prune_count_args([{ name => 'X', level => 14, payoff_ratio => 1 },
                            { name => 'X', level => 15, payoff_ratio => 1 },
                            { name => 'X', level => 16, payoff_ratio => 1 }], \@args, 15);
  is(scalar @kept, 1, 'max level prunes buildings at or above it');
  is($kept[0]{level}, 14, 'only the building below the max level survives');
  done_testing();
};

# --- cmd_resources ------------------------------------------------------------------------------

subtest 'cmd_resources' => sub {
  my $gep = make_building(id => 1, name => 'Geo Energy Plant', level => 5, energy_hour => 10,
    url => '/geoenergyplant',
    upgrade => { cost => modest_cost(energy => 0, time => 7200), production => { energy_hour => 15 } });

  subtest 'default picks the scarcest resource and ranks production' => sub {
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => { %$gep } } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $gep->{upgrade} } });
    my $out = capture { cmd_resources(0, '', { quiet => 0 }) };
    like($out, qr/energy payoff ratio:\s+2\.50/, 'payoff table printed');
    my @c = $client->calls_for('building_upgrade');
    is_deeply($c[-1], ['building_upgrade', '/geoenergyplant', 1], 'ranked building upgraded');
    is($queue[0], "resources\n", 'resources command retained');
    is(scalar @builds, 1, 'build recorded');
    done_testing();
  };

  subtest 'no upgradable buildings marks the command' => sub {
    my $senior = { %$gep, level => 15 };
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => $senior } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $senior->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    is($queue[0], "-resources\n", 'command marked when nothing is upgradable');

    reset_state(queue => ["resources max level 20\n"]);
    $buildings = { buildings => { 1 => $senior } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $senior->{upgrade} } });
    capture { cmd_resources(0, ' max level 20', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is_deeply($c[-1], ['building_upgrade', '/geoenergyplant', 1], 'max level option lifts the cap');
    done_testing();
  };

  subtest 'focus hour ranks by hourly production' => sub {
    my $mine = make_building(id => 2, name => 'Mine', level => 5, ore_hour => 100,
      upgrade => { cost => modest_cost(), production => { ore_hour => 110 } });
    my $refinery = make_building(id => 3, name => 'Ore Refinery', level => 10, ore_hour => 0,
      upgrade => { cost => modest_cost(), production => { ore_hour => 5 } });
    my $status = default_status();
    $status->{energy_stored} = 10000;
    $status->{energy_hour} = 500;
    $status->{ore_hour} = 40;
    reset_state(queue => ["resources focus hour\n"]);
    $buildings = { buildings => { 2 => $mine, 3 => $refinery } };
    $client = stats_client(status => $status,
                           stats => { 2 => { upgrade => $mine->{upgrade} },
                                      3 => { upgrade => $refinery->{upgrade} } });
    capture { cmd_resources(0, ' focus hour', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is($c[-1]->[2], 2, 'hourly focus upgrades the better ore payoff');
    done_testing();
  };

  subtest 'ignore steers the resource choice' => sub {
    my $wheat = make_building(id => 11, name => 'Wheat Farm', level => 5, food_hour => 50,
      upgrade => { cost => modest_cost(energy => 0), production => { food_hour => 52 } });
    # food, ore and water are tied at half storage, so which one the hash
    # seed picks varies; either way energy must never be the target
    reset_state(queue => ["resources ignore energy\n"]);
    $buildings = { buildings => { 1 => { %$gep }, 11 => $wheat } };
    $client = stats_client(status => default_status(),
                           stats => { 1 => { upgrade => $gep->{upgrade} },
                                      11 => { upgrade => $wheat->{upgrade} } });
    my $out = capture { cmd_resources(0, ' ignore energy', { quiet => 0 }) };
    unlike($out, qr/Want to upgrade energy production/, 'ignored resource never targeted');
    my @c = $client->calls_for('building_upgrade');
    if (@c) {
      is($c[-1]->[2], 11, 'food won the tie: wheat farm upgraded');
    } else {
      like($queue[0], qr/^-resources ignore energy/,
           'ore or water won the tie: no producer, command marked');
    }

    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => { %$gep }, 11 => $wheat } };
    $client = stats_client(status => default_status(),
                           stats => { 1 => { upgrade => $gep->{upgrade} },
                                      11 => { upgrade => $wheat->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    my @c2 = $client->calls_for('building_upgrade');
    is($c2[-1]->[2], 1, 'without ignore the energy producer wins');
    done_testing();
  };

  subtest 'equalize storage before production' => sub {
    my $status = default_status();
    $status->{energy_stored} = 2000;
    my $low = make_building(id => 21, name => 'Ore Storage Tanks', level => 2, url => '/orestorage2',
      upgrade => { cost => modest_cost(), production => {} });
    my $high = make_building(id => 22, name => 'Ore Storage Tanks', level => 5, url => '/orestorage5',
      upgrade => { cost => modest_cost(), production => {} });
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => { %$gep }, 21 => $low, 22 => $high } };
    $client = stats_client(status => $status,
                           stats => { 1 => { upgrade => $gep->{upgrade} },
                                      21 => { upgrade => $low->{upgrade} },
                                      22 => { upgrade => $high->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is(scalar @c, 1, 'only the equalizing upgrade happens');
    is($c[0]->[2], 21, 'lowest storage level upgraded');
    done_testing();
  };

  subtest 'no storage skips the equalize path' => sub {
    my $status = default_status();
    $status->{energy_stored} = 2000;
    my $low = make_building(id => 21, name => 'Ore Storage Tanks', level => 2, url => '/orestorage2',
      upgrade => { cost => modest_cost(), production => {} });
    my $high = make_building(id => 22, name => 'Ore Storage Tanks', level => 5, url => '/orestorage5',
      upgrade => { cost => modest_cost(), production => {} });
    reset_state(queue => ["resources no storage\n"]);
    $buildings = { buildings => { 1 => { %$gep }, 21 => $low, 22 => $high } };
    $client = stats_client(status => $status,
                           stats => { 1 => { upgrade => $gep->{upgrade} },
                                      21 => { upgrade => $low->{upgrade} },
                                      22 => { upgrade => $high->{upgrade} } });
    capture { cmd_resources(0, ' no storage', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is_deeply($c[-1], ['building_upgrade', '/geoenergyplant', 1], 'production upgrade goes ahead');
    ok(!(grep { $_->[2] == 21 } @c), 'storage left alone under no storage');
    done_testing();
  };

  subtest 'near storage limit upgrades that type of storage' => sub {
    my $status = default_status();
    $status->{ore_stored} = 19800; $status->{ore_hour} = 100;
    $status->{water_stored} = 19600;
    $status->{energy_stored} = 19400;
    my $ore_storage = make_building(id => 21, name => 'Ore Storage Tanks', level => 4, url => '/orestorage',
      upgrade => { cost => modest_cost(), production => {} });
    my $water_storage = make_building(id => 22, name => 'Water Storage Tank', level => 4, url => '/waterstorage',
      upgrade => { cost => modest_cost(), production => {} });
    my $energy_reserve = make_building(id => 23, name => 'Energy Reserve', level => 4, url => '/energyreserve',
      upgrade => { cost => modest_cost(energy => 100), production => { energy_hour => 2 } });
    my $food_reserve = make_building(id => 24, name => 'Food Reserve', level => 4, url => '/foodreserve',
      upgrade => { cost => modest_cost(), production => {} });
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { map { $_->{id} => $_ } ($ore_storage, $water_storage, $energy_reserve, $food_reserve) } };
    $client = stats_client(status => $status,
                           stats => { map { $_->{id} => { upgrade => $_->{upgrade} } }
                                      ($ore_storage, $water_storage, $energy_reserve, $food_reserve) });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is(scalar @c, 1, 'only the near limit upgrade happens');
    is($c[0]->[2], 23, 'third fullest resource gets its storage upgraded');
    done_testing();
  };

  subtest 'storage only stops before production' => sub {
    reset_state(queue => ["resources storage only\n"]);
    $buildings = { buildings => { 1 => { %$gep } } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $gep->{upgrade} } });
    capture { cmd_resources(0, ' storage only', { quiet => 0 }) };
    is(scalar $client->calls_for('building_upgrade'), 0, 'no production upgrade under storage only');
    is($queue[0], "resources storage only\n", 'command neither consumed nor marked');

    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => { %$gep } } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $gep->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    is(scalar $client->calls_for('building_upgrade'), 1, 'production upgrade without the option');
    done_testing();
  };

  subtest 'balance evens out food producers' => sub {
    my $status = default_status();
    $status->{food_stored} = 2000;
    $status->{energy_stored} = 10000;
    my $apple = make_building(id => 11, name => 'Apple Orchard', level => 5, food_hour => 50,
      upgrade => { cost => modest_cost(food => 10, energy => 0), production => { food_hour => 55 } });
    my $wheat = make_building(id => 12, name => 'Wheat Farm', level => 5, food_hour => 100,
      upgrade => { cost => modest_cost(food => 10, energy => 0), production => { food_hour => 105 } });
    my $oremine = make_building(id => 13, name => 'Ore Mine', level => 5,
      upgrade => { cost => modest_cost(food => 10, energy => 0), production => {} });
    reset_state(queue => ["resources balance\n"]);
    $buildings = { buildings => { 11 => $apple, 12 => $wheat, 13 => $oremine } };
    $client = stats_client(status => $status,
                           stats => { 11 => { upgrade => $apple->{upgrade} },
                                      12 => { upgrade => $wheat->{upgrade} },
                                      13 => { upgrade => $oremine->{upgrade} } });
    my $out = capture { cmd_resources(0, ' balance', { quiet => 0 }) };
    like($out, qr/payoff ratio:\s+51\.00:.*Apple Orchard/, 'apple rebalanced payoff printed');
    my @c = $client->calls_for('building_upgrade');
    is($c[-1]->[2], 11, 'balanced food run picks the scarcer food type');
    done_testing();
  };

  subtest 'avoid delay demotes the slow producer' => sub {
    my $slow = make_building(id => 1, name => 'Geo Energy Plant', level => 5, energy_hour => 0,
      url => '/geoenergyplant',
      upgrade => { cost => modest_cost(energy => 5, time => 3600), production => { energy_hour => 40 } });
    my $quick = make_building(id => 2, name => 'Fusion Power Plant', level => 5, energy_hour => 0,
      url => '/fusion',
      upgrade => { cost => modest_cost(energy => 0, time => 3600), production => { energy_hour => 20 } });
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => $slow, 2 => $quick } };
    $client = stats_client(status => default_status(),
                           stats => { 1 => { upgrade => $slow->{upgrade} },
                                      2 => { upgrade => $quick->{upgrade} } });
    my $out = capture { cmd_resources(0, '', { quiet => 0 }) };
    like($out, qr/Want to upgrade energy production\nenergy payoff ratio:\s+26\.67:/,
         'higher payoff ranks first despite the wait');
    my @c = $client->calls_for('building_upgrade');
    if (@c) {
      is($c[-1]->[2], 1, 'slow producer upgraded when storage covers the cost');
    } else {
      like($queue[0], qr/^-resources/, 'storage shortfall marks the command instead');
    }

    reset_state(queue => ["resources avoid delay\n"]);
    $buildings = { buildings => { 1 => $slow, 2 => $quick } };
    $client = stats_client(status => default_status(),
                           stats => { 1 => { upgrade => $slow->{upgrade} },
                                      2 => { upgrade => $quick->{upgrade} } });
    my $out2 = capture { cmd_resources(0, ' avoid delay', { quiet => 0 }) };
    like($out2, qr/Want to upgrade energy production\nenergy payoff ratio:\s+20\.00:/,
         'avoid delay hands the top rank to the quick producer');
    my @c2 = $client->calls_for('building_upgrade');
    ok(@c2 && $c2[-1]->[2] == 2, 'quick producer upgraded under avoid delay');
    done_testing();
  };

  subtest 'decorations and beaches never rank' => sub {
    my $lake = make_building(id => 31, name => 'Small Lake', level => 1, energy_hour => 0,
      upgrade => { cost => modest_cost(energy => 0), production => { energy_hour => 1000 } });
    my $pond = make_building(id => 32, name => 'Algae Pond', level => 1, energy_hour => 0,
      upgrade => { cost => modest_cost(energy => 0), production => { energy_hour => 1000 } });
    my $beach = make_building(id => 33, name => 'Beach House', level => 1, energy_hour => 0, url => '/beach/house',
      upgrade => { cost => modest_cost(energy => 0), production => { energy_hour => 1000 } });
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 1 => { %$gep }, 31 => $lake, 32 => $pond, 33 => $beach } };
    $client = stats_client(status => default_status(),
                           stats => { 1 => { upgrade => $gep->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is_deeply($c[-1], ['building_upgrade', '/geoenergyplant', 1], 'only the real producer upgraded');
    done_testing();
  };

  subtest 'count args prune the ranking' => sub {
    my @geps = map {
      make_building(id => $_, name => 'Geo Energy Plant', level => (8 - $_), url => "/gep$_",
        energy_hour => 10,
        upgrade => { cost => modest_cost(energy => 0, time => 7200), production => { energy_hour => 15 } })
    } (1, 2, 3);
    reset_state(queue => ["resources 2x Geo Energy Plant\n"]);
    $buildings = { buildings => { map { $_->{id} => $_ } @geps } };
    $client = stats_client(status => default_status(),
                           stats => { map { $_->{id} => { upgrade => $_->{upgrade} } } @geps });
    capture { cmd_resources(0, ' 2x Geo Energy Plant', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is($c[-1]->[2], 1, 'two highest Geo Energy Plants stay eligible');

    reset_state(queue => ["resources 0x Geo Energy Plant\n"]);
    $buildings = { buildings => { map { $_->{id} => $_ } @geps } };
    $client = stats_client(status => default_status(),
                           stats => { map { $_->{id} => { upgrade => $_->{upgrade} } } @geps });
    capture { cmd_resources(0, ' 0x Geo Energy Plant', { quiet => 0 }) };
    is($queue[0], "-resources 0x Geo Energy Plant\n", 'fully pruned ranking marks the command');
    done_testing();
  };

  subtest 'storage paths mark the command when denied' => sub {
    my $status = default_status();
    $status->{energy_stored} = 2000;
    my $low = make_building(id => 21, name => 'Ore Storage Tanks', level => 2, url => '/orestorage2',
      upgrade => { cost => modest_cost(), production => {} });
    my $high = make_building(id => 22, name => 'Ore Storage Tanks', level => 5, url => '/orestorage5',
      upgrade => { cost => modest_cost(), production => {} });
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { 21 => $low, 22 => $high } };
    $client = denied_client(status => $status,
                            stats => { 21 => { upgrade => $low->{upgrade} },
                                       22 => { upgrade => $high->{upgrade} } });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    is(scalar $client->calls_for('building_upgrade'), 0, 'denied equalize makes no upgrade');
    is($queue[0], "-resources\n", 'denied equalize marks the command');

    my $near = default_status();
    $near->{ore_stored} = 19800;
    $near->{water_stored} = 19600;
    $near->{energy_stored} = 19400;
    my @stores = (
      make_building(id => 21, name => 'Ore Storage Tanks', level => 4, url => '/orestorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 22, name => 'Water Storage Tank', level => 4, url => '/waterstorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 23, name => 'Energy Reserve', level => 4, url => '/energyreserve',
        upgrade => { cost => modest_cost(energy => 100), production => { energy_hour => 2 } }),
      make_building(id => 24, name => 'Food Reserve', level => 4, url => '/foodreserve',
        upgrade => { cost => modest_cost(), production => {} }),
    );
    reset_state(queue => ["resources\n"]);
    $buildings = { buildings => { map { $_->{id} => $_ } @stores } };
    $client = denied_client(status => $near,
                            stats => { map { $_->{id} => { upgrade => $_->{upgrade} } } @stores });
    capture { cmd_resources(0, '', { quiet => 0 }) };
    is(scalar $client->calls_for('building_upgrade'), 0, 'denied near limit makes no upgrade');
    is($queue[0], "-resources\n", 'denied near limit marks the command');
    done_testing();
  };

  subtest 'sleepy echoes report quiet runs' => sub {
    my $status = default_status();
    $status->{energy_stored} = 2000;
    my $low = make_building(id => 21, name => 'Ore Storage Tanks', level => 2, url => '/orestorage2',
      upgrade => { cost => modest_cost(), production => {} });
    my $high = make_building(id => 22, name => 'Ore Storage Tanks', level => 5, url => '/orestorage5',
      upgrade => { cost => modest_cost(), production => {} });
    reset_state(queue => ["-*resources\n"]);
    $buildings = { buildings => { 21 => $low, 22 => $high } };
    $client = stats_client(status => $status,
                           stats => { 21 => { upgrade => $low->{upgrade} },
                                      22 => { upgrade => $high->{upgrade} } });
    $sleepy = 7;
    my $out = capture { cmd_resources(0, '', { quiet => 1 }) };
    my $equalize_echo = () = $out =~ /Equalizing storage levels/g;
    is($equalize_echo, 1, 'equalize echoed once through the sleepy branch');

    my $near = default_status();
    $near->{ore_stored} = 19800;
    $near->{water_stored} = 19600;
    $near->{energy_stored} = 19400;
    my @stores = (
      make_building(id => 21, name => 'Ore Storage Tanks', level => 4, url => '/orestorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 22, name => 'Water Storage Tank', level => 4, url => '/waterstorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 23, name => 'Energy Reserve', level => 4, url => '/energyreserve',
        upgrade => { cost => modest_cost(energy => 100), production => { energy_hour => 2 } }),
      make_building(id => 24, name => 'Food Reserve', level => 4, url => '/foodreserve',
        upgrade => { cost => modest_cost(), production => {} }),
    );
    reset_state(queue => ["-*resources\n"]);
    $buildings = { buildings => { map { $_->{id} => $_ } @stores } };
    $client = stats_client(status => $near,
                           stats => { map { $_->{id} => { upgrade => $_->{upgrade} } } @stores });
    $sleepy = 7;
    $out = capture { cmd_resources(0, '', { quiet => 1 }) };
    my $near_echo = () = $out =~ /Near storage limit for energy/g;
    is($near_echo, 1, 'near limit echoed once through the sleepy branch');

    reset_state(queue => ["-*resources\n"]);
    $buildings = { buildings => { 1 => { %$gep } } };
    $client = stats_client(status => default_status(), stats => { 1 => { upgrade => $gep->{upgrade} } });
    $sleepy = 7;
    $out = capture { cmd_resources(0, '', { quiet => 1 }) };
    my $want = () = $out =~ /Want to upgrade energy production/g;
    is($want, 1, 'production want echoed once through the sleepy branch');
    my $table = () = $out =~ /payoff ratio:\s+2\.50/g;
    is($table, 1, 'only the sleepy echo table prints');
    $sleepy = 0;
    done_testing();
  };

  subtest 'ignored resource shifts the near limit pick' => sub {
    my $status = default_status();
    $status->{ore_stored} = 19800;
    $status->{water_stored} = 19600;
    $status->{energy_stored} = 19400;
    my @stores = (
      make_building(id => 21, name => 'Ore Storage Tanks', level => 4, url => '/orestorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 22, name => 'Water Storage Tank', level => 4, url => '/waterstorage',
        upgrade => { cost => modest_cost(), production => {} }),
      make_building(id => 23, name => 'Energy Reserve', level => 4, url => '/energyreserve',
        upgrade => { cost => modest_cost(energy => 100), production => { energy_hour => 2 } }),
      make_building(id => 24, name => 'Food Reserve', level => 4, url => '/foodreserve',
        upgrade => { cost => modest_cost(), production => {} }),
    );
    my $wheat = make_building(id => 11, name => 'Wheat Farm', level => 5, food_hour => 50,
      upgrade => { cost => modest_cost(energy => 0), production => { food_hour => 52 } });
    reset_state(queue => ["resources ignore ore\n"]);
    $buildings = { buildings => { (map { $_->{id} => $_ } @stores), 11 => $wheat } };
    $client = stats_client(status => $status,
                           stats => { (map { $_->{id} => { upgrade => $_->{upgrade} } } @stores),
                                      11 => { upgrade => $wheat->{upgrade} } });
    capture { cmd_resources(0, ' ignore ore', { quiet => 0 }) };
    my @c = $client->calls_for('building_upgrade');
    is(scalar @c, 1, 'no near limit fires for the ignored resource');
    is($c[0]->[2], 11, 'food producer wins instead of any storage');
    done_testing();
  };
  done_testing();
};

# --- run_queue integration -----------------------------------------------------------------------

subtest 'run_queue' => sub {
  subtest 'upgrade then build: one build per run' => sub {
    reset_state(queue => ["-upgrade <9 Mine\n", "-build Capitol\n"]);
    my $mine = make_building(id => 7, name => 'Mine', level => 5, url => '/mine',
      upgrade => { cost => modest_cost(), production => {} });
    $buildings = { buildings => { 7 => $mine } };
    $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
    $client = FakeClient->new(responses => {
      body_status => sub { default_status() },
      building_stats_for_level => sub {
        my (undef, $url, $id, $level) = @_;
        return { building => { upgrade => { cost => modest_cost(), production => {} } } };
      },
      building_view_cached => { building => { upgrade => { can => 1 } } },
      building_upgrade => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
      body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
    });
    capture { run_queue() };
    is_deeply(\@queue, ["build Capitol\n"], 'upgrade consumed, later build left for the next run');
    is(read_queue_file(), "build Capitol\n", 'queue file keeps the remaining command');
    ok($client->calls_for('building_upgrade'), 'upgrade executed');
    is(scalar $client->calls_for('body_build'), 0, 'no second build in the same run');
    is_deeply(\@builds, ['Mine'], 'upgrade recorded as the run build');
    done_testing();
  };

  subtest 'abort flag stops processing later commands' => sub {
    reset_state(queue => ["!upgrade <9 Mine\n", "build Capitol\n"]);
    my $mine = make_building(id => 7, name => 'Mine', level => 5, url => '/mine',
      upgrade => { cost => modest_cost(), production => {} });
    $buildings = { buildings => { 7 => $mine } };
    $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
    $client = FakeClient->new(responses => {
      body_status => sub { default_status() },
      building_stats_for_level => sub {
        { building => { upgrade => { cost => modest_cost(), production => {} } } }
      },
      building_view_cached => { building => { upgrade => { can => 1 } } },
      building_upgrade => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
      body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
    });
    capture { run_queue() };
    is_deeply(\@queue, ["build Capitol\n"], 'commands after the abort marker untouched');
    is(scalar $client->calls_for('body_build'), 0, 'build after the abort marker never runs');
    done_testing();
  };

  subtest 'future wait stops the run' => sub {
    reset_state(queue => ["wait 2099-01-01\n", "build Capitol\n"]);
    $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
    $client = FakeClient->new(responses => {
      body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
    });
    capture { run_queue() };
    is_deeply(\@queue, ["-wait 2099-01-01\n", "build Capitol\n"], 'wait marked and run suspended');
    is(read_queue_file(), "-wait 2099-01-01\nbuild Capitol\n", 'suspension persisted');
    is(scalar $client->calls_for('body_build'), 0, 'later commands never dispatched');
    done_testing();
  };

  subtest 'unrecognized and failed commands' => sub {
    reset_state(queue => ["frobnicate the wibble\n", "wait 2099-01-01\n"]);
    $client = FakeClient->new();
    capture { run_queue() };
    is($queue[0], "frobnicate the wibble\n", 'unrecognized line left untouched');
    is($queue[1], "-wait 2099-01-01\n", 'run still stops at the later wait');

    reset_state(queue => ["!upgrade 5 Mine\n", "build Capitol\n"]);
    my $mine = make_building(id => 7, name => 'Mine', level => 5, url => '/mine',
      upgrade => { cost => modest_cost(), production => {} });
    $buildings = { buildings => { 7 => $mine } };
    $buildable = { buildable => { 'Capitol' => { build => { can => 1 } } } };
    $client = FakeClient->new(responses => {
      body_status => sub { default_status() },
      building_stats_for_level => sub {
        { building => { upgrade => { cost => modest_cost(), production => {} } } }
      },
      building_view_cached => { building => { upgrade => { can => 0, reason => ['c', 'It forms naturally.'] } } },
      body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
    });
    capture { run_queue() };
    is_deeply(\@queue, ["-!upgrade 5 Mine\n", "build Capitol\n"], 'failed abort command marked');
    is(scalar $client->calls_for('body_build'), 0, 'commands after a failed abort command still skipped');

    reset_state(queue => ["wait 2099-01-01\n"]);
    $debug = 1;
    my $out = capture { run_queue() };
    like($out, qr/Inspecting wait 2099-01-01/, 'debug prints the inspected command');
    $debug = 0;
    done_testing();
  };

  subtest 'flag order does not matter end to end' => sub {
    reset_state(queue => ["!-build -4 1 Water Reclamation Facility\n", "build Capitol\n"]);
    $buildable = { buildable => { 'Water Reclamation Facility' => { build => { can => 1 } } } };
    $client = FakeClient->new(responses => {
      body_build => { building => { pending_build => { end => '01 01 2099 00:00:00 +0000' } } },
    });
    capture { run_queue() };
    my @wrf = $client->calls_for('body_build');
    is_deeply($wrf[0], ['body_build', 'testbody42', 'Water Reclamation Facility', -4, 1],
              'abort-quiet build dispatches with coordinates');
    is_deeply(\@queue, ["build Capitol\n"], 'abort stops the rest of the queue after the build');
    is(scalar $client->calls_for('body_build'), 1, 'no second build in the same run');

    reset_state(queue => ["!-build -4 1 Water Reclamation Facility\n", "build Capitol\n"]);
    $buildable = { buildable => { 'Water Reclamation Facility' =>
      { build => { can => 0, reason => ['x', 'You do not have a sufficient supply (9) of mineral agents.'] } } } };
    $client = FakeClient->new();
    capture { run_queue() };
    is_deeply(\@queue, ["!-build -4 1 Water Reclamation Facility\n", "build Capitol\n"],
              'quiet denial leaves the line alone');
    is(scalar $client->calls_for('body_build'), 0, 'no build RPC when the server denies');
    done_testing();
  };
  done_testing();
};

# --- run ------------------------------------------------------------------------

subtest 'run' => sub {
  my $fake;
  no warnings 'redefine';
  local *Client::new = sub {
    my ($class, %args) = @_;
    $fake = FakeClient->new(responses => {
      empire_status => { planets => { 1 => 'Noseeum Prime', 2 => 'Overlook' }, home_planet_id => 2 },
      body_status => { name => 'Noseeum Prime' },
      body_buildings => { buildings => {} },
    });
    return $fake;
  };

  my ($fh, $qfile) = tempfile();
  print $fh "wait 2099-01-01\n";
  close $fh;

  reset_state();
  local @ARGV = ('--body=Overlook', "--queue=$qfile");
  run();
  is($body_id, 2, 'body matched by name');
  is(scalar @queue, 1, 'queue file read');
  is($queue[0], "-wait 2099-01-01\n", 'run processed the queue through run_queue');

  reset_state();
  $queue_name = undef;
  $body_name = undef;
  local @ARGV = ();
  my $died = '';
  eval { run(); 1 } or $died = $@;
  like($died, qr/Couldn't read queue file Noseeum_Prime\.queue/, 'queue name defaults from the body name');
  is(scalar $fake->calls_for('empire_status'), 1, 'home planet resolution used the empire status');

  reset_state();
  $body_id = undef;
  local @ARGV = ('--body=NoMatch');
  $died = '';
  eval { run(); 1 } or $died = $@;
  like($died, qr/No matching planet for name NoMatch/, 'unmatched body name dies');

  reset_state();
  unlink $qfile;
  open($fh, '>', $qfile) or die "Can't truncate queue file: $!";
  close $fh;
  local @ARGV = ('--body=Overlook', "--queue=$qfile");
  run();
  is(scalar @queue, 0, 'empty queue file processed cleanly');
  done_testing();
};

# --- populate_building_with_production ---------------------------------------------

subtest 'populate_building_with_production' => sub {
  my $ghost = { id => 42, name => 'Ghost', level => 1, food_hour => 5 };
  my $copy;
  my $out = capture { $copy = populate_building_with_production($ghost) };
  like($out, qr/No url for building 42/, 'missing url notice printed');
  is($copy->{food_hour}, 5, 'building returned unmerged');
  ok(!exists $copy->{upgrade}, 'no stats merged without a url');
  done_testing();
};

done_testing();
