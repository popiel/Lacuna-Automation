#!/usr/bin/perl
#
# Votes in the Lacuna lottery, spreading each day's regenerated links across
# as many zones as possible.
#
# Server mechanics (verified against the live game):
#   * each named link refreshes 24h after it was last followed, independent
#     of zone; which ED was used to fetch the link only decides which zone
#     the vote counts for
#   * every zone's ED sees the same global pool of available link names
#   * entertainment/get_lottery_voting_options returns a success response
#     with an empty options list once everything available has been followed
#     (the web client renders that state as "You have voted as many times
#     as you could today.")
#
# With --daily (driven by the five-minute build queue job):
#   * the first check of the day happens at a random time inside 6:00-6:30pm
#     local; checks continue every five minutes until 9:00pm local
#   * each link's last use is tracked by its name, because following a link
#     in one zone marks that link used for every zone
#   * known link names are learned from the available-link pool itself; a
#     name is dropped only after it has been absent from the pool for more
#     than 48 hours
#   * checks are skipped while every known link was followed within the last
#     23h45m (none can have regenerated yet); probing continues until at
#     least two link names are known, so a fresh install discovers the pool
#   * a run which saw links distributed them across zones in one burst:
#     one vote per zone per round-robin pass before any zone duplicates

use strict;

BEGIN {
  @INC = (@INC, ".", "local/lib/perl5");
}

use warnings;

use Client;
use Fcntl qw(O_RDWR O_CREAT :flock :seek);
use Getopt::Long;
use JSON::PP qw(encode_json decode_json);
use List::Util qw(shuffle);
use LWP::UserAgent;
use POSIX qw(strftime);
use Time::Local qw(timelocal);

my $config_name = "config.json";
my $daily = 0;
my $at = "";

GetOptions(
    "config=s" => \$config_name,
    "daily"    => \$daily,
    "at=s"     => \$at,
) or die "$0 [--config=foo.json] [--daily] [--at=HH:MM]\n";

my $state_file     = "entertainment.queue";
my $window_start   = 18 * 60;            # minutes: 6:00pm local
my $window_end     = 21 * 60;            # minutes: 9:00pm local (exclusive)
my $start_span     = 30;                 # first check: rand 0..29 minutes after window start
my $click_base     = 10;                 # seconds between link visits
my $click_jitter   = 15;                 # plus 0..14 seconds
my $skip_within    = 23.75 * 60 * 60;    # links refresh 24h after use
my $ed_name        = "Entertainment District";

my $lock;
my $state;

