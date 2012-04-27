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
	eval {
		$task->run_task($self);
		$success = 1;
	};
	if (!$success) {
		print "Failed to run task type: ".ref($task)."\n";
		print "Error was: " . $@ . "\n";
		return 0;
	}
	elsif ( $task->going_again() ) {
		$self->add_scheduled_task($started_at + $task->repeat_after(), $task);
	}
	return 1;
}

1;

