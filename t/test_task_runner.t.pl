
use File::Basename qw(dirname);
my $script_path = dirname(__FILE__);
use lib "$script_path/..";
use Test::More;
use Test::Mock::LWP;
use DateTime::Event::Cron;

BEGIN {
	use_ok('Client');
	use_ok('Client::TaskRunner');
	use_ok('Client::Task');
}

my $client;
eval {
	$client = Client->new(config => "$script_path/test_config.json");
	$client->{ua} = $Mock_ua;
};
isa_ok($client, 'Client');

my $runner;
eval {
	$runner = Client::TaskRunner->new('client' => $client, 'debug' => 1);
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
			'description' => 'Basic one-off',
		);
	};
	isa_ok($task, 'Client::Task');

	# basic one-off task
	$runner->add_task($task);
	$runner->run();
	is($ran_stub, 1);

	$task->repeat_after(1);
	$task->description('Basic repeating');
	$runner->add_task($task);
	$runner->run();
	is($ran_stub, 3);
	
}

{
	# verify that the event loop works if a task takes longer than the time until the next ccheduled task
	my @ran_stub;
	$runner = Client::TaskRunner->new('client' => $client, 'debug' => 1);
	$runner->add_task(Client::Task->new( 'callback' => sub { sleep 3; push(@ran_stub, 'cb1'); } ));
	$runner->add_task(Client::Task->new( 
		'callback' => sub { push(@ran_stub, 'cb2') }, 
		'next_run' => time() + 2,
		'description' => 'Longer task than next scheduled',
	));
	$runner->run();
	is_deeply(\@ran_stub, ['cb1', 'cb2']);
}
{
	# verify that the callback can override the next run time
	my $ran_stub = 0;
	$runner = Client::TaskRunner->new('client' => $client, 'debug' => 1);
	$runner->add_task(Client::Task->new( 
		repeat_after => 30, 
		callback => sub { 
			if (++$ran_stub > 1) { 
				$_[0]->stop_repeating();
			} else { 
				$_[0]->next_run(time()); 
			}
		},
		description => 'Callback override of schedule',
	));
	my $start = time();
	$runner->run();
	ok(time() - $start < 30);
}
{
	# verify cron scheduling support
	my $ran_stub = 0;
	$runner = Client::TaskRunner->new('client' => $client, 'debug' => 1);
	# TODO test cron scheduling
	$runner->add_task(Client::Task->new(
		'cron_spec' => DateTime::Event::Cron->new('* * * * *'),
		'callback'  => sub { 
			$_[0]->remove_cron() if ++$ran_stub > 1; 
		},
		'description' => 'Cron style scheduling',
	));
	$runner->run();
	is($ran_stub, 2);
}




done_testing(11);

