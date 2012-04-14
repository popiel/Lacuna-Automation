package Client;

use strict;

use Carp;
use Exception::Class (
    'LacunaRPCException' => { fields => ['code', 'text', 'data'] }
);
use File::Path;
use File::Spec;
use JSON::PP;
use LWP::UserAgent;
use Scalar::Util qw(blessed);
use Time::Local;
use List::Util qw(min max first);

{
  package LacunaRPCException;
  use overload 'bool' => sub { 1 },
               '""'   => sub { "LacunaRPCException ".($_[0]->code).": ".($_[0]->text)."\n" },
               '0+'   => sub { $_[0]->code };
}

sub new {
  my $base = shift;
  die "Cannot make a new Client from ".ref($base)."\n"
    if blessed($base) && !$base->isa("Client");
  my $class = ref($base) || $base;
  my $self = ref($base) ? { %$base, @_ } : { @_ };
  bless($self, $class);
  $self->read_config();
  $self->{ua} ||= LWP::UserAgent->new();
  $self->{cache_root} ||= 'cache';
  $self->{total_calls} = 0;
  return $self;
}

sub read_json {
  my ($self, $filename, $filetype) = @_;

  my $file;
# warn "filename: $filename\n";
  unless (open($file, "<", $filename)) {
    croak "Could not read $filetype file $filename: $!" if $filetype;
    return;
  }
  my $json = do { local $/; <$file> };
  close($file);
  my $result = decode_json($json);
  return $result;
}

sub write_json {
  my $self = shift;
  my $filename = shift;
  my $filetype = shift;
  my $value = shift;

  my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0..1]);
  -d $dir or mkpath($dir) or croak "Could not make path $dir: $!";

  my $file;
  open($file, ">", "$filename.$$") or croak "Could not write $filetype file $filename.$$: $!";
  print $file encode_json($value);
  close $file;
  rename("$filename.$$", $filename) or croak "Could not rename $filetype file $filename.$$ to $filename: $!";
}

sub read_config {
  my $self = shift;
  croak "config not specified for Client" unless $self->{config};
  my $config = $self->read_json($self->{config}, "config");
  for my $key (qw(empire_name empire_password uri api_key cache_root captcha_program)) {
    $self->{$key} = $config->{$key} if exists($config->{$key});
#    warn "$key: $self->{$key}\n";
  }
}

sub parse_time {
  my $str = shift;
  return timegm($6,$5,$4,$1,$2 - 1,$3) if $str =~ /^(\d+) (\d+) (20\d\d) (\d+):(\d+):(\d+) \+0000$/;
  return;
}

sub format_time {
  my $time = shift;
  my $gm = shift;

  my @elems = reverse(($gm ? gmtime($time) : localtime($time))[0..5]);
  $elems[0] += 1900;
  $elems[1]++;
  sprintf("%4d-%02d-%02d %02d:%02d:%02d", @elems);
}

sub log_call {
  my $api = shift;
  my $message = shift;
  my $response = shift;
  our $time;
  our $count;

  my $now = time();
  if ($time ne $now) {
    $time = $now;
    $count = 0;
  } else {
    $count++;
  }

  my $dir = File::Spec->catdir("log", substr(format_time($time, 1), 0, 10));
  -d $dir or mkpath($dir) or croak "Could not make path $dir: $!";

  eval { confess("stacktrace") };
  my $stack = $@;

  my $password;
  if ($api eq "/empire" && $message->{method} eq "login") {
    my $password = $message->{params}[1];
    $message->{params}[1] = "password elided";
    my $pattern = $password;
    $pattern =~ s/(\W)/\\$1/g;
    $stack =~ s/$pattern/password elided/g;
  }

  my $filename = join(".", format_time($time, 1), $$, sprintf("%03d", $count), $api, $message->{method});
  $filename =~ s-/--g;
  $filename =~ s- -_-g;
  my $file;
  open($file, ">:utf8", File::Spec->catfile($dir, $filename)) or croak "Could not log call: $!";
  print $file encode_json({
    api => $api,
    message => $message,
    status => $response->status_line,
    response => $response->content,
    stack => $stack,
  });
  close($file);

  if ($api eq "empire" && $message->{method} eq "login") {
    $message->{params}[1] = $password;
  }
}

