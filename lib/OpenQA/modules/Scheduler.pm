package Scheduler;

use strict;
use warnings;
use diagnostics;

use DBIx::Class::ResultClass::HashRefInflator;
use Digest::MD5;
use Data::Dump qw/pp/;
use Date::Format qw/time2str/;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use openqa ();

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register worker_get list_workers job_create
    job_get list_jobs job_grab job_set_scheduled job_set_done
    job_set_cancel job_set_waiting job_set_running job_set_prio
    job_delete job_update_result job_restart job_cancel command_enqueue
    command_get list_commands command_dequeue iso_cancel_old_builds
    job_set_stop job_stop iso_stop_old_builds
    );


my $schema = openqa::connect_db();

=item _hashref()

Convert an ORM object into a hashref. The API only export hashes and
not ORM objects.

=cut

# XXX TODO - Remove this useless function when is not needed anymore 
sub _hashref {
    my $obj = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
	$hashref{$field} = $obj->$field;
    }

    return \%hashref;
}


#
# Workers API
#

# param hash: host, instance, backend
sub worker_register {
    my ($host, $instance, $backend) = @_;

    my $worker = $schema->resultset("Workers")->search({
	host => $host,
	instance => int($instance),
    })->first;

    if ($worker) { # worker already known. Update fields and return id
	$worker->update({ t_updated => 0 });
    } else {
	$worker = $schema->resultset("Workers")->create({
	    host => $host,
	    instance => $instance,
	    backend => $backend,
	});
    }

    # maybe worker died, delete pending commands and reset running jobs
    $worker->jobs->update_all({
	state_id => $schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
    });
    $schema->resultset("Commands")->search({
	worker_id => $worker->id
    })->delete_all();

    die "got invalid id" unless $worker->id;
    return $worker->id;
}

# param hash:
# XXX TODO: Remove HashRedInflator
sub worker_get {
    my $workerid = shift;

    my $rs = $schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my $worker = $rs->find($workerid);

    return $worker;
}

# XXX TODO: Remove HashRedInflator
sub list_workers {
    my $rs = $schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @workers = $rs->all;

    return \@workers;
}

sub _validate_workerid($) {
    my $workerid = shift;
    die "invalid worker id\n" unless $workerid;
    my $rs = $schema->resultset("Workers")->search({ id => $workerid });
    die "invalid worker id $workerid\n" unless $rs->count;
}

sub _seen_worker($) {
    my $id = shift;
    $schema->resultset("Workers")->find($id)->update({ t_updated => 0 });
}


#
# Jobs API
#

=item job_create

create a job

=cut
sub job_create {
    my %settings = @_;

    for my $i (qw/DISTRI VERSION ISO DESKTOP TEST/) {
	die "need one $i key\n" unless exists $settings{$i};
    }

    for my $i (qw/ISO NAME/) {
	next unless $settings{$i};
	die "invalid character in $i\n" if $settings{$i} =~ /\//; # TODO: use whitelist?
    }

    unless (-e sprintf("%s/%s", $openqa::isodir, $settings{ISO})) {
	die "ISO does not exist\n";
    }

    my @settings = ();
    while(my ($k, $v) = each %settings) {
	push @settings, { key => $k, value => $v };
    }

    my %new_job_args = (
	settings => \@settings,
	test => $settings{'TEST'},
    );

    if ($settings{NAME}) {
	    my $njobs = $schema->resultset("Jobs")->search({ slug => $settings{'NAME'} })->count;
	    return 0 if $njobs;

	    $new_job_args{slug} = $settings{'NAME'};
    }

    my $job = $schema->resultset("Jobs")->create(\%new_job_args);

    return $job->id;
}

sub job_get($) {
    my $value = shift;

    if ($value =~ /^\d+$/) {
	return _job_get({ id => $value });
    }
    return _job_get({slug => $value });
}

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;

    my $job = $schema->resultset("Jobs")->search($search)->first;
    my $job_hashref;
    if ($job) {
	$job_hashref = _hashref($job, qw/ id name priority worker_id t_started t_finished test test_branch/);
	# XXX: use +columns in query above?
	$job_hashref->{state} = $job->state->name;
	$job_hashref->{result} = $job->result->name;
	_job_fill_settings($job_hashref);
    }
    return $job_hashref;
}

