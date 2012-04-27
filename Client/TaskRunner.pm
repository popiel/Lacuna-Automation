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
		'add_scheduled_work'  => 'set',
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
		print "Woke up at $now, work scheduled at [" . join(',', $self->schedule())."]\n";
		my @avalible_work = grep { $self->{timed_work}->{$_} <= $now } $self->schedule();
		for my $run_at ( @avalible_work ) {
			my $work = delete($self->{timed_work}->{$run_at});
			my $success;
			eval {
				$work->run_task($self);
				$success = 1;
			};
			if (!$success) {
				print "Failed to run timed task at $run_at: ".ref($work)."\n";
			}
			elsif ( $work->going_again() ) {
				$self->add_scheduled_work($now + $work->repeat_after(), $work);
			}
		}
		print "Finished work, going to sleep with schedule: [". join(',', $self->schedule())."]\n";
		if (!$self->work_finished()) {
			sleep(min($self->schedule()) - $now);
		}
		else {
			print "Work queue empty, shutting down\n";
			last;
		}

	}

}


1;

