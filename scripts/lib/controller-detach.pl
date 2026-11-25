#!/usr/bin/env perl
# Start a controller session and wait for its write-once startup acknowledgment.
use strict;
use warnings;
use Encode qw(decode_utf8 encode_utf8);
use Errno qw(EINTR);
use Fcntl qw(:DEFAULT :flock S_ISREG);
use File::Path qw(make_path);
use FindBin;
use JSON::PP;
use POSIX qw(setsid WNOHANG);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime sleep);
require "$FindBin::Bin/bounded-log.pl";

my ($flow, $plan, $as_json, @command) = @ARGV;
my $logs = "$flow/logs/$plan";
my $launches = "$flow/launches";
my $json = JSON::PP->new->utf8->canonical;
my $ack_seconds = $ENV{AGENTIC_DETACH_ACK_S} // 30;
if ($ack_seconds !~ /\A[0-9]{1,2}(?:\.[0-9]{1,3})?\z/ || $ack_seconds <= 0 || $ack_seconds > 30) {
    print STDERR "controller: invalid AGENTIC_DETACH_ACK_S\n";
    exit 2;
}

sub fail {
    print STDERR "controller: $_[0]\n";
    exit 5;
}

sub entries {
    my ($dir, $pattern) = @_;
    opendir(my $dh, $dir) or fail("cannot scan $dir: $!");
    my @files;
    for (1..10000) {
        my $name = readdir($dh);
        last unless defined $name;
        next unless $name =~ $pattern;
        my $path = "$dir/$name";
        my @st = lstat($path);
        push @files, [$path, $st[9]] if @st && S_ISREG($st[2]);
    }
    return @files;
}

sub open_regular {
    my ($path, $flags) = @_;
    sysopen(my $fh, $path, $flags | O_NONBLOCK | O_NOFOLLOW, 0600) or return;
    my @st = stat($fh);
    return unless @st && S_ISREG($st[2]);
    return ($fh, $st[7]);
}

sub prepare_log {
    my ($path) = @_;
    # Serialize retention and creation so another launcher sees a locked log as live.
    my ($guard) = open_regular("$logs/.prune.lock", O_WRONLY | O_CREAT);
    $guard or fail("cannot open log pruning lock: $!");
    for (1..50) {
        last if flock($guard, LOCK_EX | LOCK_NB);
        fail("cannot take log pruning lock: $!") if $_ == 50;
        sleep 0.02;
    }
    my @older = sort { $b->[1] <=> $a->[1] || $b->[0] cmp $a->[0] }
        entries($logs, qr/\A[a-zA-Z0-9_-]+\.log\z/);
    my ($log) = open_regular($path, O_WRONLY | O_CREAT | O_EXCL);
    $log && flock($log, LOCK_EX | LOCK_NB) or fail("cannot create $path: $!");
    splice(@older, 0, 19);
    for my $entry (@older) {
        my ($old) = open_regular($entry->[0], O_RDONLY);
        unlink $entry->[0] if $old && flock($old, LOCK_EX | LOCK_NB);
    }
    return $log;
}

