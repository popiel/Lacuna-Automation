package Client::TaskRunner;

use Moose;
use List::Util qw( min max first );

=pod

=head1 Description

A demultiplexer for the Lacuna Client. Set up Client::Tasks with schedules.
  - All work shares the same Client object and cache
  - No possibility of multiple scripts stepping on your rpc rate limit
  - Just-in-time scheduling of work

=head1 Usage

$client = Client->new(config => $ARGV[0]);
$runner = Client::TaskRunner->new('client' => $client);

# set up a simple periodic task to check for a specific email then stop
$runner->add_task(Client::Task->new(
	'repeat_after' => 30, # seconds
	'callback' => sub {
		my ($self, $runner) = @_;
		my $client = $runner->client();
		... check email ... 
		if $email =~ /I accept your terms/ {
			$self->stop_repeating();
		} else {
			... build more snarks ...
		}
	}
));

# set up a cron-scheduled task that creates new one-off tasks that run at exactly the right time.
# in this case, maybe we want to automatically ship spies to another planet to post them on the merc guild
$auto_spy_auction = Client::Task->new(
	'cron_spec' => DateTime::Event::Cron->new('0 * * * *'),
	'callback' => sub {
		my ($self, $runner) = @_;
		... for empty IntMin slots ... {
			... train spy, get spy id, calculate time until training finishes ...
			$runner->add_task(Client::Task->new('next_run' => $training_time, 'callback' => sub { 
				my ($self, $runner) = @_;
				... ship spy to your merc guild planet, get time until arrival ...
				$runner->add_task(Client::Task->new( 'next_run' => $arrival_time, 'callback' => sub { ... put spy up for auction ... } ));
			}));
		}
	}
);
$runner->add_task($auto_spy_auction);

# run all tasks on schedule until we don't have any more to run
$runner->run();

=cut

has 'client' => (
	is => 'ro',
	isa => 'Client', # Lacuna client, that is
	required => 1,
);

has 'timed_work' => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} },
	traits => ['Hash'],
	handles => {
		'add_scheduled_task'  => 'set',
		'schedule'            => 'keys',
		'work_finished'       => 'is_empty',
	},
);

has 'debug' => (
	is => 'rw',
	isa => 'Bool',
	default => 0,
);

sub run {
	my ($self) = @_;
	while (1) {
		my $now = time();
		print "Woke up at $now, work scheduled at [" . join(',', $self->schedule())."]\n" if $self->debug();
		my @avalible_work = 
			sort { $self->{timed_work}->{$a}->niceness() <=> $self->{timed_work}->{$b}->niceness() } 
			grep { $_ <= $now }
			sort $self->schedule();
		for my $run_at ( @avalible_work ) {
			my $task = delete($self->{timed_work}->{$run_at});
			$self->run_task($task, $now);
		}
		print "Finished work, going to sleep with schedule: [". join(',', $self->schedule())."]\n" if $self->debug();
		if (!$self->work_finished()) {
			my $next_work = min($self->schedule());
			next if $next_work < time();
			sleep($next_work - time()) && next;
		}
		else {
			print "Work queue empty, shutting down\n" if $self->debug();
			last;
		}

	}

}

sub run_task {
	my ($self, $task, $started_at) = @_;
	my $success;
	my $duration;
	eval {
		$task->clear_schedule();
		$duration = time();
		$task->run_task($self);
		$duration = time() - $duration;
		$task->schedule_next($self, $started_at);
		$success = 1;
	};
	if (!$success) {
		print "Failed to run task: ".$task->name()."\n";
		print "Error was: " . $@ . "\n";
		return 0;
	}
	else {
		print "Finished running task: ".$task->name().", in $duration seconds\n";
	}
	return 1;
}

sub add_task {
	my ($self, $task) = @_;
	$task->next_run(time()) unless $task->scheduled();
	$self->add_scheduled_task($task->next_run(), $task);
	return $task;
}

1;