sub call {
  my $self = shift;
  my $api = shift;
  my $method = shift;
  my @params = @_;

  unshift(@params, $self->session_id) unless "$api/$method" eq "empire/login";

  $api = "/$api" unless $api =~ /^\//;
  my $message = { jsonrpc => "2.0", id => 1, method => $method, params => [ @params ] };
  # warn "Posting to ".($self->{uri} . $api)."\n";
  # warn "Content: ".encode_json($message)."\n";
  my $response = $self->{ua}->post($self->{uri} . $api, Content => encode_json($message));
  $self->{total_calls}++;
  log_call($api, $message, $response);
  my $result;
  eval { $result = decode_json($response->content); };
  if (!$result && $@ =~ /^malformed/) {
    print $response->content;
    die $@;
  }
  if ($result->{error} && $result->{error}{code} == 1010 && $result->{error}{message} =~ /maximum number of requests/i) {
# {
#    "error" : {
#       "code" : 1010,
#       "data" : null,
#       "message" : "You have already made the maximum number of requests (10000) you can make for one day."
#    },
#    "id" : 1,
#    "jsonrpc" : "2.0"
# }
    # warn "Request: ".encode_json($message)."\n";
    warn "Out of requests.  Shutting down.\n";
    $self->cache_write( type => 'misc', id => 'rpc_limit', data => { rpc_exceeded => 1 } );
    LacunaRPCException->throw(code => $result->{error}{code}, text => $result->{error}{message},
                              data => JSON::PP->new->allow_nonref->canonical->pretty->encode($result->{error}{data}));
  } elsif ($result->{error} && $result->{error}{code} == 1010 && $result->{error}{message} =~ /slow down/i) {
    warn "Request throttling active: $result->{error}{message}\nSleeping for 30 seconds before retry.\n";
    sleep 30;
    return $self->call($api, $method, @_);
  } elsif ($result->{error} && $result->{error}{code} == 1016 && $self->{captcha_program}) {
    warn "Captcha needed.\n";
    $self->present_captcha();
    return $self->call($api, $method, @_);
  } elsif ($result->{error} && $result->{error}{code} == 1014 && $self->{captcha_program}) {
    warn "Captcha answer incorrect.\n";
    $self->present_captcha($result->{error}{data});
    return "wrong";
  } elsif ($result->{error}) {
    # warn "Request: ".encode_json($message)."\n";
    warn "Error Response: $result->{error}{code}: $result->{error}{message}\n";
    LacunaRPCException->throw(code => $result->{error}{code}, text => $result->{error}{message},
                              data => JSON::PP->new->allow_nonref->canonical->pretty->encode($result->{error}{data}));
  }
  croak "Call failed: ".($response->status_line) unless $response->is_success;
  croak "Call response without result" unless $result->{result};
  $self->{session_id} = $result->{result}{session_id} if $result->{result}{session_id};
  $self->{session_time} = time();
  $self->write_session if $self->{session_id};
  my $time = parse_time($result->{result}{status}{server}{time});
  $result->{result}{status}{_time} = $time;
  my $empire = $result->{result}{status}{empire};
  if ($empire) {
    $self->cache_write( type => 'empire_status', data => $empire );
  }
  my $body = $result->{result}{status}{body};
  if ($body) {
    my @arrivals = map { parse_time($_->{date_arrives}) } @{ $body->{incoming_foreign_ships} || [] };
    my $invalid = List::Util::min(time() + 3600, @arrivals);
    $self->cache_write( type => 'body_status', id => $body->{id}, data => $body, invalid => $invalid );
  }
  return $result->{result};
}


sub read_session {
  my $self = shift;

  my $session = $self->cache_read( type => 'session' );
  @$self{ keys %$session } = values %$session;

  return;
}

sub write_session {
  my $self = shift;

  my $session = {
      session_id   => $self->{session_id},
      session_time => time(),
  };
  $self->cache_write( type => 'session', data => $session );

  return;
}

