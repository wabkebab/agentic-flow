#!/usr/bin/env perl
# The detached controller's pipe stays open even if its log stops accepting writes.
use strict;
use warnings;
use Errno qw(EINTR);

sub write_log_bytes {
    my ($out, $bytes) = @_;
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $n = syswrite($out, $bytes, length($bytes) - $offset, $offset);
        next if !defined($n) && $! == EINTR;
        return unless $n;
        $offset += $n;
    }
    return 1;
}

sub drain_log {
    my ($in, $out) = @_;
    $SIG{$_} = 'IGNORE' for qw(INT TERM HUP);
    my $cap = 16 * 1024 * 1024;
    my ($written, $dropped, $writable) = (0, 0, 1);
    while (1) {
        my $n = sysread($in, my $chunk, 65536);
        next if !defined($n) && $! == EINTR;
        last unless $n;
        next unless $writable;
        my $save = $n < $cap - $written ? $n : $cap - $written;
        $writable = write_log_bytes($out, substr($chunk, 0, $save));
        $written += $save;
        $dropped += $n - $save;
    }
    if ($writable && $dropped) {
        # Replace the final bytes at the cap and count those bytes in the marker.
        my $marker = "\nagentic-flow: log truncated; $dropped bytes dropped\n";
        my $size;
        do {
            $size = length($marker);
            $marker = "\nagentic-flow: log truncated; " . ($dropped + $size) . " bytes dropped\n";
        } while (length($marker) != $size);
        sysseek($out, $cap - $size, 0) && write_log_bytes($out, $marker);
    }
}

1;
