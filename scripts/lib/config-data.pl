# Config parsing and writes use byte-oriented I/O so edits can preserve existing lines.
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW LOCK_EX LOCK_NB);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;

my ($root, $operator, $mode, @args) = @ARGV;
my $project = "$root/.agentic-flow/config";
my $registry = "$root/config/config-keys.tsv";
my $byte_limit = 64 * 1024;
my $key_pattern = qr/[a-z][a-z0-9_.-]{0,63}/;
my (@keys, %keys);

sub error {
    my ($status, $message) = @_;
    print STDERR "config: $message\n";
    exit $status;
}

sub usage {
    error(2, 'usage: agentic-flow config [list [--json] | get <key> | explain <key> | pin | set <key> <value> [--scope project|operator] | unset <key> [--scope project|operator] | init [--missing] [--print]]');
}

sub bounded_read {
    my ($fh, $source) = @_;
    my $bytes;
    defined read($fh, $bytes, $byte_limit + 1) or error(5, "$source: $!");
    length($bytes) <= $byte_limit or error(2, "$source:1: file exceeds 64 KiB");
    return $bytes;
}

sub file_bytes {
    my ($file) = @_;
    if (!lstat $file) {
        return undef if $! == ENOENT;
        error(5, "$file: $!");
    }
    -f _ && !-l _ or error(5, "$file: expected a regular file");
    sysopen(my $fh, $file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or error(5, "$file: $!");
    -f $fh or error(5, "$file: expected a regular file");
    return bounded_read($fh, $file);
}

sub lines {
    my ($bytes, $source) = @_;
    my @lines = split /(?<=\n)/, $bytes;
    @lines <= 256 or error(2, "$source:257: file exceeds 256 lines");
    return @lines;
}

sub valid_value {
    my ($type, $value) = @_;
    return 0 if length($value) > 256;
    if ($type =~ /\Aint:([0-9]{1,6})-([0-9]{1,6})\z/) {
        my ($min, $max) = ($1, $2);
        return $value =~ /\A(?:0|[1-9][0-9]{0,5})\z/ && $value >= $min && $value <= $max;
    }
    if ($type =~ /\Adecimal:([0-9]{1,6})\.0-([0-9]{1,6})\.0\z/) {
        my ($min, $max) = ($1, $2);
        return 0 unless $value =~ /\A(0|[1-9][0-9]{0,5})(?:\.([0-9]+))?\z/;
        my ($whole, $fraction) = ($1, $2 // '');
        return $whole >= $min && ($whole < $max || ($whole == $max && $fraction !~ /[1-9]/));
    }
    return scalar grep { $value eq $_ } split /\|/, $type;
}

sub range_text {
    my ($type) = @_;
    $type =~ s/\A(?:int|decimal)://;
    return $type;
}

sub load_registry {
    my ($bytes, $registry) = @_;
    defined $bytes or error(5, "$registry: missing registry");
    my ($header, @rows) = lines($bytes, $registry);
    defined $header && $header eq "key\ttier\ttype\tdefault\tsummary\n" && @rows
        or error(2, "$registry:1: invalid registry header or empty registry");
    my $line = 1;
    my %env_names;
    for my $row (@rows) {
        ++$line;
        chomp $row;
        my ($key, $tier, $type, $default, $summary, @extra) = split /\t/, $row, -1;
        defined $summary && !@extra && $key =~ /\A$key_pattern\z/ && !exists $keys{$key}
            && $tier =~ /\A(?:plan|project|operator)\z/ && $summary =~ /\A[^\x00-\x1f\x7f]+\z/
            && $type =~ /\A(?:(?:int:[0-9]{1,6}-[0-9]{1,6}|decimal:[0-9]{1,6}\.0-[0-9]{1,6}\.0)|[a-z0-9:]+(?:\|[a-z0-9:]+)+)\z/
            && valid_value($type, $default)
            or error(2, "$registry:$line: invalid registry row");
        my $env = 'AGENTIC_FLOW_' . uc $key;
        $env =~ tr/.-/__/;
        !$env_names{$env}++ or error(2, "$registry:$line: duplicate environment name $env");
        push @keys, $key;
        $keys{$key} = {tier => $tier, type => $type, default => $default, summary => $summary, env => $env};
    }
}

sub read_layer {
    my ($bytes, $source, $layer, $ci) = @_;
    my (%entries, %listed, %seen);
    my $index = 0;
    for my $line (lines($bytes, $source)) {
        my $number = ++$index;
        my $at = "$source:$number";
        $line =~ s/\r?\n\z//;
        $line !~ /[\x00-\x08\x0b-\x1f\x7f]/ or error(2, "$at: invalid control character");
        next if $line =~ /\A[ \t]*\z/;
        if ($line =~ /\A[ \t]*#/) {
            my ($key, $value) = $line =~ /\A[ \t]*#[ \t]*($key_pattern)=(.{0,256})\z/;
            if (defined $key && exists $keys{$key} && valid_value($keys{$key}{type}, $value)) {
                $listed{$key} //= $number - 1;
            }
            next;
        }
        my ($key, $value) = $line =~ /\A($key_pattern)=(.{0,256})\z/;
        defined $key or error(2, "$at: expected key=value (key <= 64 and value <= 256 bytes)");
        exists $keys{$key} or error(2, "$at: unknown key $key");
        !$seen{$key}++ or error(2, "$at: duplicate key $key");
        $listed{$key} = $number - 1;
        if ($layer eq 'operator' && $ci && $key =~ /\Abudget\./) {
            print STDERR "config: CI=true ignores $key from $at\n";
            next;
        }
        my $entry = $keys{$key};
        $layer ne 'operator' || $entry->{tier} eq 'operator'
            or error(2, "$at: $key has tier $entry->{tier} and cannot be set by the operator");
        valid_value($entry->{type}, $value)
            or error(2, "$at: invalid value for $key (expected " . range_text($entry->{type}) . ')');
        $entries{$key} = $value;
    }
    return (\%entries, \%listed);
}

sub project_bytes {
    -l dirname($project) and error(5, "$project: project config directory is a symlink");
    return file_bytes($project);
}

sub resolve {
    my $ci = $mode eq 'ci';
    my ($values) = read_layer(project_bytes() // '', $project, 'project', $ci);
    my ($operator_values) = $operator ne ''
        ? read_layer(file_bytes($operator) // '', $operator, 'operator', $ci)
        : ({});
    my %resolved;
    for my $key (@keys) {
        my $entry = $keys{$key};
        my $env = $entry->{env};
        my ($value, $source) = ($entry->{default}, 'default');
        if (exists $values->{$key} && !($ci && $key eq 'budget.wall.scale')) {
            ($value, $source) = ($values->{$key}, $project);
        }
        if (exists $operator_values->{$key}) {
            ($value, $source) = ($operator_values->{$key}, $operator);
        }
        if (exists $ENV{$env}) {
            if ($ci && $key =~ /\Abudget\./) {
                print STDERR "config: CI=true ignores $key from $env\n";
            } else {
                $entry->{tier} eq 'operator'
                    or error(2, "$env: $key has tier $entry->{tier} and cannot be set in the environment");
                valid_value($entry->{type}, $ENV{$env})
                    or error(2, "$env: invalid value for $key (expected " . range_text($entry->{type}) . ')');
                ($value, $source) = ($ENV{$env}, $env);
            }
        }
        $resolved{$key} = {value => $value, source => $source, tier => $entry->{tier}};
    }
    return \%resolved;
}

sub git_bytes {
    my ($source, @command) = @_;
    open my $fh, '-|', 'git', '-C', $root, @command or error(5, "$source: $!");
    my $bytes = bounded_read($fh, $source);
    close $fh or error(5, "$source: cannot read Git object");
    return $bytes;
}

sub revision_file_bytes {
    my ($oid, $path, $source) = @_;
    my $row = git_bytes($source, 'ls-tree', '--full-tree', $oid, '--', $path);
    return undef if $row eq '';
    $row =~ /\A100(?:644|755) blob ([a-f0-9]{40,64})\t\Q$path\E\n\z/
        or error(5, "$source: expected a regular file");
    return git_bytes($source, 'cat-file', 'blob', $1);
}

sub pin {
    my ($rev) = @_;
    my ($bytes, $source);
    if (defined $rev) {
        $source = "$rev:.agentic-flow/config";
        my $oid = git_bytes($source, 'rev-parse', '--verify', '--end-of-options', "$rev^{commit}");
        chomp $oid;
        $bytes = revision_file_bytes($oid, '.agentic-flow/config', $source);
        my $registry_at_rev = "$rev:config/config-keys.tsv";
        my $registry_bytes = revision_file_bytes($oid, 'config/config-keys.tsv', $registry_at_rev);
        # A base from before the config registry uses the running harness's defaults.
        if (defined $registry_bytes) {
            load_registry($registry_bytes, $registry_at_rev);
        } else {
            load_registry(file_bytes($registry), $registry);
        }
    } else {
        $source = $project;
        load_registry(file_bytes($registry), $registry);
        $bytes = project_bytes();
    }
    my ($values) = read_layer($bytes // '', $source, 'project', 0);
    print join(' ', map { "$_=" . ($values->{$_} // $keys{$_}{default}) }
        grep { $keys{$_}{tier} eq 'plan' } @keys), "\n";
}

sub template_entry {
    my ($key) = @_;
    my $entry = $keys{$key};
    return "# $key — $entry->{summary}\n"
        . "# tier: $entry->{tier} · range: " . range_text($entry->{type}) . " · default: $entry->{default}\n"
        . "#$key=$entry->{default}\n";
}

sub template {
    return <<'HEADER';
# agentic-flow project config. Commented keys use their defaults.
# Change one with: agentic-flow config set <key> <value>   then review and commit.
# Tiers: plan = frozen into each plan at approval · project = this file only ·
#        operator = may be overridden per machine (~/.config, AGENTIC_FLOW_*).
# Not configurable: merge, ship and hold-clear stay human-only; see C-1's floor table.
HEADER
}

sub append_entries {
    my ($bytes, @keys) = @_;
    return $bytes unless @keys;
    $bytes .= "\n" if length($bytes) && $bytes !~ /\n\z/;
    return $bytes . ($bytes eq '' ? '' : "\n") . join("\n", map { template_entry($_) } @keys);
}

sub atomic_edit {
    my ($file, $scope, $edit) = @_;
    my $dir = dirname($file);
    if (!-d $dir) {
        eval { make_path($dir, {mode => $scope eq 'operator' ? 0700 : 0777}); 1 }
            or error(5, "$dir: $@");
    }
    # Keep one directory inode locked through read, validation and publication.
    # A contending writer can retry without leaving a lock file in the project.
    sysopen(my $lock, $dir, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or error(5, "$dir: $!");
    flock($lock, LOCK_EX | LOCK_NB) or error(5, "$dir: cannot lock config directory: $!");
    my $old = file_bytes($file);
    my $new = $edit->($old);
    return if !defined $new || (defined $old && $old eq $new);
    length($new) <= $byte_limit or error(2, "$file:1: file exceeds 64 KiB");
    read_layer($new, $file, $scope, 0);
    my ($out, $temp) = eval { tempfile('.config.XXXXXXXX', DIR => $dir, UNLINK => 1) };
    defined $out or error(5, "$dir: $@");
    my $perm = $scope eq 'operator' ? 0600 : 0666 & ~umask();
    if (defined $old) {
        my @metadata = stat($file);
        @metadata or error(5, "$file: $!");
        $perm = $metadata[2] & 0777;
    }
    print {$out} $new or error(5, "$temp: $!");
    chmod $perm, $out or error(5, "$temp: $!");
    close $out or error(5, "$temp: $!");
    rename $temp, $file or error(5, "$file: $!");
}

sub init_config {
    my ($missing, $print, %seen);
    for my $flag (@_) {
        usage() if $seen{$flag}++;
        if ($flag eq '--missing') { $missing = 1 }
        elsif ($flag eq '--print') { $print = 1 }
        else { usage() }
    }
    my $render = sub {
        my ($old) = @_;
        return append_entries(template(), @keys) unless defined $old;
        $missing or error(2, "$project: already exists; use config init --missing");
        my (undef, $listed) = read_layer($old, $project, 'project', 0);
        return append_entries($old, grep { !exists $listed->{$_} } @keys);
    };
    if ($print) {
        my $new = $render->(project_bytes());
        length($new) <= $byte_limit or error(2, "$project:1: file exceeds 64 KiB");
        read_layer($new, $project, 'project', 0);
        print $new;
    } else {
        atomic_edit($project, 'project', $render);
    }
}

sub change {
    my ($action, $key, @options) = @_;
    defined $key or usage();
    my $value = $action eq 'set' ? shift @options : undef;
    $action ne 'set' || defined $value or usage();
    my $scope = 'project';
    if (@options) {
        @options == 2 && $options[0] eq '--scope' && $options[1] =~ /\A(?:project|operator)\z/ or usage();
        $scope = $options[1];
    }
    my $entry = $keys{$key} or error(3, "unknown key $key");
    $scope ne 'operator' || $entry->{tier} eq 'operator'
        or error(3, "$key has tier $entry->{tier} and cannot be set in operator scope");
    # Every accepted value is a bounded number or a registry enum, excluding credentials.
    $action ne 'set' || valid_value($entry->{type}, $value)
        or error(2, "invalid value for $key (expected " . range_text($entry->{type}) . ')');
    my $file = $scope eq 'project' ? $project : $operator;
    $file ne '' or error(5, 'operator scope requires a GitHub origin and a config home');
    if ($action eq 'unset' && !lstat $file) {
        return if $! == ENOENT;
        error(5, "$file: $!");
    }
    atomic_edit($file, $scope, sub {
        my ($old) = @_;
        $old //= '';
        my ($values, $listed) = read_layer($old, $file, $scope, 0);
        return undef if $action eq 'unset' && !exists $values->{$key};
        my @lines = lines($old, $file);
        my $new = $action eq 'set' ? "$key=$value" : "#$key=$entry->{default}";
        if (exists $listed->{$key}) {
            my $i = $listed->{$key};
            my ($ending) = $lines[$i] =~ /(\r?\n)\z/;
            $lines[$i] = $new . ($ending // '');
            return join '', @lines;
        }
        $old .= "\n" if length($old) && $old !~ /\n\z/;
        return $old . "$new\n";
    });
}

my $action = shift(@args) // 'list';
if ($action eq '--json') {
    unshift @args, $action;
    $action = 'list';
}
if ($action eq 'pin') {
    @args <= 1 or usage();
    pin(@args);
    exit 0;
}
load_registry(file_bytes($registry), $registry);
if ($action eq 'init') {
    init_config(@args);
} elsif ($action eq 'set' || $action eq 'unset') {
    change($action, @args);
} elsif ($action eq 'diagnose') {
    my $bytes = project_bytes();
    if (!defined $bytes) {
        print "info    .agentic-flow/config is absent (run agentic-flow config init)\n";
    } else {
        my (undef, $listed) = read_layer($bytes, $project, 'project', 0);
        my @missing = grep { !exists $listed->{$_} } @keys;
        print 'info    .agentic-flow/config does not list ' . join(', ', @missing) .
            " (run agentic-flow config init --missing)\n" if @missing;
    }
} elsif ($action eq 'list') {
    @args == 0 || (@args == 1 && $args[0] eq '--json') or usage();
    my $resolved = resolve();
    if (@args) {
        print JSON::PP->new->canonical->encode($resolved), "\n";
    } else {
        print join("\t", $_, @{$resolved->{$_}}{qw(value source tier)}), "\n" for @keys;
    }
} elsif ($action eq 'get' || $action eq 'explain') {
    @args == 1 or usage();
    my ($key) = @args;
    my $entry = $keys{$key} or error(3, "unknown key $key");
    my $resolved = resolve()->{$key};
    if ($action eq 'get') {
        print "$resolved->{value}\n";
    } else {
        my %override = (
            plan => 'project file, frozen into the plan at approval',
            project => 'project file',
            operator => 'project file, operator file or environment',
        );
        print "$key=$resolved->{value}\nsource: $resolved->{source}\ntier: $entry->{tier}\n",
            'range: ', range_text($entry->{type}), "\noverrides: $override{$entry->{tier}}\n";
    }
} else {
    usage();
}