sub session_id {
  my $self = shift;

# warn "Known session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  $self->read_session();
# warn "Preexisting session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  my $result = $self->call(empire => login => $self->{empire_name}, $self->{empire_password}, $self->{api_key});
# warn "Created session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  croak "Couldn't get session_id";
}

sub empire_status {
  my $self = shift;

  my $result = $self->cache_read( type => 'empire_status', stale => 610 );
  $result && return $result;

  $result = $self->call(empire => login => $self->{empire_name}, $self->{empire_password}, $self->{api_key})->{status}{empire};
  return $result || croak "Couldn't get empire status";
}

sub match_planet {
  my $self = shift;
  my $name = shift;
  my $planets = $self->empire_status->{planets};
  my @candidates = grep { $planets->{$_} =~ /$name/ } keys %$planets;
  return $candidates[0] if @candidates == 1;
  LacunaRPCException->throw(code => 1002, text => "Planet name $name not found") unless @candidates;
  LacunaRPCException->throw(code => 1002, text => "Planet name $name is ambiguous",
                            data => JSON::PP->new->allow_nonref->canonical->pretty->encode([ map { $planets->{$_} } @candidates ]));
}

sub body_status {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'body_status', id => $body_id, stale => 500 );
  return $result if $result;

  $self->cache_invalidate( type => 'buildings', id => $body_id );
  $result = $self->body_buildings($body_id)->{status}{body};
  return $result || croak "Couldn't get body status";
}

sub body_buildings {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'buildings', id => $body_id );
  return $result if $result;

  $result = $self->call(body => get_buildings => $body_id);
  my @completions;
  for my $building (values(%{$result->{buildings}})) {
    push(@completions, parse_time($building->{pending_build}{end})) if $building->{pending_build};
    push(@completions, parse_time($building->{work         }{end})) if $building->{work};
  }
  my $invalid = List::Util::min(time() + 3600, @completions);
  $self->cache_write( type => 'buildings', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub body_buildable {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'buildable', id => $body_id );
  return $result if $result;

  $result = $self->call(body => get_buildable => $body_id);
  my $buildings = $self->body_buildings($body_id);
  my @completions;
  for my $building (values(%{$buildings->{buildings}})) {
    next unless $building->{pending_build};
    # next unless $building->{name} =~ /Oversight|Ore Refinery|Intelligence|University/;
    push(@completions, parse_time($building->{pending_build}{end}));
  }
  my $body = $self->body_status($body_id);
  if ($body->{incoming_foreign_ships}) {
    push(@completions, map { parse_time($_->{date_arrives}) } @{$body->{incoming_foreign_ships}});
  }
  my $invalid = List::Util::max(time() + 30, List::Util::min(time() + 600, @completions));
  $self->cache_write( type => 'buildable', id => $body_id, invalid => $invalid, data => $result );
  return $result;
}

sub body_build {
  my $self = shift;
  my $body_id = shift;
  my $building_name = shift;
  my $sx = shift;
  my $sy = shift;

  my $url = "";
  my %plots;
  my $existing = $self->body_buildings($body_id);
  for my $building (values %{$existing->{buildings}}) {
    $plots{$building->{x},$building->{y}} = 1;
    $url = $building->{url} if $building->{name} eq $building_name;
  }
  my @plots;
  for my $x (-5 .. 5) {
    for my $y (-5 .. 5) {
      next if -1 <= $x && $x <= 1 && -1 <= $y && $y <= 1;
      # next if $x >= 3 && $y >= 3;
      push(@plots, [ $x, $y ]) unless $plots{$x,$y};
    }
  }
  my $place = $plots[int(rand(@plots))];
  $place = [ $sx, $sy ] if ($sx || $sy) && !$plots{$sx,$sy};

  $url ||= $self->body_buildable($body_id)->{buildable}{$building_name}{url};

  return $self->building_build($url, $body_id, @$place);
}