sub _job_fill_settings {
    my $job = shift;
    my $job_settings = $schema->resultset("JobSettings")->search({ job_id => $job->{id} });
    $job->{settings} = {};
    while(my $js = $job_settings->next) {
	$job->{settings}->{$js->key} = $js->value;
    }

    if ($job->{name} && !$job->{settings}->{NAME}) {
        $job->{settings}->{NAME} = sprintf "%08d-%s", $job->{id}, $job->{name};
    }

    return $job;
}

sub list_jobs {
    my %args = @_;

    my %cond = ();
    my %attrs = ();

    if ($args{state}) {
	my $states_rs = $schema->resultset("JobStates")->search({ name => [split(',', $args{state})] });
	$cond{state_id} = { -in => $states_rs->get_column("id")->as_query }
    }
    if ($args{finish_after}) {
        my $param = "datetime('$args{finish_after}')"; # FIXME: SQL injection!
        $cond{t_finished} = { '>' => \$param }
    }
    if ($args{maxage}) {
        $cond{'-or'} = [ t_finished => undef, t_finished => { '>' => time2str('%Y-%m-%d %R', time - $args{maxage}) } ];
    }
    if ($args{build}) {
        $cond{'settings.key'} = "BUILD";
        $cond{'settings.value'} = $args{build};
        $attrs{join} = 'settings';
    }

    my $jobs = $schema->resultset("Jobs")->search(\%cond, \%attrs);

    my @results = ();
    while( my $job = $jobs->next) {
	my $j = _hashref($job, qw/ id name priority worker_id t_started t_finished test test_branch/);
	$j->{state} = $job->state->name;
	$j->{result} = $job->result->name;
	_job_fill_settings($j) if $args{fulldetails};
	push @results, $j;
    }

    return \@results;
}

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab {
    my %args = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my $result;
    while (1) {
	my $now = "datetime('now')";
	$result = $schema->resultset("Jobs")->search({
	    state_id => $schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
	    worker_id => 0,
	}, { order_by => { -asc => 'priority'}, rows => 1})->update({
	    state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
	    worker_id => $workerid,
	    t_started => \$now,
	});

	last if $result != 0;
	last unless $blocking;
	# XXX: do something smarter here
	#print STDERR "no jobs for me, sleeping\n";
	#sleep 1;
	last;
    }

    my $job_hashref;
    $job_hashref = _job_get({
	id => $schema->resultset("Jobs")->search({
		  state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
		  worker_id => $workerid,
	      })->single->id,
    }) if $result != 0;

    return $job_hashref;
}

=item job_set_scheduled

release job from a worker and put back to scheduled (e.g. if worker
aborted). No error check. Meant to be called from worker!

=cut
sub job_set_scheduled {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
	worker_id => 0,
	t_started => undef,
	t_finished => undef,
	result_id => 0,
    });
    return $r;
}

=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters    
sub job_set_done {
    my %args = @_;
    my $jobid = int($args{jobid});
    my $result = $schema->resultset("JobResults")->search({ name => $args{result}})->single;

    die "invalid result string" unless $result;

    my $now = "datetime('now')";
    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "done" })->single->id,
	worker_id => 0,
	t_finished => \$now,
	result_id => $result->id,
    });
    return $r;
}

=item job_set_cancel

mark job as cancelled. No error check. Meant to be called from worker!

=cut
sub job_set_cancel {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "cancelled" })->single->id,
	worker_id => 0,
    });
    return $r;
}

sub job_set_stop {
    carp "job_set_stop is deprecated, use job_set_cancel instead";
    return job_set_cancel(@_);
}

=item job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "waiting" })->single->id,
    });
    return $r;
}

=item job_set_running

mark job as running. No error check. Meant to be called from worker!

=cut
sub job_set_running {
    my $jobid = shift;

    my $states_rs = $schema->resultset("JobStates")->search({ name => ['cancelled', 'waiting'] });
    my $r = $schema->resultset("Jobs")->search({
	id => $jobid,
        state_id => { -in => $states_rs->get_column("id")->as_query },
    })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
    });
    return $r;
}

sub job_set_prio {
    my %args = @_;

    my $r = $schema->resultset("Jobs")->search({ id => $args{jobid} })->update({
	priority => $args{prio},
    });
}

