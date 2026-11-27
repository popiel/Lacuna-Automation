use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

our $script_dir;

BEGIN {
  $script_dir = abs_path(dirname(__FILE__) . '/..');
  unshift @INC, $script_dir;
}
require Client;

sub future_stamp {
  my $time = shift;
  my @g = gmtime($time);
  return sprintf("%d %d %d %02d:%02d:%02d +0000", $g[3], $g[4] + 1, $g[5] + 1900, $g[2], $g[1], $g[0]);
}

sub test_client {
  my $dir = tempdir(CLEANUP => 1);
  (my $json_dir = $dir) =~ s/\\/\//g;
  my $config = File::Spec->catfile($dir, 'config.json');
  open(my $fh, '>', $config) or die "Can't write $config: $!";
  print {$fh} <<"END";
{
  "empire_name": "TestEmp",
  "empire_password": "seekrit",
  "uri": "https://test1.lacunaexpanse.com",
  "api_key": "abc123",
  "cache_root": "$json_dir"
}
END
  close $fh;
  return (Client->new(config => $config), $dir);
}

sub seed {
  my ($client, $type, $id, $data) = @_;
  $client->cache_write(type => $type, (defined $id ? (id => $id) : ()),
                       data => $data, invalid => time() + 3600);
}

sub fake_fleet_lib {
  my $lib = shift;
  my $result_dir = File::Spec->catfile($lib, 'Lacuna', 'DB', 'Result');
  my $fleet_dir = File::Spec->catfile($result_dir, 'Fleet');
  make_path($fleet_dir);
  open(my $fh, '>', File::Spec->catfile($result_dir, 'Fleet.pm')) or die $!;
  print {$fh} <<"END";
__PACKAGE__->typecast_map(type => {
    'dory'  => 'Lacuna::DB::Result::Fleet::FakeDory',
    'probe' => 'Lacuna::DB::Result::Fleet::FakeProbe',
    'snark' => 'Lacuna::DB::Result::Fleet::FakeSnark',
});
END
  close $fh;
  open($fh, '>', File::Spec->catfile($fleet_dir, 'FakeDory.pm')) or die $!;
  print {$fh} "with \"Lacuna::Role::Fleet::Arrive::CargoExchange\";\n";
  close $fh;
  open($fh, '>', File::Spec->catfile($fleet_dir, 'FakeSnark.pm')) or die $!;
  print {$fh} "with \"Lacuna::Role::Fleet::Arrive::CargoExchange\";\n";
  close $fh;
  open($fh, '>', File::Spec->catfile($fleet_dir, 'FakeProbe.pm')) or die $!;
  print {$fh} "use Moose;\n";
  close $fh;
  return $lib;
}

subtest 'trade_ship_types parses the clone' => sub {
  plan tests => 5;
  my $saved_lib = $Client::SERVER_LIB_DIR;
  $Client::SERVER_LIB_DIR = fake_fleet_lib(tempdir(CLEANUP => 1));
  %Client::trade_ship_types = ();
  my %types = Client::trade_ship_types();
  ok($types{dory},  'CargoExchange classes are trade types');
  ok($types{snark}, 'second CargoExchange class found');
  ok(!$types{probe}, 'non-cargo classes excluded');
  is(scalar(keys %types), 2, 'exactly the cargo-capable types');

  $Client::SERVER_LIB_DIR = $saved_lib;
  %Client::trade_ship_types = ();
  %types = Client::trade_ship_types();
  ok($types{dory} && $types{freighter} && !$types{probe}, 'real clone parses when restored');
};