sub building_build {
  my $self = shift;
  my $url = shift;
  my $body_id = shift;
  my $x = shift;
  my $y = shift;

  # invalidate the buildable cache
  $self->cache_invalidate( type => 'buildable', id => $body_id );
  my $result = $self->call($url => build => $body_id, $x, $y);

  if ( $result ) {
    # invalidate the buildings cache
    $self->cache_invalidate( type => 'buildings', id => $body_id );

    # invalidate building caches if we upgrade oversight ministry or ore refinery
    if ( $url =~ /oversite|orerefinery/ ) {
      for my $id ( keys %{$self->body_buildings($result->{status}{body}{id})->{buildings}} ) {
        $self->cache_invalidate( type => 'building_stats', id => $id, level => $_ ) for ( 0 .. 30 );
      }
    }
  }

  return $result;
}

sub building_demolish {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->call($url => demolish => $building_id);
  $self->cache_invalidate( type => 'building_view', id => $building_id                );
  $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
  $self->cache_invalidate( type => 'buildable',     id => $result->{status}{body}{id} );
  return $result;
}

sub building_upgrade {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  if ( my $result = eval { $self->call($url => upgrade => $building_id); } ) {
      $self->cache_invalidate( type => 'building_view', id => $building_id                );
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'buildable',     id => $result->{status}{body}{id} ) if $url =~ /oversight|orerefinery|intelligence|university/;

      # invalidate the buildings cache
      $self->cache_invalidate( type => 'buildings', id => $result->{status}{body}{id} );

      # invalidate building caches if we upgrade oversight ministry or ore refinery
      if ( $url =~ /oversite|orerefinery/ ) {
          for my $id ( keys %{$self->body_buildings($result->{status}{body}{id})->{buildings}} ) {
              $self->cache_invalidate( type => 'building_stats', id => $id, level => $_ ) for ( 0 .. 30 );
          }
      }
      return $result;
  }
  else {
    if (my $e = Exception::Class->caught('LacunaRPCException')) {
      if ($e->code eq 1011 || $e->code eq 1012) {
        # Not enough X in storage / production
        $self->cache_invalidate( type => 'building_view', id => $building_id                );
      }
      $e->rethrow;
    }
    else {
      my $e = Exception::Class->caught();
      ref $e ? $e->rethrow : die $e;
    }
  }
}

sub body_subsidize {
  my $self = shift;
  my $body_id = shift;

  my $dev = $self->find_building($body_id, "Development Ministry");
  my $result = $self->call(development => subsidize_build_queue => $dev->{id});
  $self->cache_invalidate(type => "buildings", id => $body_id);
  $self->cache_invalidate(type => "buildable", id => $body_id);
  return $result;
}

sub halls_sacrifice {
  my $self = shift;
  my $hall_id = shift;
  my $building_id = shift;

  my $result = eval { $self->call(hallsofvrbansk => sacrifice_to_upgrade => $hall_id, $building_id); };
  $self->cache_invalidate( type => 'building_view', id => $building_id                );
  $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
  return $result;
}

sub building_repair {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->call($url => repair => $building_id);
  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'building_view', id => $building_id );
  }
  return $result;
}

sub building_view {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->cache_read( type => 'building_view', id => $building_id );
  return $result if $result;

  $result = $self->call($url, view => $building_id);
  my @completions;
  for my $building ($result->{building}) {
    push(@completions, parse_time($building->{pending_build}{end})) if $building->{pending_build};
    push(@completions, parse_time($building->{work         }{end})) if $building->{work};
  }
  push(@completions, time() + 300) unless $result->{building}{upgrade}{can};
  my $invalid = List::Util::min(time() + 3600, @completions);

  $self->cache_write( type => 'building_view', id => $building_id, invalid => $invalid, data => $result );
  return $result;
}

sub building_stats_for_level {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;
  my $level = shift;

  my $result = $self->cache_read( type => 'building_stats', id => $building_id, level => $level );
  return $result if $result;

  $result = $self->call($url, get_stats_for_level => $building_id, $level);
  $self->cache_write( type => 'building_stats', id => $building_id, level => $level, data => $result );
  return $result;
}

