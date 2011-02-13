package Client;

use strict;

use Carp;
use Exception::Class (
    'LacunaRPCException' => { fields => ['code', 'text', 'data'] }
);
use File::Path;
use File::Spec;
use JSON::XS;
use LWP::UserAgent;
use Scalar::Util qw(blessed);
use Time::Local;

sub new {
  my $base = shift;
  die "Cannot make a new Client from ".ref($base)."\n"
    if blessed($base) && !$base->isa("Client");
  my $class = ref($base) || $base;
  my $self = ref($base) ? { %$base, @_ } : { @_ };
  bless($self, $class);
  $self->read_config();
  $self->{ua} ||= LWP::UserAgent->new();
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
  for my $key (qw(empire_name empire_password uri api_key)) {
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

  my @elems = reverse((localtime($time))[0..5]);
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

  my $dir = "log/".substr(format_time($time), 0, 10);
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

  my $filename = join(".", format_time($time), sprintf("%03d", $count), $api, $message->{method});
  $filename =~ s-/--g;
  $filename =~ s- -_-g;
  my $file;
  open($file, ">", "$dir/$filename") or croak "Could not log call: $!";
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
  if ($result->{error}) {
    # warn "Request: ".encode_json($message)."\n";
    warn "Error Response: $result->{error}{code}: $result->{error}{message}\n";
    LacunaRPCException->throw(code => $result->{error}{code}, text => $result->{error}{message},
                              data => JSON::XS->new->allow_nonref->canonical->pretty->encode($result->{error}{data}));
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

sub body_status {
  my $self = shift;
  my $body_id = shift;

  my $result =
          $self->cache_read( type => 'body_status', id => $body_id, stale => 500 ) ||
          $self->body_buildings($body_id)->{status}{body};
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
  $self->cache_write( type => 'buildable', id => $body, invalid => $invalid, data => $result );
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

  # invalidate the buildings cache
  $self->cache_invalidate( type => 'buildings', id => $body_id ) if $result;
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

sub building_repair {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->call($url => repair => $building_id);
  if ( $result ) {
      $self->cache_invalidate( type => 'buildings',     id => $building_id );
      $self->cache_invalidate( type => 'building_view', id => $result->{status}{body}{id} );
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

  my $result = $self->cache_read( type => 'spaceport_view_all_ships', id => $building_id );
  return $result if $result;

  my $page = 1;
  my @ships;
  for (;;) {
    $result = $self->call(spaceport => view_all_ships => $building_id, $page);
    push(@ships, @{$result->{ships}});
    last if @{$result->{ships}} < 25;
    $page++;
  }
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
  $self->cache_write( type => 'spaceport_view_all_ships', id => $building_id, data => $result );
  return $result;
}

sub get_probed_stars {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->cache_read( type => 'observatory_get_probed_stars', id => $building_id );
  return $result;

  my $page = 1;
  my @stars;
  for (;;) {
    $result = $self->call(observatory => get_probed_stars => $building_id, $page);
    push @stars, @{$result->{stars}};
    last if @{$result->{stars}} < 25;
    $page++;
  }
  $result->{stars} = \@stars;
  my $invalid = time() + 3600;
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

  my $result = $self->call(shipyard => build_ship => $building_id, $type);
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
    for my $body ($target_id, $result->{status}{body}{id}) {
      my $buildings = $self->body_buildings($body);
      for my $id (keys %{$buildings->{buildings}}) {
        $self->cache_invalidate( type => 'spaceport_view_all_ships', id => $id );
      }
    }
  }
  return $result;
}

{
    my %path_for = (
        empire_status                => 'empire/status',
        body_status                  => 'body/%d/status',
        buildings                    => 'body/%d/buildings',
        buildable                    => 'body/%d/buildable',
        building_view                => 'building/%d/view',
        building_stats               => 'building/%d/stats_%d',
        spaceport_view_all_ships     => 'building/%d/view_all_ships',
        observatory_get_probed_stars => 'building/%d/get_probed_stars',
        shipyard_view_build_queue    => 'building/%d/view_build_queue',
        session                      => 'session',
    );

    sub _cache_path {
        my ($self, $type, $id, $level) = @_;

        my ($host) = ( $self->{uri} =~ m|^\w+://(\w+)\.lacunaexpanse\.com$|i );
        return sprintf "cache/%s@%s/$path_for{ $type }", grep { defined $_ } $self->{empire_name}, $host, $id, $level;
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
        ($result->{_time}    && ( $result->{_time}    <= ( $now - $args{stale} ) )) # cache is stale
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

1;
