package Client::Task;
use Moose;

has 'callback' => ( 
	traits => ['Code'],
	is     => 'rw',
	handles => { 'run_task' => 'execute_method' },
);

# When this task expects to be run next
has 'next_run' => (
	is => 'rw',
	isa => 'Int',
	predicate => 'scheduled',
	clearer => 'clear_schedule',
	default => sub { return time() },
);

# run according to the cron specification
has 'cron_spec' => (
	is => 'rw',
	isa => 'DateTime::Event::Cron',
	predicate => 'cron_schedule',
	clearer => 'remove_cron',
	trigger => sub { 
		my ($self, $new) = @_; 
		$self->next_run( $self->cron_spec()->increment()->epoch() ); 
	},
);

# after this task finishes, schedule it to run again in this number of seconds
# after it started the first time (careful about tasks that take longer than their
# repeat interval)
has 'repeat_after' => (
	is  => 'rw',
	isa => 'Int',
	predicate => 'fixed_schedule',
	clearer => 'stop_repeating',
);

has 'niceness' => (
	is => 'rw',
	isa => 'Int',
	default => 10,
);
has 'description' => (
	is => 'rw', isa => 'Str',
);
# other things, like expected rpc usage, or historical runtimes


sub schedule_next {
	my ($self, $runner, $started_at) = @_;
	if ( $self->scheduled() ) {
		# the task execution itself set the next run
		$runner->add_task($self);
	}
	elsif ( $self->fixed_schedule() ) {
		$self->next_run( $started_at + $self->repeat_after() );
		$runner->add_task($self);
	}
	elsif ( $self->cron_schedule()) {
		$self->next_run( $self->cron_spec()->increment()->epoch() );
		$runner->add_task($self);
	}
}

sub name {
	my ($self) = @_;
	return ref($self) . ( $self->description() ? "(".$self->description().")" : '' );
}

1;