sub find_building {
  my $self  = shift;
  my $where = shift;
  my $name  = shift;
  my $level = shift;

  my $buildings = $self->body_buildings($where);
  my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

  @buildings = grep { $_->{name}  eq $name  } @buildings;
  @buildings = grep { $_->{level} == $level } @buildings if $level;
  my @sorted = sort { $a->{level} <=> $b->{level} } @buildings;

  if (wantarray()) {
    return @sorted;
  } else {
    return $sorted[$#sorted] if @sorted;
    LacunaRPCException->throw(code => 1002, text => "$name not found",
                              data => JSON::PP->new->allow_nonref->canonical->pretty->encode({body_id => $where, name => $name, level => $level}));
  }
}

sub park_party {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->call(park => throw_a_party => $building_id);

  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'building_view', id => $building_id );
  }
  return $result;
}

sub themepark_operate {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->call(themepark => operate => $building_id);

  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'building_view', id => $building_id );
  }
  return $result;
}

sub recycle_recycle {
  my $self = shift;
  my $building_id = shift;
  my $water = shift;
  my $ore = shift;
  my $energy = shift;

  my $result = $self->call(wasterecycling => recycle => $building_id, $water, $ore, $energy, 0);
  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'building_view', id => $building_id );
  }
  return $result;
}

sub archaeology_search {
  my $self = shift;
  my $building_id = shift;
  my $ore = shift;

  my $result = $self->call(archaeology => search_for_glyph => $building_id, $ore);
  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'building_view', id => $building_id );
  }
  return $result;
}

sub ores_for_search {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->call(archaeology => get_ores_available_for_processing => $building_id);
  return $result;
}

sub get_glyphs {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->call(archaeology => get_glyphs => $building_id);
  return $result;
}