open_state();
roll_state() unless ($state->{date} // "") eq today();

if ($daily) {
    my $now_min = (localtime)[2] * 60 + (localtime)[1];
    $now_min = $1 * 60 + $2 if $at =~ /^(\d{1,2}):(\d{2})$/;    # test hook: pretend it is HH:MM
    exit 0 if $now_min >= $window_end;
    exit 0 if $now_min < $window_start + $state->{start_min};
}

# Each link refreshes 24h after its own last use, so while every known link
# was followed within the last 23h45m none can have regenerated.  Keep
# probing when fewer than two links are known so a fresh install can discover
# the rest of the pool.  The settled flag keeps a burst interrupted after its
# probe from hiding the links it had not actually followed yet.
exit 0 if ($state->{settled} // 1) && known_links_consumed_recently();

my $client = Client->new(config => $config_name);

discover();

my $config = probe();

$state->{settled} = 0;
save_state();

my @links = @{ $config->{options} // [] };
track_links(map { $_->{name} } @links);
unless (@links) {
    $state->{settled} = 1;
    save_state();
    emit("no links available yet; the next run will check again");
    exit 0;
}

save_state();

my $followed = burst();

$state->{settled} = 1;
save_state();
emit("burst consumed $followed link(s); last link followed at $state->{last_used}");
emit("all known links used within 23h45m; pausing checks until one nears refresh")
    if known_links_consumed_recently();
exit 0;

sub open_state {
    sysopen($lock, $state_file, O_RDWR|O_CREAT) or die "Can't open $state_file: $!\n";
    unless (flock($lock, LOCK_EX|LOCK_NB)) {
        # A five-minute tick colliding with an in-progress burst, or two
        # invocations racing; the job just runs again shortly.
        exit 0 if $daily;
        die "another entertainment run appears to be active\n";
    }
    my $data = "";
    if (-s $lock) {
        sysread($lock, $data, -s $lock);
    }
    $state = eval { decode_json($data) } // {};
    $state->{links} = {} unless ref($state->{links}) eq 'HASH';
}

sub save_state {
    my $json = encode_json($state);
    seek($lock, 0, SEEK_SET);
    truncate($lock, 0);
    syswrite($lock, $json . "\n", length($json) + 1);
}

# Reroll the daily start time on a new local date.  Zones, per-link last-use
# history and the last used timestamp carry over; per-cycle counters reset.
sub roll_state {
    my $prior = $state;
    $state = {
        date      => today(),
        start_min => $daily ? int(rand($start_span)) : 0,
        zones     => $prior->{zones}     // {},
        links     => $prior->{links}     // {},
        last_used => $prior->{last_used},
        settled   => $prior->{settled},
        votes     => 0,
    };
    save_state();
    if ($daily) {
        printf("%s entertainment: new day %s; first check due %02d:%02d\n",
            Client::format_time(time()), $state->{date},
            int($window_start / 60), start_min());
    }
}

sub start_min {
    $state->{start_min} // 0;
}

sub today {
    strftime("%Y-%m-%d", localtime());
}

sub known_links_consumed_recently {
    my $links = $state->{links} // {};
    return 0 if keys %$links < 2;
    my $now = time();
    for my $name (keys %$links) {
        my $used = text_epoch($links->{$name});
        return 0 unless defined($used) && $now - $used < $skip_within;
    }
    return 1;
}

sub text_epoch {
    my $text = shift or return undef;
    my ($y, $mo, $d, $h, $mi, $s) = $text =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/
        or return undef;
    eval { timelocal($s, $mi, $h, $d, $mo - 1, $y) };
}

# Record every link name the pool offers as used now, then drop names that
# have neither been offered nor used for more than 48 hours.  A name is the
# unit of use: following it in any zone consumes it for every zone.
sub track_links {
    my @names = @_;
    my $now = strftime("%Y-%m-%d %H:%M:%S", localtime());
    for my $name (@names) {
        $state->{links}{$name} = $now;
    }
    my %available = map { $_ => 1 } @names;
    my $now_epoch = time();
    for my $name (keys %{$state->{links}}) {
        next if $available{$name};
        my $used = text_epoch($state->{links}{$name});
        next unless defined($used);
        delete $state->{links}{$name} if $now_epoch - $used > 48 * 60 * 60;
    }
}

sub discover {
    my $planets = $client->empire_status->{planets};
    for my $id (keys %$planets) {
        my $name = $planets->{$id} // $id;
        emit("checking buildings on $name");
        my $buildings = eval { $client->body_buildings($id) };
        unless ($buildings) {
            my $error = $@ // "unknown error";
            emit("could not inspect $name: $error");
            next;
        }
        my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_, body_id => $id } }
                        keys(%{$buildings->{buildings}});
        my $ed = (grep { $_->{name} eq $ed_name } @buildings)[0];
        my $zone = $buildings->{status}{body}{zone};
        unless ($zone) {
            emit("could not determine the zone of $name");
            next;
        }
        if ($ed) {
            my $prior = $state->{zones}{$zone} // {};
            $state->{zones}{$zone} = {
                ed_id     => $ed->{id},
                body_id   => $id,
                exhausted => $prior->{exhausted} // 0,
            };
            if (!$prior->{body_id}) {
                emit("found an entertainment district on $name covering zone $zone");
            }
            elsif (($prior->{ed_id} // "") ne $ed->{id}) {
                emit("updated entertainment district on $name covering zone $zone");
            }
        }
        elsif (($state->{zones}{$zone}{body_id} // "") eq $id) {
            # The planet was scanned successfully and no longer has a district.
            delete $state->{zones}{$zone};
            emit("$name no longer has an entertainment district; dropped zone $zone");
        }
    }
    unless (keys %{$state->{zones}}) {
        emit("no entertainment districts anywhere; nothing to vote with");
        exit 0;
    }
    save_state();
}

sub probe {
    # Every ED sees the same global pool of link names, so probing one ED
    # reveals all currently regenerated links.  Pick a district
    # deterministically for the observation.
    my ($probe_zone) = sort { $state->{zones}{$a}{ed_id} <=> $state->{zones}{$b}{ed_id} }
                       keys %{$state->{zones}};
    my $result = eval { $client->call(entertainment => get_lottery_voting_options => $state->{zones}{$probe_zone}{ed_id}) };
    unless ($result) {
        my $error = $@ // "unknown error";
        emit("could not check voting options in zone $probe_zone: $error");
        exit 0;
    }
    return $result;
}

sub burst {
    my $ua = LWP::UserAgent->new(
        timeout => 60,
        # follow redirects until a non-3xx status arrives (default, 7 hops max)
        agent => "Mozilla/5.0 (compatible; LacunaAutomation entertainment.pl)",
    );

    my $followed = 0;
    while (1) {
        my @zones = shuffle keys %{$state->{zones}};
        my $acted = 0;
        for my $zone (@zones) {
            my $ed = $state->{zones}{$zone}{ed_id};
            my $result = eval { $client->call(entertainment => get_lottery_voting_options => $ed) };
            unless ($result) {
                my $error = $@ // "unknown error";
                emit("could not get voting options for zone $zone: $error");
                next;
            }
            my @links = @{ $result->{options} // [] };
            track_links(map { $_->{name} } @links);
            next unless @links;
            my $pick = $links[int rand @links];
            emit("zone $zone: voting via $pick->{name} at $pick->{url}");
            my $response = $ua->get($pick->{url});
            my $label = eval { $response->status_line };
            $label = "no response" unless defined $label;
            emit("zone $zone: visit returned $label");
            my $used = strftime("%Y-%m-%d %H:%M:%S", localtime());
            $state->{last_used} = $used;
            $state->{links}{$pick->{name}} = $used;
            $state->{votes}++;
            save_state();
            $acted++;
            $followed++;
            sleep($click_base + int rand $click_jitter);
        }
        last unless $acted;
    }
    return $followed;
}

sub emit {
    my $message = shift;
    print Client::format_time(time()), " entertainment: $message\n";
}
