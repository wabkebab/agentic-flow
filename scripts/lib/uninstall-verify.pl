#!/usr/bin/env perl
# Runs from memory after removal. STDIN is Git's NUL-delimited index listing.
use strict;
use warnings;
use Digest::SHA;
use Encode qw(decode encode FB_CROAK);
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
use JSON::PP;

my ($rm_status, $file_mode) = @ARGV;
open my $plan_input, '<&=3' or die "could not read uninstall plan: $!\n";
my $plan = decode_json(do { local $/; <$plan_input> });
my %indexed;
{
    local $/ = "\0";
    my $count = 0;
    while (defined(my $path = <STDIN>)) {
        ++$count <= 8000 && chomp $path or die "invalid uninstall index listing\n";
        $indexed{$path} = 1;
    }
}

sub worktree_state {
    my ($candidate) = @_;
    my @parts = split m{/}, encode('UTF-8', $candidate->{path}, FB_CROAK);
    my $file = '.';
    while (@parts) {
        $file .= '/' . shift @parts;
        my @stat = lstat $file;
        return $! == ENOENT ? 'missing' : 'unreadable' unless @stat;
        if (@parts) {
            return 'different' unless -d _;
            next;
        }
        return 'different' unless -f _;
        my $mode = $stat[2] & 0100 ? '100755' : '100644';
        return 'different' if $file_mode eq 'true' && $mode ne $candidate->{mode};
        sysopen my $input, $file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW or return 'unreadable';
        my @opened = stat $input;
        return 'unreadable' unless @opened && -f _ && $opened[0] == $stat[0] && $opened[1] == $stat[1];
        my $sha = eval { Digest::SHA->new(256)->addfile($input)->hexdigest };
        return 'unreadable' unless defined $sha;
        return $sha eq $candidate->{sha256} ? 'recorded' : 'different';
    }
    die "empty uninstall path\n";
}

my (@remaining, @deleted);
my $unchanged = $rm_status != 0;
for my $candidate (@{ $plan->{remove} }) {
    my $path = $candidate->{path};
    my $in_index = exists $indexed{encode('UTF-8', $path)};
    my $worktree = worktree_state($candidate);
    my $present = $worktree ne 'missing';
    $unchanged &&= $in_index && $present && $worktree ne 'unreadable';
    if ($in_index || $present) {
        push @remaining, { path => $path, index => $in_index ? JSON::PP::true : JSON::PP::false,
            worktree => $present ? JSON::PP::true : JSON::PP::false, state => $worktree };
    } else {
        push @deleted, $path;
    }
}
my $outcome = !$rm_status && !@remaining ? 'complete' : $unchanged ? 'unchanged' : 'incomplete';
print JSON::PP->new->utf8->canonical->encode({ outcome => $outcome, incomplete => \@remaining,
    verified_deletions => $outcome eq 'complete' ? \@deleted : [] }), "\n";