sub port_all_ships {
  my $self = shift;
  my $building_id = shift;

  my $body_id;
  my $planets = $self->empire_status->{planets};
  if ($planets->{$building_id}) {
    $body_id = $building_id;
    $building_id = $self->find_building($body_id, "Space Port")->{id};
  } else {
    $body_id = $self->building_view(spaceport => $building_id)->{status}{body}{id};
  }

  my $result = $self->cache_read( type => 'spaceport_view_all_ships', id => $body_id, stale => 3600 );
  return $result if $result;

  my @ships;
  $result = $self->call(spaceport => view_all_ships => $building_id, { no_paging => 1 });
  push(@ships, @{$result->{ships}});
  $result->{ships} = [ @ships ];
  my @completions;
  for my $ship (@{$result->{ships}}) {
    if ($ship->{date_available}) {
      my $available = parse_time($ship->{date_available});
      push(@completions, $available) if $available > time() + 30;
    }
    push(@completions, parse_time($ship->{date_arrives})) if $ship->{date_arrives};
  }
  my $invalid = List::Util::min(time() + 3600, @completions);
  $self->cache_write( type => 'spaceport_view_all_ships', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub get_probed_stars {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->cache_read( type => 'observatory_get_probed_stars', id => $building_id );
  return $result if $result;

  my $page = 1;
  my @stars;
  for (;;) {
    $result = $self->call(observatory => get_probed_stars => $building_id, $page);
    push @stars, @{$result->{stars}};
    last if @{$result->{stars}} < 25;
    $page++;
  }
  $result->{stars} = \@stars;
  my $invalid = time() + 600;
  $self->cache_write( type => 'observatory_get_probed_stars', id => $building_id, data => $result, invalid => $invalid );
  return $result;
}

sub ships_for {
  my $self = shift;
  my $planet = shift;
  my $target = shift;

  my $result = $self->call(spaceport => get_ships_for => $planet, $target);
  return $result;
}

sub send_ship {
  my $self = shift;
  my $ship = shift;
  my $target = shift;

  my $result = $self->call(spaceport => send_ship => $ship, $target);
  return $result;
}

sub send_fleet {
  my $self = shift;
  my $ships = shift;
  my $target = shift;

  my $result = $self->call(spaceport => send_fleet => $ships, $target);
  return $result;
}

sub send_spies {
  my $self = shift;
  my $from = shift;
  my $to = shift;
  my $ship = shift;
  my $spies = shift;

  my $result = $self->call(spaceport => send_spies => $from, $to, $ship, $spies);
  return $result;
}

sub fetch_spies {
  my $self = shift;
  my $from = shift;
  my $to = shift;
  my $ship = shift;
  my $spies = shift;

  my $result = $self->call(spaceport => fetch_spies => $from, $to, $ship, $spies);
  return $result;
}

sub yard_queue {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->cache_read( type => 'shipyard_view_build_queue', id => $building_id );
  return $result if $result;
  my $page = 1;
  my @ships;
  for (;;) {
    $result = $self->call(shipyard => view_build_queue => $building_id, $page);
    push(@ships, @{$result->{ships_building}});
    last if @{$result->{ships_building}} < 25;
    $page++;
  }
  $result->{ships_building} = [ @ships ];
  my @completions;
  for my $ship (@{$result->{ships_building}}) {
    if ($ship->{date_completed}) {
      my $available = parse_time($ship->{date_completed});
      push(@completions, $available) if $available > time() + 30;
    }
    push(@completions, parse_time($ship->{date_arrives})) if $ship->{date_arrives};
  }
  my $invalid = List::Util::min(time() + 3600, @completions);
  $self->cache_write( type => 'shipyard_view_build_queue', id => $building_id, data => $result, invalid => $invalid );
  return $result;
}

sub yard_buildable {
  my $self = shift;
  my $yard_id = shift;

  my $result = $self->cache_read( type => 'buildable', id => $yard_id );
  return $result if $result;
  $result = $self->call(shipyard => get_buildable => $yard_id);

  # Building completions can affect shipyard builds
  my $body_id = $result->{status}{body}{id};
  my $buildings = $self->body_buildings($body_id);
  my @completions;
  for my $building (values(%{$buildings->{buildings}})) {
    next unless $building->{pending_build};
    push(@completions, parse_time($building->{pending_build}{end}));
  }

  my $invalid = List::Util::max(time() + 30, List::Util::min(time() + 600, @completions));
  $self->cache_write( type => 'buildable', id => $yard_id, data => $result, invalid => $invalid );
  return $result;
}

sub yard_build {
  my $self = shift;
  my $building_id = shift;
  my $type = shift;
  my $count = shift || 1;

  my $result = $self->call(shipyard => build_ship => $building_id, $type, $count);
  $self->cache_invalidate( type => 'buildable', id => $building_id );
  $self->cache_invalidate( type => 'shipyard_view_build_queue', id => $building_id );
  return $result;
}

sub trade_push {
  my $self = shift;
  my $building_id = shift;
  my $target_id = shift;
  my $items = shift;
  my $options = shift;

  my $result = $self->call(trade => push_items => $building_id, $target_id, $items, $options);
  if ($result) {
    $self->cache_invalidate( type => 'body_status', id => $target_id );
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $target_id );
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
  }
  return $result;
}

sub transporter_push {
  my $self = shift;
  my $building_id = shift;
  my $target_id = shift;
  my $items = shift;

  my $result = $self->call(transporter => push_items => $building_id, $target_id, $items);
  if ($result) {
    $self->cache_invalidate( type => 'body_status', id => $target_id );
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $target_id );
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
  }
  return $result;
}

sub depot_transmit {
  my $self = shift;
  my $building_id = shift;
  my $type = shift;

  my $result = $self->call(subspacesupplydepot => "transmit_$type" => $building_id);
  if ($result) {
    $self->cache_invalidate( type => 'body_buildable', id => $building_id );
  }
  return $result;
}

sub map_get_stars {
  my ($self, $x1, $y1, $x2, $y2) = @_;
  my $result = $self->call('map' => get_stars => $x1, $y1, $x2, $y2);
  return $result;
}

sub mission_list {
  my ($self, $where) = @_;
  my $result = $self->cache_read( type => 'mission_list', id => $where );
  return $result if $result;

  $result = $self->call(missioncommand => get_missions => $where);

  my $invalid = time() + 600;
  $self->cache_write( type => 'mission_list', id => $where, data => $result, invalid => $invalid );
  return $result;
}

sub mission_complete {
  my ($self, $where, $which) = @_;
  $self->cache_invalidate(type => 'mission_list', id => $where);
  my $mission = first { $_->{id} eq $which } @{$self->mission_list($where)->{missions}};
  my $result = $self->call(missioncommand => complete_mission => $where, $which);
  if (grep { /speed.*stealth.*hold size.*combat/ } (@{$mission->{rewards}}, @{$mission->{objectives}})) {
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
  }
  return $result;
}