sub job_delete {
    my $value = shift;

    my $cnt = 0;
    my $jobs = _job_find_smart($value);
    foreach my $job ($jobs) {
	my $r = $job->delete;
	$cnt += $r if $r != 0;
    }
    return $cnt;
}

sub job_update_result {
    my %args = @_;

    my $id = int($args{jobid});
    my $result = $schema->resultset("JobResults")->search({ name => $args{result}})->single;

    my $r = $schema->resultset("Jobs")->search({ id => $id })->update({
		    result_id => $result->id
	    });

    return $r;
}

sub _job_find_smart($) {
    my $value = shift;

    my $jobs;
    if ($value =~ /^\d+$/ ) {
	$jobs = _job_find_by_id($value);
    } elsif ($value =~ /\.iso$/) {
	$jobs = _jobs_find_by_iso($value);
    } else {
	$jobs = _job_find_by_name($value);
    }

    return $jobs;
}

sub _job_find_by_id($) {
    my $id = shift;
    my $jobs = $schema->resultset("Jobs")->search({ id => $id});
}

sub _jobs_find_by_iso($) {
    my $iso = shift;

    # In case iso file use a absolute path
    # like iso_delete /var/lib/.../xxx.iso
    if ($iso =~ /\// ) {
	$iso =~ s#^.*/##;
    }

    my $jobs = $schema->resultset("Jobs")->search_related("settings", {
	key => "ISO",
	value => $iso,
    });
    return $jobs;
}

sub _job_find_by_name($) {
    my $name = shift;

    my $jobs = $schema->resultset("Jobs")->search({ slug => $name });
    return $jobs;
}

sub job_restart {
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "abort", "scheduled");
}

sub job_cancel {
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "cancel", "cancelled");
}

sub job_stop {
    carp "job_stop is deprecated, use job_cancel instead";
    return job_cancel(@_);
}

# set job to a final state, resetting it's properties
# parameters:
# - id or name
# - command to send to worker if the job is in use
# - name of final state
sub _job_set_final_state($$$) {
    my $name = shift;
    my $cmd = shift;
    my $statename = shift;

    # XXX TODO Put this into a transaction
    # needs to be a transaction as we need to make sure no worker assigns
    # itself while we modify the job
    my $jobs = _job_find_smart($name);
    while (my $job = $jobs->next) {
	print STDERR "workerid ". $job->id . ", " . $job->worker_id . " -> $cmd\n";
	if ($job->worker_id) {
	    $schema->resultset("Commands")->create({
		worker_id => $job->worker_id,
		command => $cmd,
	    });
	} else {
	    # XXX This do not make sense
	    $job->update({
		state_id => $schema->resultset("JobStates")->search({ name => $statename })->single->id,
		worker_id => 0,
	    });
	}
    }
}


#
# Commands API
#

sub command_enqueue {
    my %args = @_;

    _validate_workerid($args{workerid});

    my $command = $schema->resultset("Commands")->create({
	worker_id => $args{workerid},
	command => $args{command},
    });
    return $command->id;
}

sub command_get {
    my $workerid = shift;

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my @commands = $schema->resultset("Commands")->search({ worker_id => $workerid });

    my @as_array = ();
    foreach my $command (@commands) {
	push @as_array, [$command->id, $command->command];
    }

    return \@as_array;
}

sub list_commands {
    my $rs = $schema->resultset("Commands");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @commands = $rs->all;

    return \@commands;
}

sub command_dequeue {
    my %args = @_;

    die "missing workerid parameter\n" unless $args{workerid};
    die "missing id parameter\n" unless $args{id};

    _validate_workerid($args{workerid});

    my $r = $schema->resultset("Commands")->search({
	id => $args{id},
	worker_id =>$args{workerid},
    })->delete;

    return $r;
}

sub iso_cancel_old_builds($) {
    my $pattern = shift;

    my $r = $schema->resultset("Jobs")->search({
	state_id => $schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
	'settings.key' => "ISO",
	'settings.value' => { like => $pattern },
    }, {
	join => "settings",
    })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "cancelled" })->single->id,
	worker_id => 0,
    });
    return $r;
}

sub iso_stop_old_builds($) {
    carp "iso_stop_old_builds is deprecated, use iso_cancel_old_builds instead";
    return iso_cancel_old_builds(shift);
}