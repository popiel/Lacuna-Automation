
use File::Basename qw(dirname);
my $script_path = dirname(__FILE__);
use lib "$script_path/..";
use Test::More;
use Test::Mock::LWP;

BEGIN {
	use_ok('Client');
	use_ok('Client::TaskRunner');
	use_ok('Client::Task');
}

my $client;
eval {
	$client = Client->new(config => "$script_path/config.json");
	$client->{ua} = $Mock_ua;
};
isa_ok($client, 'Client');

my $runner;
eval {
	$runner = Client::TaskRunner->new('client' => $client);
};
isa_ok($runner, 'Client::TaskRunner');

{
	my $ran_stub = 0;
	my $task;
	eval {
		$task = Client::Task->new(
			'callback' => sub {
				my ($self,$runner) = @_; 
				$self->stop_repeating() if (++$ran_stub > 2); 
			},
		);
	};
	isa_ok($task, 'Client::Task');

	# basic one-off task
	$runner->add_scheduled_work(time(), $task);
	$runner->run();
	is($ran_stub, 1);

	$task->repeat_after(1);
	$runner->add_scheduled_work(time(), $task);
	$runner->run();
	is($ran_stub, 3);
	
}


done_testing(8);