sub mission_skip {
  my ($self, $where, $mission) = @_;
  $self->cache_invalidate(type => 'mission_list', id => $where);
  return $self->call(missioncommand => skip_mission => $where, $mission);
}

sub spy_list {
  my ($self, $where) = @_;
  my $result = $self->cache_read( type => 'spy_list', id => $where );
  return $result if $result;

  my $intel = $self->find_building($where, "Intelligence Ministry");

  my @spies;
  my $result;
  for my $page (1..30) {
    $result = $self->call(intelligence => view_spies => $intel->{id}, $page);
    push(@spies, @{$result->{spies}});
    $result->{spies} = \@spies;
    last if $result->{spy_count} <= $page * 25;
  }

  my @completions = map { parse_time($_->{available_on}) } grep { !($_->{is_available}) } @{$result->{spies}};
  my $invalid = List::Util::max(time() + 30, List::Util::min(time() + (20 * 60 * 60), @completions));

  $self->cache_write( type => 'spy_list', id => $where, data => $result, invalid => $invalid );
  return $result;
}

sub spy_train {
  my ($self, $where, $count) = @_;
  my $result = $self->call(intelligence => train_spy => $where, $count);
  $self->cache_invalidate(type => 'spy_list', id => $result->{status}{body}{id});
  return $result;
}

sub spy_burn {
  my ($self, $where, $who) = @_;
  my $result = $self->call(intelligence => burn_spy => $where, $who);
  $self->cache_invalidate(type => 'spy_list', id => $result->{status}{body}{id});
  return $result;
}

sub spy_name {
  my ($self, $where, $who, $what) = @_;
  my $result = $self->call(intelligence => name_spy => $where, $who, $what);
  $self->cache_invalidate(type => 'spy_list', id => $result->{status}{body}{id});
  return $result;
}

sub spy_assign {
  my ($self, $where, $who, $what) = @_;
  my $result = $self->call(intelligence => assign_spy => $where, $who, $what);
  $self->cache_invalidate(type => 'spy_list', id => $result->{status}{body}{id});
  return $result;
}

sub present_captcha {
  my ($self, $captcha) = @_;
  $captcha ||= $self->call(captcha => "fetch");
  for (;;) {
    warn("Fetched captcha guid $captcha->{guid}\n");
    my $c_response = $self->{ua}->get($captcha->{url});
    my $image = $c_response->content;
    my $filename = $captcha->{url};
    $filename =~ s-.*/-captcha/-;
    -d 'captcha' or mkdir 'captcha';
    my $file;
    open($file, ">", $filename) or die "Couldn't write captcha image: $filename: $!\n";
    print $file $image;
    close($file);
    open($file, "-|", "$self->{captcha_program} $filename") or die "Couldn't run captcha presenter: $!\n";
    my $answer = <$file>;
    close($file);
    chomp $answer;
    $answer =~ s/^ANSWER: //;
    if (!$answer) {
      $captcha = $self->call(captcha => "fetch");
      next;
    }
    my $response = eval { $self->call(captcha => solve => $captcha->{guid}, $answer) };
    if ($response eq "wrong") {
      open($file, ">", "$filename.wrong") or die "Couldn't write captcha answer: $!\n";
      print $file "$answer\n";
      close($file);
      warn("Failed captcha guid $captcha->{guid}\n");
    } else {
      open($file, ">", "$filename.answer") or die "Couldn't write captcha answer: $!\n";
      print $file "$answer\n";
      close($file);
      warn("Solved captcha guid $captcha->{guid}\n");
    }
    last;
  }
}

