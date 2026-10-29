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
#   * checks less than 23h55m after the last link was followed are skipped
#     without any RPC calls, because nothing can have regenerated yet
#   * an empty options list seen 24h15m or more after the last link was
#     followed confirms every available link has been consumed and the
#     cycle is done
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

GetOptions(
    "config=s" => \$config_name,
    "daily"    => \$daily,
) or die "$0 [--config=foo.json] [--daily]\n";

my $state_file     = "entertainment.queue";
my $window_start   = 18 * 60;            # minutes: 6:00pm local
my $window_end     = 21 * 60;            # minutes: 9:00pm local (exclusive)
my $start_span     = 30;                 # first check: rand 0..29 minutes after window start
my $click_base     = 10;                 # seconds between link visits
my $click_jitter   = 15;                 # plus 0..14 seconds
my $ed_name        = "Entertainment District";
my $skip_before    = 24*60*60 - 15*60;   # 23h55m; nothing regenerates before this
my $done_after     = 24*60*60 + 15*60;   # 24h15m; empty list then means cycle done

my $lock;
my $state;

open_state();
roll_state() unless ($state->{date} // "") eq today();

if ($daily) {
    my $now_min = (localtime)[2] * 60 + (localtime)[1];
    exit 0 if $now_min >= $window_end;
    exit 0 if $now_min < $window_start + 60 * $state->{start_min};
}

# Checks before 23h55m past the last consumption can not find anything new;
# only skip them when the previous burst's bookkeeping is in a settled state
# (an interrupted burst clears the flag so leftovers get picked up).
if (defined(my $last = used_epoch())) {
    exit 0 if time() - $last < $skip_before && ($state->{settled} // 1);
}

# A probe already confirmed that nothing is pending; stop polling until the
# same delay that governs new links has elapsed.
if (defined(my $confirmed = confirmed_epoch())) {
    exit 0 if time() < $confirmed + $skip_before;
}

my $client = Client->new(config => $config_name);

discover() unless keys(%{$state->{zones}});

my $config = probe();
delete $state->{confirmed_at};

my @links = @{ $config->{options} // [] };
unless (@links) {
    # An empty pool is ambiguous: links may simply not have regenerated
    # yet.  Once 24h15m have passed since the last link was followed, an
    # empty pool proves every available link was followed and it is safe
    # to stop polling for a while.
    my $last = used_epoch();
    if (defined($last) && time() - $last >= $done_after) {
        $state->{confirmed_at} = strftime("%Y-%m-%d %H:%M:%S", localtime());
        $state->{settled} = 1;
        save_state();
        emit("nothing pending: no links regenerated 24h15m after the last one was followed; cycle done");
    }
    else {
        $state->{settled} = 1;
        save_state();
        emit("no links available yet; the next run will check again");
    }
    exit 0;
}

$state->{settled} = 0;   # crash before finishing must not hide the leftovers
save_state();

my $followed = burst();

$state->{settled} = 1;
save_state();
emit("burst consumed $followed link(s); last link followed at $state->{last_used}");
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
}

sub save_state {
    my $json = encode_json($state);
    seek($lock, 0, SEEK_SET);
    truncate($lock, 0);
    syswrite($lock, $json . "\n", length($json) + 1);
}

# Reroll the daily start time on a new local date.  Zones, the last used
# timestamp and settled state carry over; per-cycle counters reset.
sub roll_state {
    my $prior = $state;
    $state = {
        date      => today(),
        start_min => $daily ? int(rand($start_span)) : 0,
        zones     => $prior->{zones}     // {},
        last_used => $prior->{last_used},
        settled   => $prior->{settled},
        confirmed_at => $prior->{confirmed_at},
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

sub used_epoch {
    text_epoch($state->{last_used});
}

sub confirmed_epoch {
    text_epoch($state->{confirmed_at});
}

sub text_epoch {
    my $text = shift or return undef;
    my ($y, $mo, $d, $h, $mi, $s) = $text =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/
        or return undef;
    eval { timelocal($s, $mi, $h, $d, $mo - 1, $y) };
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
        next unless $ed;
        my $zone = $buildings->{status}{body}{zone};
        next if exists $state->{zones}{$zone};  # one district covers its whole zone
        $state->{zones}{$zone} = { ed_id => $ed->{id}, body_id => $id, exhausted => 0 };
        emit("found an entertainment district on $name covering zone $zone");
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
            next unless @links;
            my $pick = $links[int rand @links];
            emit("zone $zone: voting via $pick->{name} at $pick->{url}");
            my $response = $ua->get($pick->{url});
            my $label = eval { $response->status_line };
            $label = "no response" unless defined $label;
            emit("zone $zone: visit returned $label");
            $state->{last_used} = strftime("%Y-%m-%d %H:%M:%S", localtime());
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