sub acknowledgment {
    my ($path, $nonce) = @_;
    my ($fh, $size) = open_regular($path, O_RDONLY);
    return unless $fh && $size <= 1024;
    my $bytes = '';
    while (length($bytes) <= 1024) {
        my $n = sysread($fh, $bytes, 1025 - length($bytes), length($bytes));
        next if !defined($n) && $! == EINTR;
        return unless defined $n;
        last unless $n;
    }
    return if length($bytes) > 1024;
    my $ack = eval { $json->decode($bytes) };
    return unless ref($ack) eq 'HASH' && ($ack->{v} // '') eq '1'
        && ($ack->{nonce} // '') eq $nonce && ($ack->{plan} // '') eq $plan
        && ($ack->{pid} // '') =~ /\A[1-9][0-9]{0,9}\z/
        && ($ack->{host} // '') =~ /\A[0-9a-f]{12}\z/
        && !ref($ack->{start}) && length($ack->{start} // '')
        && ($ack->{run} // '') =~ m{\A\Q$plan\E/controller/\Q$ack->{pid}\E-[0-9]+\z}
        && ($ack->{ownership} // '') =~ /\A(?:owner|recovering)\z/
        && ($ack->{at} // '') =~ /\A[1-9][0-9]*\z/;
    return $ack;
}

sub launch_session {
    my ($log, $nonce) = @_;
    my $session = setsid();
    defined($session) && $session >= 0 or fail("cannot start a controller session: $!");
    open(STDIN, '<', '/dev/null') or fail("cannot redirect controller stdin: $!");
    pipe(my $read, my $write) or fail("cannot create log pipe: $!");
    # The writer ignores signals from the moment it forks.
    local @SIG{qw(INT TERM HUP)} = ('IGNORE') x 3;
    my $writer = fork();
    defined($writer) or fail("cannot start log writer: $!");
    if (!$writer) {
        close $write;
        close STDOUT;
        close STDERR;
        drain_log($read, $log);
        POSIX::_exit(0);
    }
    $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP);
    close $read;
    close $log;
    open(STDOUT, '>&', $write) && open(STDERR, '>&', $write)
        or fail("cannot redirect controller output: $!");
    close $write;
    $ENV{AGENTIC_DETACH_NONCE} = $nonce;
    exec @command or fail("cannot exec controller: $!");
}

sub child_exit {
    my ($pid, $flags) = @_;
    my $waited;
    do { $waited = waitpid($pid, $flags); } while $waited < 0 && $! == EINTR;
    return if $waited == 0;
    fail("cannot reap controller: $!") if $waited < 0;
    return ($? & 127) ? 128 + ($? & 127) : $? >> 8;
}

sub terminate_session {
    my ($pid) = @_;
    kill('TERM', -$pid) || kill('TERM', $pid);
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 10;
    my $exit;
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
        $exit //= child_exit($pid, WNOHANG);
        return if defined($exit) && !kill(0, -$pid);
        sleep 0.1;
    }
    kill('KILL', -$pid) || (!defined($exit) && kill('KILL', $pid));
    child_exit($pid, 0) unless defined($exit);
}

sub log_tail {
    my ($path) = @_;
    my ($fh) = open_regular($path, O_RDONLY);
    return unless $fh;
    # Give the writer a bounded chance to drain the startup error after reaping.
    for (1..20) {
        last if flock($fh, LOCK_EX | LOCK_NB);
        sleep 0.05;
    }
    my $bytes = '';
    read($fh, $bytes, 16 * 1024 * 1024);
    my $offset = length($bytes);
    $offset-- if $offset && substr($bytes, -1) eq "\n";
    for (1..20) {
        $offset = $offset > 0 ? rindex($bytes, "\n", $offset - 1) : -1;
        last if $offset < 0;
    }
    my $tail = decode_utf8(substr($bytes, $offset + 1));
    $tail =~ s/(?:\e\]|\x{9d})[^\a\e\x{9c}]*(?:\a|\e\\|\x{9c})|(?:\e\[|\x{9b})[0-?]*[ -\/]*[@-~]//g;
    $tail =~ s/[\x00-\x09\x0b-\x1f\x7f-\x9f]//g;
    print STDERR encode_utf8($tail);
}

sub test_pause {
    my ($point, $pid) = @_;
    my $path = $ENV{AGENTIC_CONTROLLER_PAUSE};
    return unless ($ENV{AGENTIC_CONTROLLER_TESTING} // '') eq '1'
        && ($ENV{AGENTIC_CONTROLLER_FAULT} // '') eq $point && $path;
    open(my $ready, '>', "$path.ready") or fail("cannot pause launch: $!");
    print {$ready} "$pid\n";
    close $ready;
    for (1..300) {
        if (-f "$path.release") {
            return unless -s "$path.release";
            # A nonempty release asks the hook to wait for a completed child.
            my $exit = child_exit($pid, WNOHANG);
            return $exit if defined($exit);
        }
        sleep 0.1;
    }
    fail("launch fixture did not release $point");
}

eval { make_path($logs, $launches) };
fail("cannot create detach directories: $@") if $@;
my $oldest = time - 86400;
for my $entry (entries($launches, qr/\A(?:[0-9a-f]{32}\.json|\.ack\.[a-zA-Z0-9]+)\z/)) {
    unlink $entry->[0] if $entry->[1] < $oldest;
}
open(my $random, '<', '/dev/urandom') or fail("cannot open random source: $!");
read($random, my $random_bytes, 16) == 16 or fail("cannot read launch nonce: $!");
close $random;
my $nonce = unpack('H*', $random_bytes);
my $log_path = "$logs/$nonce.log";
my $ack_path = "$launches/$nonce.json";
my $log = prepare_log($log_path);
my $child = fork();
defined($child) or fail("cannot fork controller: $!");
launch_session($log, $nonce) unless $child;

my $deadline = clock_gettime(CLOCK_MONOTONIC) + $ack_seconds;
my $ack;
my $exit = test_pause('detach-before-poll', $child);
for (my $first_poll = 1; ; $first_poll = 0) {
    $ack = acknowledgment($ack_path, $nonce);
    $exit //= test_pause('detach-after-read', $child) if $first_poll;
    $exit //= child_exit($child, WNOHANG);
    # Reaping orders this read after the controller's last possible publication.
    $ack //= acknowledgment($ack_path, $nonce) if defined($exit);
    last if $ack || defined($exit);
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    if ($remaining <= 0) {
        terminate_session($child);
        unlink $ack_path if acknowledgment($ack_path, $nonce);
        fail("startup acknowledgment timed out; log: $log_path");
    }
    sleep($remaining < 0.2 ? $remaining : 0.2);
}

if (!$ack) {
    close $log;
    log_tail($log_path);
    exit $exit if $exit != 0;
    fail('exited without acknowledgment');
}
my ($run_id) = $ack->{run} =~ m{/([^/]+)\z};
my $run_log = "$logs/$run_id.log";
if (link($log_path, $run_log)) {
    unlink $log_path;
    $log_path = $run_log;
}
close $log;
unlink $ack_path;
my $status = "agentic-flow status $plan --watch";
if ($as_json eq 'true') {
    print $json->encode({pid=>0+$ack->{pid}, log=>decode_utf8($log_path), status=>$status, finished_exit=>$exit}), "\n";
} else {
    print "controller pid: $ack->{pid}\nlog: $log_path\nstatus: $status\n";
    print "controller finished: exit $exit\n" if defined($exit);
}
exit($exit // 0);
