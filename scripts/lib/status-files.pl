#!/usr/bin/env perl
# Bounded, read-only access to the controller's local status files.
use strict;
use warnings;
use Encode qw(decode FB_CROAK);
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW S_ISREG);
use JSON::PP;
use Time::HiRes ();

my $json = JSON::PP->new->utf8->canonical;
my ($op, $path, $limit) = @ARGV;

sub regular_stamp {
  my @st = Time::HiRes::lstat($_[0]);
  return unless @st && S_ISREG($st[2]);
  return [@st[7,9]];
}

sub read_source {
  return {state=>'missing'} unless regular_stamp($path);
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    or return {state=>'missing'};
  my @st = stat($fh);
  return {state=>'missing'} unless @st && S_ISREG($st[2]);
  # Check the byte count on the same descriptor used for the bounded read.
  return {state=>'over_limit'} if $st[7] > $limit;
  my $bytes = '';
  while (length($bytes) <= $limit) {
    my $n = sysread($fh, $bytes, $limit + 1 - length($bytes), length($bytes));
    return {state=>'missing'} unless defined $n;
    last if !$n;
  }
  return {state=>'over_limit'} if length($bytes) > $limit;
  my $raw = eval { decode('UTF-8', $bytes, FB_CROAK) };
  return defined($raw) ? {state=>'ok', raw=>$raw} : {state=>'missing'};
}

sub discover {
  my %plans;
  my $left = 1000;
  for my $kind (qw(state locks)) {
    my $dir = "$path/$kind";
    next if -l $dir || !opendir(my $dh, $dir);
    while ($left > 0 && defined(my $name = readdir($dh))) {
      next if $name eq '.' || $name eq '..';
      $left--;
      my $entry = "$dir/$name";
      if ($kind eq 'state' && $name =~ /\A([a-z0-9][a-z0-9._-]{0,79})\.(?:controller\.json|tsv)\z/) {
        my $plan = $1;
        my $stamp = regular_stamp($entry) or next;
        $plans{$plan} = $stamp->[1] if !exists($plans{$plan}) || $stamp->[1] > $plans{$plan};
      } elsif ($kind eq 'locks' && $name =~ /\Acontroller-([a-z0-9][a-z0-9._-]{0,79})\z/ && !-l $entry && -d _) {
        $plans{$1} //= 0;
      }
    }
    closedir($dh);
  }
  my @ids = sort { $plans{$b} <=> $plans{$a} || $a cmp $b } keys %plans;
  my $more = @ids > 20 ? @ids - 20 : 0;
  splice(@ids, 20) if $more;
  return {ids=>\@ids, more=>$more};
}

my $value;
if ($op eq 'read') { $value = read_source(); }
elsif ($op eq 'stamp') { $value = regular_stamp($path); }
elsif ($op eq 'discover') { $value = discover(); }
else { die "invalid status file operation\n"; }
print $json->encode($value), "\n";