{
    my %path_for = (
        empire_status                => 'empire/status',
        body_status                  => 'body/%d/status',
        buildings                    => 'body/%d/buildings',
        buildable                    => 'body/%d/buildable',
        spy_list                     => 'body/%d/spy_list',
        building_view                => 'building/%d/view',
        building_stats               => 'building/%d/stats_%d',
        spaceport_view_all_ships     => 'body/%d/view_all_ships',
        observatory_get_probed_stars => 'building/%d/get_probed_stars',
        shipyard_view_build_queue    => 'building/%d/view_build_queue',
        mission_list                 => 'building/%d/mission_list',
        session                      => 'session',
        misc                         => 'misc/%s',
    );

    sub _cache_path {
        my ($self, $type, $id, $level) = @_;

        my ($host) = ( $self->{uri} =~ m|^\w+://(\w+)\.lacunaexpanse\.com$|i );
        my $name = $self->{empire_name};
        $name =~ s/\W/_/g;
        my $result = sprintf "$self->{cache_root}/%s_%s/$path_for{ $type }", grep { defined $_ } $name, $host, $id, $level;
        $result = File::Spec->catfile(split(/\//, $result));
        return $result;
    }
}

sub cache_read {
    my ($self, %args) = @_;

    my $result = $self->read_json( $self->_cache_path( $args{type}, $args{id}, $args{level} ) );

    # short-circuit
    return unless $result;

    my $now = time();
    if (
        ($result->{_invalid} && ( $result->{_invalid} < $now ))                     # cache expired
        or                                                                          # or
        ($args{stale}        && ( $result->{_time}    <= ( $now - $args{stale} ) )) # cache is stale
    ) {
        unlink $self->_cache_path( $args{type}, $args{id}, $args{level} );
        return;
    }

    return $result;
}

sub cache_write {
    my ($self, %args) = @_;

    $args{data}{_time} = time();
    $args{data}{_invalid} = $args{invalid} if $args{invalid};

    my $cache_file = $self->_cache_path( $args{type}, $args{id}, $args{level} );
    $self->write_json( $cache_file , $args{type}, $args{data} );

    return;
}

sub cache_invalidate {
    my ($self, %args) = @_;
    unlink $self->_cache_path( $args{type}, $args{id} );
    return;
}

sub select_exchange {
  my $self     =   $_[0];
  my %existing = %{$_[1]};
  my %extra    = %{$_[2]};
  my %wanted   = %{$_[3]};

  # ::emit(join("\n", "Need to balance ".List::Util::sum(values(%wanted)).":", map { sprintf("%9d %s", $wanted{$_}, $_) } sort keys %wanted));
  # ::emit(join("\n", "Can work with ".List::Util::sum(values(%extra)).":", map { sprintf("%9d %s", $extra{$_}, $_) } sort keys %extra));


  my $amount;
  my %giving;
  my $iteration = 0;
  while (($amount = List::Util::sum(values(%wanted)) - List::Util::sum(values(%giving))) > 0) {
    return if $iteration++ > 150;
    my @ordered = sort { $existing{$a} + $giving{$a} <=> $existing{$b} + $giving{$b} } grep { $giving{$_} < $extra{$_} } keys(%extra);
    # ::emit("Ordered resources: ". join(", ", @ordered));
    # ::emit(join("\n", "Ordered resources:", map { sprintf("%9d %s", $existing{$_} + $giving{$_}, $_) } @ordered));
    last unless @ordered;
    my $top = 1;
    $top++ while $existing{$ordered[$top]} + $giving{$ordered[$top]} == $existing{$ordered[0]} + $giving{$ordered[0]};
    # ::emit("Top: $top, remaining: $amount");
    if ($amount >= $top) {
      my $step;
      if ($top < @ordered) {
        $step = List::Util::min((map { $extra{$_} - $giving{$_} } @ordered[0..($top-1)]), 
                                ($existing{$ordered[$top]} + $giving{$ordered[$top]}) - ($existing{$ordered[0]} + $giving{$ordered[0]}),
                                int($amount / $top));
        $giving{$_} += $step for @ordered[0..($top-1)];
      } else {
        $step = List::Util::min((map { $extra{$_} - $giving{$_} } @ordered[0..($top-1)]), 
                                int($amount / $top));
        $giving{$_} += $step for @ordered[0..($top-1)];
      }
    } else {
      $giving{$_}++ for @ordered[0..($amount-1)];
    }
    # ::emit(join("\n", "Giving resources:", map { sprintf("%9d %s", $giving{$_}, $_) } keys(%giving)));
  }
  return %giving;
}

1;
