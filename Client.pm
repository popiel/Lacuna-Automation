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
  unless ($self->{ua}) {
    $self->{ua} = LWP::UserAgent->new();
    $self->{ua}->agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36");
  }
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
  my $result = eval { decode_json($json) };
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
  for my $key (qw(empire_name empire_password uri api_key cache_root captcha_program email_forward)) {
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

sub format_bignum {
  my $num = shift;
  my $str = sprintf("%0.0f ", $num);
  1 while $str =~ s/(\d)(\d\d\d)(\D)/$1,$2$3/;
  chop $str;
  return $str;
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
  my $pathname = File::Spec->catfile($dir, $filename);
  $pathname =~ s/:/-/g if $pathname =~ /\\/;
  my $file;
  open($file, ">:utf8", $pathname) or croak "Could not log call: $pathname: $!";
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

  # Short-circuit: if we already hit the max-requests limit during the current
  # wall-time hour, return the cached exception instead of making an RPC call
  # that we know will fail.
  my $rpc_limit_cache = $self->cache_read(type => 'misc', id => 'rpc_limit');
  if ($rpc_limit_cache && $rpc_limit_cache->{rpc_exceeded}) {
    my $now_hour = int(time() / 3600);
    my $cache_hour = int(($rpc_limit_cache->{_time} // 0) / 3600);
    if ($cache_hour == $now_hour) {
      warn "Out of requests (cached). Skipping RPC call $api/$method.\n";
      LacunaRPCException->throw(code => 1010,
                                text => "You have already made the maximum number of requests (10000) you can make for one day. (cached)",
                                data => JSON::PP->new->allow_nonref->canonical->pretty->encode({message => "maximum number of requests"}));
    }
  }

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
  if (ref $result->{result}{status} eq 'HASH') {
    my $status = $result->{result}{status};
    if (ref $status->{server} eq 'HASH') {
      $self->{server_status} = $status->{server};
      $self->{rpc_limit} = $status->{server}{rpc_limit} if exists($status->{server}{rpc_limit});
    }
    if (ref $status->{empire} eq 'HASH' && exists($status->{empire}{rpc_count})) {
      $self->{rpc_count} = $status->{empire}{rpc_count};
    }
  }
  my $time = parse_time($result->{result}{status}{server}{time});
  $result->{result}{status}{_time} = $time;
  my $empire = $result->{result}{status}{empire};
  if ($empire) {
    $self->cache_write( type => 'empire_status', data => $empire );
    eval {
      my $message_id = $empire->{latest_message_id} || eval { $empire->{most_recent_message}{id} };
      if ($message_id && $message_id ne $self->cache_read( type => 'mail_inbox' )->{messages}[0]{id}) {
        # print "Invalidating mailbox: new $empire->{most_recent_message}{id} ne cached ".($self->cache_read( type => 'mail_inbox' )->{messages}[0]{id})."\n";
        $self->cache_invalidate( type => 'mail_inbox' );
      }
    };
  }
  my $body = $result->{result}{status}{body};
  if ($body) {
    # Both foreign and own arrivals change the body (enemy presence, or
    # trade ships delivering stores), so the snapshot expires when the
    # next ship of either kind lands.
    my @arrivals = map { parse_time($_->{date_arrives}) }
                       @{ $body->{incoming_foreign_ships} || [] },
                       @{ $body->{incoming_own_ships}     || [] };
    @arrivals = grep { $_ && $_ > time() } @arrivals;
    my $invalid = List::Util::min(time() + 3600, @arrivals);
    # Stamp the cached copy with _time so cache_read's staleness check and
    # estimated_body_status can tell how old the snapshot is; the original
    # status wrapper keeps its own _time.
    my $body_cache = { %$body, _time => $time };
    $self->cache_write( type => 'body_status', id => $body->{id}, data => $body_cache, invalid => $invalid );
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

  $result = $self->call(empire => login => $self->{empire_name}, $self->{empire_password}, $self->{api_key});
  $self->{server_status} = $result->{status}{server} if $result->{status}{server};
  $result = $result->{status}{empire};
  return $result || croak "Couldn't get empire status";
}

sub empire_public_profile {
  my $self = shift;
  my $id = shift;

  my $result = $self->cache_read( type => 'empire_profile', id => $id, stale => 86400 );
  $result && return $result;

  $result = $self->call(empire => view_public_profile => $id);
  $self->cache_write( type => 'empire_profile', id => $id, data => $result, invalid => time() + 86400 );
  return $result;
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
  $self->_note_university_level($body_id, $result);
  return $result;
}

# A university upgrade only raises its level when it completes, and that
# re-opens the upgradeability of every building that was capped at
# 'university level + 1'.  The building_view caches hold those denials for
# up to an hour, so detect the level change here - body_buildings refetches
# right when the university's pending build completes - and sweep them.
sub _note_university_level {
  my ($self, $body_id, $result) = @_;

  my ($uni) = grep { ($_->{name} // '') eq 'University' } values %{$result->{buildings}};
  return unless $uni;

  my $key   = "university_level_$body_id";
  my $known = $self->cache_read( type => 'misc', id => $key );
  return if $known && $known->{level} == $uni->{level};

  $self->cache_write( type => 'misc', id => $key, data => { level => $uni->{level} } );
  return unless $known;
  for my $id ( keys %{$result->{buildings}} ) {
    $self->cache_invalidate( type => 'building_view', id => $id );
  }
  return;
}

# Estimate a body's current resource stores by advancing the newest cached
# status snapshot with its own production rates.  Read-only: never makes an
# RPC call, and reads cache files directly, so even expired entries still
# yield a usable snapshot.  Returns a status hash like body_status with the
# *_stored fields replaced by estimates, or undef when nothing has ever
# been cached for this body.  The returned hash has no _time stamp - treat
# it as a snapshot of right now.
sub estimated_body_status {
  my $self = shift;
  my $body_id = shift;

  my ($snap, $snap_time);
  for my $type (qw(body_status buildings)) {
    my $entry = $self->read_json( $self->_cache_path( $type, $body_id ) ) or next;
    my $status = $type eq 'buildings' ? $entry->{status}{body} : $entry;
    next unless $status && $entry->{_time};
    if (!$snap || $entry->{_time} > $snap_time) {
      $snap      = $status;
      $snap_time = $entry->{_time};
    }
  }
  return unless $snap;

  my $status = { %$snap };
  delete $status->{_time};
  my $elapsed = time() - $snap_time;
  $elapsed = 0 if $elapsed < 0;
  for my $res (qw(food ore water energy waste)) {
    next unless defined $snap->{"${res}_stored"};
    my $est = $snap->{"${res}_stored"} + ($snap->{"${res}_hour"} // 0) * $elapsed / 3600;
    $est = 0 if $est < 0;
    $est = $snap->{"${res}_capacity"} if defined $snap->{"${res}_capacity"} && $est > $snap->{"${res}_capacity"};
    $status->{"${res}_stored"} = int($est);
  }
  return $status;
}

# Fold a delta of stored resources into whatever status snapshots are cached
# for a body, in place, without any RPC.  Only entries that exist are
# touched, and only the listed types - callers must not adjust a snapshot
# that the server has already re-reported post-mutation.
sub _adjust_body_stores {
  my $self = shift;
  my $body_id = shift;
  my $deltas = shift;
  my @types = @_;

  return unless $body_id && $deltas;
  @types = qw(buildings) unless @types;
  for my $type (@types) {
    my $path = $self->_cache_path( $type, $body_id );
    my $entry = $self->read_json( $path ) or next;
    my $status = $type eq 'buildings' ? $entry->{status}{body} : $entry;
    next unless $status;
    my $changed;
    for my $res ( keys %$deltas ) {
      next unless defined $status->{"${res}_stored"};
      $status->{"${res}_stored"} += $deltas->{$res};
      $status->{"${res}_stored"} = 0 if $status->{"${res}_stored"} < 0;
      $changed = 1;
    }
    $self->write_json( $path, $type, $entry ) if $changed;
  }
  return;
}

sub body_buildable {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'buildable', id => $body_id );
  return $result if $result;

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
  if ($body->{incoming_own_ships}) {
    push(@completions, map { parse_time($_->{date_arrives}) } @{$body->{incoming_own_ships}});
  }

  my %plots;
  for my $building (values %{$buildings->{buildings}}) {
    $plots{$building->{x},$building->{y}} = 1;
  }
  my @plots;
  for my $x (-5 .. 5) {
    for my $y (-5 .. 5) {
      # next if $x >= 3 && $y >= 3;
      push(@plots, [ $x, $y ]) unless $plots{$x,$y};
    }
  }

  $result = $self->call(body => get_buildable => $body_id, $plots[0][0], $plots[0][1]);

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
    $self->cache_invalidate( type => 'plans',     id => $body_id );

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
      $self->cache_invalidate( type => 'plans',         id => $result->{status}{body}{id} );
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
  $self->cache_invalidate( type => 'plans',         id => $result->{status}{body}{id} );
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
  if (!$result->{building}{upgrade}{can}) {
    my $code = $result->{building}{upgrade}{reason}[0];
    push(@completions, time() + 3600) if $code == 1009 || $code == 1013;
  }
  my $invalid = List::Util::min(time() + 3600, @completions);

  $self->cache_write( type => 'building_view', id => $building_id, invalid => $invalid, data => $result );
  return $result;
}

sub building_view_cached {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->read_json( $self->_cache_path( 'building_view', $building_id ) ) or return;
  return ($result->{_invalid} && $result->{_invalid} > time()) ? $result : undef;
}

sub cache_building_denial {
  my ($self, $building_id, $code, $text) = @_;

  return unless defined $code && grep { $code == $_ } 1009, 1011, 1012, 1013;
  my $ttl = ($code == 1009 || $code == 1013) ? 3600 : 300;
  $self->cache_write( type    => 'building_view',
                      id      => $building_id,
                      data    => { building => { upgrade => { can => 0, reason => [ $code, $text ] } } },
                      invalid => time() + $ttl );
  return;
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

sub body_plans {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'plans', id => $body_id );
  return $result if $result;

  # Trade and transporter are preferred because of the inclusion of cargo size and plan_type
  # The last one is not in an eval so that fundamental exceptions (e.g. login failure) propagate
  $result = eval { $self->call(trade            => get_plan_summary => scalar($self->find_building($body_id, "Trade Ministry"          ))->{id}) } ||
            eval { $self->call(transporter      => get_plan_summary => scalar($self->find_building($body_id, "Subspace Transporter"    ))->{id}) } ||
                   $self->call(planetarycommand => view_plans       => scalar($self->find_building($body_id, "Planetary Command Center"))->{id});

  my @arrivals;
  for my $type (qw(incoming_own_ships incoming_enemy_ships incoming_ally_ships incoming_foreign_ships)) {
    next unless $result->{status}{body}{$type};
    for my $ship (@{$result->{status}{body}{$type}}) {
      push(@arrivals, parse_time($ship->{date_arrives}));
    }
  }
  my $invalid = List::Util::min(time() + 3600, @arrivals);
  $self->cache_write( type => 'plans', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub body_waste_chain {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'waste_chain', id => $body_id );
  return $result if $result;

  $result = $self->call(trade => view_waste_chains => scalar($self->find_building($body_id, "Trade Ministry"))->{id});

  my $invalid = time() + (23 * 3600);
  $self->cache_write( type => 'waste_chain', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub add_waste_ship_to_fleet {
  my $self = shift;
  my $body_id = shift;
  my $ship_id = shift;

  my $result = $self->call(trade => add_waste_ship_to_fleet =>
                           scalar($self->find_building($body_id, "Trade Ministry"))->{id}, $ship_id);
  $self->cache_invalidate( type => 'waste_chain',               id => $body_id );
  $self->cache_invalidate( type => 'spaceport_view_all_ships',  id => $body_id );
  return $result;
}

sub remove_waste_ship_from_fleet {
  my $self = shift;
  my $body_id = shift;
  my $ship_id = shift;

  my $result = $self->call(trade => remove_waste_ship_from_fleet =>
                           scalar($self->find_building($body_id, "Trade Ministry"))->{id}, $ship_id);
  $self->cache_invalidate( type => 'waste_chain',               id => $body_id );
  $self->cache_invalidate( type => 'spaceport_view_all_ships',  id => $body_id );
  return $result;
}

sub scuttle_ship {
  my $self = shift;
  my $body_id = shift;
  my $ship_id = shift;

  my $result = $self->call(spaceport => scuttle_ship =>
                           scalar($self->find_building($body_id, "Space Port"))->{id}, $ship_id);
  $self->cache_invalidate( type => 'spaceport_view_all_ships',  id => $body_id );
  return $result;
}

sub name_ship {
  my $self = shift;
  my $body_id = shift;
  my $ship_id = shift;
  my $name = shift;

  my $result = $self->call(spaceport => name_ship =>
                           scalar($self->find_building($body_id, "Space Port"))->{id}, $ship_id, $name);
  $self->cache_invalidate( type => 'spaceport_view_all_ships',  id => $body_id );
  return $result;
}

sub view_excavators {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'excavators', id => $body_id );
  return $result if $result;

  # Trade and transporter are preferred because of the inclusion of cargo size
  # The last one is not in an eval so that fundamental exceptions (e.g. login failure) propagate
  $result = $self->call(archaeology => view_excavators => scalar($self->find_building($body_id, "Archaeology Ministry"))->{id});

  my @travelling;
  if ($result->{travelling}) {
    my $ships = $self->port_all_ships($body_id);
    @travelling = grep { $_->{type} eq "excavator" && $_->{task} eq "Travelling" } @{$ships->{ships}};
    if ($result->{travelling} != @travelling) {
      $self->cache_invalidate( type => 'spaceport_view_all_ships',  id => $body_id );
      my $ships = $self->port_all_ships($body_id);
      @travelling = grep { $_->{type} eq "excavator" && $_->{task} eq "Travelling" } @{$ships->{ships}};
    }
  }
  my @arrivals = map { parse_time($_->{date_arrives}) } @travelling;
  my $invalid = List::Util::min(time() + (23 * 3600), @arrivals);
  $self->cache_write( type => 'excavators', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub glyph_list {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->cache_read( type => 'glyphs', id => $body_id );
  return $result if $result;

  # Trade and transporter are preferred because of the inclusion of cargo size
  # The last one is not in an eval so that fundamental exceptions (e.g. login failure) propagate
  $result = eval { $self->call(trade       => get_glyph_summary => scalar($self->find_building($body_id, "Trade Ministry"      ))->{id}) } ||
            eval { $self->call(transporter => get_glyph_summary => scalar($self->find_building($body_id, "Subspace Transporter"))->{id}) } ||
                   $self->call(archaeology => get_glyph_summary => scalar($self->find_building($body_id, "Archaeology Ministry"))->{id});

  my @arrivals;
  for my $type (qw(incoming_own_ships incoming_enemy_ships incoming_ally_ships incoming_foreign_ships)) {
    next unless $result->{status}{body}{$type};
    for my $ship (@{$result->{status}{body}{$type}}) {
      push(@arrivals, parse_time($ship->{date_arrives}));
    }
  }
  my $invalid = List::Util::min(time() + 3600, @arrivals);
  $self->cache_write( type => 'glyphs', id => $body_id, data => $result, invalid => $invalid );
  return $result;
}

sub glyph_assemble {
  my $self = shift;
  my $body_id = shift;
  my $recipe = shift;
  my $count = @_ ? shift : 1;

  my $arch = $self->find_building($body_id, "Archaeology Ministry");
  my $result = $self->call(archaeology => assemble_glyphs => $arch->{id}, $recipe, $count);
  if ($result) {
    $self->cache_invalidate( type => 'plans',  id => $result->{status}{body}{id} );
    $self->cache_invalidate( type => 'glyphs', id => $result->{status}{body}{id} );
  }
  return $result;
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
  my $type = shift || "wasterecycling";

  my $result = $self->call($type => recycle => $building_id, $water, $ore, $energy, 0);
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
      $self->cache_invalidate( type => 'glyphs',        id => $result->{status}{body}{id} );
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
    $body_id = $self->building_stats_for_level(spaceport => $building_id, 1)->{status}{body}{id};
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
  # The list only changes when one of this observatory's own probes arrives
  # (handled by cache_revalidate with the probe's arrival time) or a probe is
  # abandoned (handled by abandon_probe), so it can be trusted a lot longer
  # than the 30-minute run cadence of probe_hunter.
  my $invalid = time() + 2400;
  $self->cache_write( type => 'observatory_get_probed_stars', id => $building_id, data => $result, invalid => $invalid );
  return $result;
}

sub abandon_probe {
  my $self = shift;
  my $building_id = shift;
  my $star_id = shift;

  my $result = $self->call(observatory => abandon_probe => $building_id, $star_id);
  $self->cache_invalidate( type => 'observatory_get_probed_stars', id => $building_id );
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
  if ($result) {
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
  }
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

  my $result = $self->cache_read( type => 'shipyard_buildable', id => $yard_id );
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

  # With no completions pending, a 30-minute TTL means at most one
  # get_buildable per hour per yard; resource-driven `can` changes are
  # estimated locally by callers.
  my $invalid = List::Util::max(time() + 30, List::Util::min(time() + 1800, @completions));
  $self->cache_write( type => 'shipyard_buildable', id => $yard_id, data => $result, invalid => $invalid );
  return $result;
}

sub yard_build {
  my $self = shift;
  my $building_id = shift;
  my $type = shift;
  my $count = shift || 1;

  my $result = $self->call(shipyard => build_ship => $building_id, $type, $count);
  if ($result) {
    # Building ships spends stored resources.  call() has already re-cached
    # the body_status from this response, so only the get_buildings
    # snapshot needs adjusting; adjusting both would subtract twice.
    if (my $buildable = $self->cache_read( type => 'shipyard_buildable', id => $building_id )) {
      my $cost = $buildable->{buildable}{$type}{cost} || {};
      my %deltas;
      for my $res (qw(food ore water energy)) {
        $deltas{$res} = -($cost->{$res} // 0) * $count if $cost->{$res};
      }
      $self->_adjust_body_stores( $result->{status}{body}{id}, \%deltas ) if %deltas;
    }
    $self->cache_invalidate( type => 'shipyard_buildable', id => $building_id );
    # The build response is the post-build build queue, so it can be cached
    # as one directly - no view_build_queue refetch needed.  Only trust it
    # when it is complete: the count of ships building must match the
    # entries (a paged or truncated response falls back to invalidation).
    my @ships = @{$result->{ships_building} // []};
    if (($result->{number_of_ships_building} // 0) == scalar(@ships)) {
      my @completions;
      for my $ship (@ships) {
        push(@completions, parse_time($ship->{date_completed})) if $ship->{date_completed};
      }
      my $invalid = List::Util::min(time() + 3600, @completions);
      $self->cache_write( type => 'shipyard_view_build_queue', id => $building_id, data => $result, invalid => $invalid );
    }
    else {
      $self->cache_invalidate( type => 'shipyard_view_build_queue', id => $building_id );
    }
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
  }
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
    my $sender_id = $result->{status}{body}{id};
    # The server deducts cargo from the sending body immediately; call()
    # has already re-cached its body_status from this response, so only the
    # get_buildings snapshot needs dropping here.
    $self->cache_invalidate( type => 'buildings', id => $sender_id );
    $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $sender_id );
    if (grep { $_->{type} eq "plan" } @$items) {
      $self->cache_invalidate( type => 'plans', id => $sender_id );
      $self->cache_invalidate( type => 'buildable', id => $sender_id );
    }
    if (grep { $_->{type} eq "glyph" } @$items) {
      $self->cache_invalidate( type => 'glyphs', id => $sender_id );
    }
    # The target gains the cargo only when the fleet arrives (CargoExchange
    # unloads on arrival), so its caches are tightened to the arrival time
    # rather than dropped now.  With no parseable arrival time, fall back
    # to dropping them.
    my $fleet = $result->{fleet} || {};
    my $arrival = parse_time($fleet->{date_arrives})
               || parse_time($fleet->{details}{date_available});
    my @target_types = qw(body_status buildings spaceport_view_all_ships plans glyphs);
    if ($arrival && $arrival > time()) {
      $self->cache_revalidate( type => $_, id => $target_id, invalid => $arrival ) for @target_types;
    }
    else {
      $self->cache_invalidate( type => $_, id => $target_id ) for @target_types;
    }
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
    # The subspace transporter transfers instantly - both bodies change
    # now.  call() has already re-cached the sender's body_status, so only
    # its get_buildings snapshot needs dropping.
    $self->cache_invalidate( type => 'buildings', id => $result->{status}{body}{id} );
    $self->cache_invalidate( type => 'body_status', id => $target_id );
    $self->cache_invalidate( type => 'buildings', id => $target_id );
    if (grep { $_->{type} eq "ship" } @$items) {
      $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $target_id );
      $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $result->{status}{body}{id} );
    }
    if (grep { $_->{type} eq "plan" } @$items) {
      $self->cache_invalidate( type => 'plans', id => $target_id );
      $self->cache_invalidate( type => 'plans', id => $result->{status}{body}{id} );
      $self->cache_invalidate( type => 'buildable', id => $result->{status}{body}{id} );
    }
    if (grep { $_->{type} eq "glyph" } @$items) {
      $self->cache_invalidate( type => 'glyphs', id => $target_id );
      $self->cache_invalidate( type => 'glyphs', id => $result->{status}{body}{id} );
    }
  }
  return $result;
}

sub depot_transmit {
  my $self = shift;
  my $building_id = shift;
  my $type = shift;

  my $result = $self->call(subspacesupplydepot => "transmit_$type" => $building_id);
  if ($result) {
    $self->cache_invalidate( type => 'buildable', id => $result->{status}{body}{id} );
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

sub spy_retrain {
  my ($self, $where, $who, $type) = @_;
  substr($type, 0, 1) =~ tr/a-z/A-Z/;
  my $trainer = $self->find_building($where, "$type Training");
  my $result = $self->call($trainer->{url} => train_spy => $trainer->{id}, $who);
  $self->cache_invalidate(type => 'spy_list', id => $result->{status}{body}{id});
  return $result;
}

# This will only cache the first page of mail.
# That's usually enough for non-interactive use;
# automated processes should be running frequently enough
# to only be interested in recent messages.
sub mail_inbox {
  my $self = shift;
  my $options = shift || {};
  my $result;
  if (!keys(%$options)) {
    $result = $self->cache_read( type => 'mail_inbox' );
    return $result if $result;
  }
  $result = $self->call( inbox => view_inbox => $options );
  if (!keys(%$options)) {
    $self->cache_write( type => 'mail_inbox', data => $result );
  }
  return $result;
}

sub mail_message {
  my $self = shift;
  my $message_id = shift;

  my $result = $self->cache_read( type => 'mail_message', id => $message_id );
  return $result if $result;
  $result = $self->call( inbox => read_message => $message_id);
  $self->cache_write( type => 'mail_message', id => $message_id, data => $result );
  return $result;
}

sub mail_trash {
  my $self = shift;
  my $message_ids = shift;

  my $result = $self->call( inbox => trash_messages => $message_ids);
  $self->cache_invalidate( type => 'mail_inbox' );
  return $result;
}

sub mail_archive {
  my $self = shift;
  my $message_ids = shift;

  my $result = $self->call( inbox => archive_messages => $message_ids);
  $self->cache_invalidate( type => 'mail_inbox' );
  return $result;
}

sub boost_view {
  my $self = shift;

  my $result = $self->cache_read(type => 'empire_boosts');
  return $result if $result;
  my $result = $self->call(empire => 'view_boosts');
  my $invalid = List::Util::min(time() + 3600);
  $self->cache_write(type => 'empire_boosts', data => $result, invalid => $invalid);
  return $result;
}

sub boost_aspect {
  my $self = shift;
  my $name = shift;

  my $result;
  if ($name eq "spy_training") {
    $result = $self->call(empire => "spy_training_boost");
  } else {
    $result = $self->call(empire => "boost_$name");
  }
  $self->cache_invalidate(type => 'empire_boosts');
  return $result;
}

sub present_captcha {
  my ($self, $captcha) = @_;
  $captcha ||= $self->call(captcha => "fetch");
  my $fetched_at = time();
  for (;;) {
    warn("Fetched captcha guid $captcha->{guid}\n");
    my $c_response = $self->{ua}->get($captcha->{url});
    my $image = $c_response->content;
    my $filename = $captcha->{url};
    $filename =~ s-.*/-captcha/-;
    -d 'captcha' or mkdir 'captcha';
    my $file;
    open($file, ">", $filename) or die "Couldn't write captcha image: $filename: $!\n";
    binmode($file);    # the PNG is binary; without this, Windows CRLF-translates it into garbage
    print $file $image;
    close($file);
    open($file, "-|", "$self->{captcha_program} $filename") or die "Couldn't run captcha presenter: $!\n";
    my $answer = <$file>;
    close($file);
    chomp $answer;
    $answer =~ s/^ANSWER: //;
    if (!$answer) {
      $captcha = $self->call(captcha => "fetch");
      $fetched_at = time();
      next;
    }
    # Let 10-30 seconds (inclusive) elapse between fetching a captcha and
    # submitting its solution; a slow human answer needs no extra wait.
    my $delay = int(10 + rand 21);
    sleep($delay - (time() - $fetched_at)) if $delay > time() - $fetched_at;
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
        empire_boosts                => 'empire/boosts',
        empire_status                => 'empire/status',
        empire_profile               => 'empire/%d/profile',
        body_status                  => 'body/%d/status',
        buildings                    => 'body/%d/buildings',
        buildable                    => 'body/%d/buildable',
        spy_list                     => 'body/%d/spy_list',
        plans                        => 'body/%d/plans',
        glyphs                       => 'body/%d/glyphs',
        excavators                   => 'body/%d/excavators',
        waste_chain                  => 'body/%d/waste_chain',
        building_view                => 'building/%d/view',
        building_stats               => 'building/%d/stats_%d',
        spaceport_view_all_ships     => 'body/%d/view_all_ships',
        observatory_get_probed_stars => 'building/%d/get_probed_stars',
        shipyard_view_build_queue    => 'building/%d/view_build_queue',
        shipyard_buildable           => 'building/%d/buildable',
        mission_list                 => 'building/%d/mission_list',
        mail_inbox                   => 'mail/inbox',
        mail_message                 => 'mail/message/%d',
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

sub cache_revalidate {
    my ($self, %args) = @_;

    my $path = $self->_cache_path( $args{type}, $args{id} );
    my $data = $self->read_json( $path ) or return;
    return unless $args{invalid};
    $data->{_invalid} = $args{invalid} if !$data->{_invalid} || $args{invalid} < $data->{_invalid};
    $self->write_json( $path, $args{type}, $data );
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
