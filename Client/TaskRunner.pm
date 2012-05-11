package Client::TaskRunner;

use Moose;
use List::Util qw( min max first );

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

