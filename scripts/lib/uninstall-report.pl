#!/usr/bin/env perl
# Build the uninstall report from the classifier's NUL-delimited stream.
use strict;
use warnings;
use Encode qw(decode FB_DEFAULT FB_CROAK);
use JSON::PP;

my %report = (
    v => 1, root => '', version => '', origin => 'none', adoption_commit => undef,
    refusals => [], remove => [], kept => [], dangling_references => [],
    dangling_truncated => 0, git => [], git_state => [], outside => [],
);
my ($root, $common) = ('', '');
my %fields = (
    refusal => [qw(reason subject command)],
    remove  => [qw(path kind why sha256 mode)],
    kept    => [qw(path why command)],
    git     => [qw(what detail command)],
);
my %section = (refusal => 'refusals', remove => 'remove', kept => 'kept', git => 'git');

sub text { decode('UTF-8', $_[0], FB_DEFAULT | Encode::LEAVE_SRC) }

sub field {
    my $value = <STDIN>;
    defined $value && chomp $value or die "incomplete uninstall report\n";
    return $value;
}

{
    local $/ = "\0";
    while (defined(my $entry = <STDIN>)) {
        chomp $entry or die "incomplete uninstall report\n";
        if (exists $fields{$entry}) {
            my %row;
            for my $key (@{ $fields{$entry} }) {
                my $value = field();
                $row{$key} = $key eq 'command' && !length $value ? undef : text($value);
            }
            push @{ $report{$section{$entry}} }, \%row;
        } elsif ($entry eq 'common') {
            $common = field();
        } elsif ($entry eq 'notice') {
            push @{ $report{outside} }, text(field());
        } elsif ($entry =~ /\A(?:root|version|origin|adoption_commit)\z/) {
            my $value = field();
            $root = $value if $entry eq 'root';
            $report{$entry} = text($value);
        } else {
            die "unknown uninstall report entry: $entry\n";
        }
    }
}

if (@{ $report{remove} } > 2000) {
    $report{remove} = [];
    push @{ $report{refusals} }, {
        reason => 'removal-limit', subject => 'more than 2000 removal paths', command => 'git status',
    };
}

sub safe_file { # Do not follow symlink components of a kept path.
    my ($path) = @_;
    my $current = $root;
    for my $part (split m{/}, $path) {
        return if $part eq '' || $part eq '.' || $part eq '..';
        $current .= "/$part";
        return if -l $current;
    }
    return -f $current ? $current : undef;
}

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub scan_references {
    return unless length $root;
    my $size_limit = 1024 * 1024;
    my %files = map { $_->{path} => 1 } grep { $_->{why} ne 'unsafe-path' } @{ $report{kept} };
    my %removed = map { $_->{path} => 1 } @{ $report{remove} };
    my @needles = sort { length($b) <=> length($a) || $a cmp $b } keys %removed;
    push @needles, 'agentic-flow';
    my $pattern = join '|', map { quotemeta $_ } @needles;
    my $reference = qr/($pattern)/;
    if (!-l "$root/.github" && !-l "$root/.github/workflows"
            && opendir(my $workflows, "$root/.github/workflows")) {
        my $count = 0;
        while (defined(my $name = readdir $workflows)) {
            next if $name eq '.' || $name eq '..';
            if (++$count > 2000) {
                push @{ $report{refusals} }, {
                    reason => 'reference-scan-limit', subject => '.github/workflows',
                    command => 'ls -la -- .github/workflows',
                };
                last;
            }
            $files{text(".github/workflows/$name")} = 1;
        }
        closedir $workflows;
    }
    for my $path (sort keys %files) {
        next if $removed{$path};
        my $bytes = Encode::encode('UTF-8', $path);
        my $file = safe_file($bytes);
        next unless defined $file && -s $file <= $size_limit && open(my $input, '<:raw', $file);
        next if -B $input;
        my $size = read $input, my $contents, $size_limit + 1;
        close $input;
        next unless defined $size && $size <= $size_limit && index($contents, "\0") < 0;
        my $decoded = eval { decode('UTF-8', $contents, FB_CROAK) };
        next unless defined $decoded;
        my ($line, $found) = (0, 0);
        for my $value (split /\n/, $decoded) {
            ++$line;
            next unless $value =~ $reference;
            if ($found++ < 20 && @{ $report{dangling_references} } < 200) {
                push @{ $report{dangling_references} }, { file => $path, line => $line, ref => $1 };
            } else {
                ++$report{dangling_truncated};
            }
        }
    }
}

sub directory_size { # Count at most 100,000 entries, without following symlinks.
    my ($directory) = @_;
    my @pending = ($directory);
    my ($entries, $bytes) = (0, 0);
    while (@pending && $entries < 100_000) {
        my $next = pop @pending;
        next if -l $next || !opendir(my $dir, $next);
        while ($entries < 100_000 && defined(my $name = readdir $dir)) {
            next if $name eq '.' || $name eq '..';
            ++$entries;
            my $path = "$next/$name";
            my @stat = lstat $path;
            next unless @stat;
            push @pending, $path if -d _;
            $bytes += $stat[7] if -f _;
        }
        closedir $dir;
    }
    return ($entries, $bytes);
}

sub shared_state {
    return unless length $common;
    my $state = "$common/agentic-flow";
    return if -l $state || !opendir(my $dir, $state);
    my @names;
    my $count = 0;
    while (defined(my $name = readdir $dir)) {
        next if $name eq '.' || $name eq '..';
        if (++$count > 2000) {
            push @{ $report{refusals} }, {
                reason => 'git-read-failed', subject => "additional shared-state entries under " . text($state),
                command => 'ls -la -- ' . text(shell_quote($state)),
            };
            last;
        }
        push @names, $name if !-l "$state/$name" && -d _;
    }
    closedir $dir;
    for my $name (sort @names) {
        my ($entries, $bytes) = directory_size("$state/$name");
        push @{ $report{git_state} }, {
            dir => text("agentic-flow/$name"),
            class => $name =~ /\A(?:cache|codex-home|gate|probe|state|verify)\z/ ? 'cache' : 'record',
            entries => $entries, bytes => $bytes,
            command => 'rm -rf -- ' . text(shell_quote("$state/$name")),
        };
    }
}

scan_references() unless grep { $_->{reason} eq 'not-git-toplevel' } @{ $report{refusals} };
shared_state();
push @{ $report{outside} },
    'Operator files: review the repository entries under ~/.config/agentic-flow (or $XDG_CONFIG_HOME/agentic-flow) and any harness rules copied to your agent configuration.',
    'Keys: review harness-only signing keys, SSH keys, deploy keys and station credentials before revoking them.',
    'GitHub labels: review workflow labels in repository Settings or the Issues label editor.',
    'GitHub issues: close or reassign any outstanding harness trackers and workflow issues.',
    'GitHub rulesets: review required harness status checks and branch protection rules in repository Settings.',
    'CI workflow: review the kept .github/workflows files and remove harness steps or workflows by hand.';

print JSON::PP->new->utf8->canonical->encode(\%report), "\n";
