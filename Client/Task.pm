package Client::Task;
use Moose;

has 'callback' => ( 
	traits => ['Code'],
	is     => 'rw',
	handles => { 'run_task' => 'execute_method' },
);

has 'repeat_after' => (
	is  => 'rw',
	isa => 'Int',
	predicate => 'going_again',
	clearer => 'stop_repeating',
);

has 'niceness' => (
	is => 'rw',
	isa => 'Int',
	default => 10,
);

# other things, like expected rpc usage, or historical runtimes

1;
