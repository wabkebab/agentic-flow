#!/usr/bin/env perl
# Inventory literal assertion messages and named assertion-helper arguments.
# Keep shell spelling (including dynamic variables); never evaluate test input.
# assertion-messages.txt was recorded before the move from commit 49865d0.
# Keep it unchanged; assertion-additions.txt records this step's new guards.
use strict;
use warnings;

my ($root, $mode) = @ARGV;
die "usage: $0 ROOT [--check]\n" unless defined $root;
my %messages;
my $word = qr/(?:"(?:\\.|[^"\\])*"|'[^']*'|\\.|[^\s;&|<>()"'\\])+/;
opendir my $tests, "$root/scripts/tests" or die "scripts/tests: $!\n";
my @groups = sort grep { /\.sh\z/ } readdir $tests;
closedir $tests;
for my $file ("$root/scripts/self-test.sh", map { "$root/scripts/tests/$_" } @groups) {
    open my $fh, '<', $file or die "$file: $!\n";
    local $/;
    my $text = <$fh>;
    $text =~ s/\\\n[ \t]*/ /g;
    for my $line (split /\n/, $text) {
        next if $line =~ /^\s*#/;
        while ($line =~ /\b(fail|assert_\w+|must_\w+|state_rejects|reject_before_gh|plan_reject_without_mutation|\w+_(?:case|expect|refused|reject|run|markers|quiet))(?=\s)/g) {
            my $helper = $1;
            my @args;
            while ($line =~ /\G[ \t]+($word)/gc) {
                push @args, $1;
                last if $helper eq 'fail';
            }
            # Helpers such as must_block put the diagnostic's command in their
            # second argument. Keep every argument, not just the hook path.
            $messages{"$helper\t" . join(' ', @args)} = 1 if @args;
        }
    }
}
my $actual = join('', map { "$_\n" } sort keys %messages);
if (!defined $mode) { print $actual; exit 0; }
die "unknown mode: $mode\n" unless $mode eq '--check';
my %expected;
for my $name ('assertion-messages.txt', 'assertion-additions.txt') {
    open my $fh, '<', "$root/scripts/tests/$name" or die "$name: $!\n";
    while (<$fh>) { chomp; $expected{$_} = 1 if length; }
}
my @missing = grep { !$messages{$_} } sort keys %expected;
my @added = grep { !$expected{$_} } sort keys %messages;
if (@missing || @added) {
    print STDERR "assertion inventory differs\n";
    print STDERR "missing: $_\n" for @missing;
    print STDERR "unrecorded: $_\n" for @added;
    exit 1;
}