subtest 'trade_stored_resources caching and TTL' => sub {
  plan tests => 6;
  my ($client) = test_client();
  seed($client, 'misc', 'trade_stored_resources_42',
       { resources => { gold => 500 }, _fetched => time() - 60 });
  my $entry = $client->trade_stored_resources(42, stale => 1800);
  ok($entry, 'fresh cache served without RPC');
  is($entry->{resources}{gold}, 500, 'cached values intact');

  seed($client, 'misc', 'trade_stored_resources_42',
       { resources => { gold => 500 }, _fetched => time() - 7200 });
  for my $body (42, 43) {
    seed($client, 'buildings', $body,
         { buildings => {}, status => { body => { id => $body } } });
  }
  $entry = $client->trade_stored_resources(42, stale => 1800);
  is($entry, undef, 'expired snapshot dropped when no Trade Ministry exists');
  is($client->cache_read(type => 'misc', id => 'trade_stored_resources_42'), undef,
     'expired entry unlinked');

  $entry = $client->trade_stored_resources(43, stale => 1800);
  is($entry, undef, 'cold body without Trade Ministry returns undef');

  seed($client, 'misc', 'trade_stored_resources_44',
       { resources => { gold => 500 }, _fetched => time() });
  is($client->trade_stored_resources(44)->{resources}{gold}, 500,
     'default TTL accepts a just-written snapshot');
};

subtest 'trade_stored_delta arithmetic and guards' => sub {
  plan tests => 5;
  my ($client) = test_client();
  my $fetched = time() - 60;
  seed($client, 'misc', 'trade_stored_resources_10',
       { resources => { gold => 500, cheese => 20 }, _fetched => $fetched });
  my $entry = $client->trade_stored_delta(10, { gold => -100, cheese => 5 });
  is($entry->{resources}{gold}, 400, 'delta subtracts');
  is($entry->{resources}{cheese}, 25, 'delta adds');
  is($entry->{_fetched}, $fetched, 'fetch time preserved, TTL clock not reset');

  $client->trade_stored_delta(10, { gold => -50 }, $fetched - 3600);
  $entry = $client->cache_read(type => 'misc', id => 'trade_stored_resources_10');
  is($entry->{resources}{gold}, 400, 'older-than-snapshot events do not apply');

  $client->trade_stored_delta(99, { gold => 1 });
  is($client->cache_read(type => 'misc', id => 'trade_stored_resources_99'), undef,
     'cold bodies are untouched, ready for a fresh fetch');
};

subtest 'trade push bookkeeping' => sub {
  plan tests => 6;
  my ($client) = test_client();
  seed($client, 'misc', 'trade_stored_resources_1',
       { resources => { gold => 500 }, _fetched => time() - 60 });

  my $now = time();
  $client->_trade_track_push(1, 2,
    [ { type => 'gold', quantity => 100 },
      { type => 'plan', plan_type => 'LCOTa', quantity => 1 } ],
    { id => 77 }, $now + 7200);

  my $entry = $client->cache_read(type => 'misc', id => 'trade_stored_resources_1');
  is($entry->{resources}{gold}, 400, 'departure subtracts known cargo from the source');

  my $tracker = $client->_trade_arrivals();
  my @arrivals = @{$tracker->{arrivals}};
  is(scalar @arrivals, 1, 'one pending arrival recorded');
  is($arrivals[0]{body_id}, 2, 'target body tracked');
  is($arrivals[0]{ship_id}, 77, 'ship id tracked');
  is($arrivals[0]{eta}, $now + 7200, 'eta tracked');
  is_deeply($arrivals[0]{cargo}, [ { name => 'gold', quantity => 100 } ],
            'resource cargo recorded, plan cargo excluded');
};

subtest 'trade_arrivals landing handling' => sub {
  plan tests => 7;
  my ($client) = test_client();
  my $now = time();
  seed($client, 'empire_status', undef,
       { id => 1, planets => { 10 => 'Ten', 42 => 'FortyTwo', 43 => 'FortyThree', 44 => 'FortyFour' } });
  for my $body (42, 43, 44) {
    seed($client, 'buildings', $body,
         { buildings => {}, status => { body => { id => $body } } });
    seed($client, 'misc', "trade_stored_resources_$body",
         { resources => { gold => 100 }, _fetched => $now - 60 });
  }
  $client->_trade_arrivals_save({ arrivals => [
    { body_id => 42, ship_id => 1, eta => $now - 30, known => 1,
      cargo => [ { name => 'gold', quantity => 50 } ] },
    { body_id => 43, ship_id => 2, eta => $now - 30, known => 0, type => 'dory' },
    { body_id => 44, ship_id => 3, eta => $now - 30, known => 0, type => 'probe' },
  ]});
  my %types = Client::trade_ship_types();

  my $merged = $client->trade_arrivals([42, 43, 44]);
  my $entry = $client->cache_read(type => 'misc', id => 'trade_stored_resources_42');
  is($entry->{resources}{gold}, 150, 'known cargo applied at landing');
  is($client->cache_read(type => 'misc', id => 'trade_stored_resources_43'), undef,
     'unknown trade-capable landing invalidates the snapshot');
  $entry = $client->cache_read(type => 'misc', id => 'trade_stored_resources_44');
  is($entry->{resources}{gold}, 100, 'unknown probe landing leaves the snapshot alone');
  my $tracker = $client->_trade_arrivals();
  is(scalar @{$tracker->{arrivals}}, 0, 'processed entries retire from the tracker');
  is(scalar @{$merged->{42}}, 0, 'no pending arrivals remain');

  $client->_trade_arrivals_save({ arrivals => [
    { body_id => 42, ship_id => 5, eta => $now - 8 * 86400, known => 0, type => 'dory' },
  ]});
  $client->trade_arrivals([42]);
  $tracker = $client->_trade_arrivals();
  is(scalar @{$tracker->{arrivals}}, 0, 'week-old entries are pruned without processing');
  is($client->cache_read(type => 'misc', id => 'trade_stored_resources_42')->{resources}{gold},
     150, 'pruned stale entry does not double-apply');
};

subtest 'trade_arrivals incoming correlation' => sub {
  plan tests => 8;
  my ($client) = test_client();
  my $now = time();
  seed($client, 'empire_status', undef,
       { id => 1, planets => { 10 => 'Ten', 42 => 'FortyTwo' } });
  seed($client, 'buildings', 10,
       { buildings => { 501 => { name => 'Space Port', level => 5 } },
         status => { body => { id => 10, incoming_own_ships => [], incoming_ally_ships => [] } } });
  seed($client, 'spaceport_view_all_ships', 10,
       { ships => [ { id => 77, type => 'dory', task => 'Travelling', hold_size => 100 },
                    { id => 88, type => 'probe', task => 'Travelling', hold_size => 0 } ] });
  seed($client, 'buildings', 42,
       { buildings => { 601 => { name => 'Space Port', level => 7 } },
         status => { body => {
           id => 42,
           incoming_own_ships => [
             { id => 77, date_arrives => future_stamp($now + 7200), is_own => 1 },
             { id => 88, date_arrives => future_stamp($now + 7200), is_own => 1 },
           ],
           incoming_ally_ships => [
             { id => 99, date_arrives => future_stamp($now + 3600), is_ally => 1 },
           ],
         } } });
  seed($client, 'spaceport_view_all_ships', 42, { ships => [] });

  my $merged = $client->trade_arrivals([10, 42]);
  my @pending = @{$merged->{42}};
  is(scalar @pending, 2, 'probe traffic is not tracked, trade ships and allies are');
  my ($ally)  = grep { $_->{ship_id} == 99 } @pending;
  my ($dory)  = grep { $_->{ship_id} == 77 } @pending;
  my ($probe) = grep { $_->{ship_id} == 88 } @pending;
  ok($ally, 'ally ship tracked');
  ok($dory, 'own trade-capable ship tracked as unknown');
  ok(!$probe, 'own non-trade ship not tracked');
  is($ally->{eta}, $now + 3600, 'ally eta parsed');
  is($ally->{known}, 0, 'ally arrival is unknown cargo');
  is($dory->{type}, 'dory', 'own ship type resolved from cached ports');

  my $tracker = $client->_trade_arrivals();
  is(scalar @{$tracker->{arrivals}}, 2, 'tracker persists the merged list');
};

done_testing();
