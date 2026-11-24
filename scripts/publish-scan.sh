#!/usr/bin/env bash
# Audit publication surfaces without writing to Git or GitHub.
set -eu
scan_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
exec perl - "$scan_root" "$@" <<'PERL'
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IO::Handle;
use IPC::Open3;
use JSON::PP;
use MIME::Base64 qw(decode_base64 encode_base64);

my $scanner_root = shift;
my ($scope, $report, $resolve) = ('all');
my ($error, $head, $git_version, $leaks_version, $gh_version, $scratch);
my (@rules, %allowed, %findings, %resolved, @corpus, %locations);
my ($corpus_bytes, $objects_seen, $paths_seen, $api_rows) = (0, 0, 0, 0);
my $max_output = 64 * 1024 * 1024;
my $json = JSON::PP->new->utf8;
my $oid_re = qr/(?:[a-f0-9]{40}|[a-f0-9]{64})/a;
my $rule_re = qr/[a-z][a-z0-9_-]{0,79}/a;
my $num_re = qr/[1-9][0-9]{0,14}/a;

sub fail { $error = $_[0]; die "\n"; }
sub short_hash { substr sha256_hex($_[0]), 0, 12; }
sub selected { $scope eq 'all' || $scope eq $_[0]; }

# Child output can contain paths, credentials or remote response text. Only
# fixed diagnostics cross the output boundary until scanning has finished.
open my $quiet, '>', File::Spec->devnull or die "publish scan: could not open the null device\n";
sub command {
    my ($diagnostic, @args) = @_;
    my $pid = open my $pipe, '-|';
    defined $pid or fail($diagnostic);
    if (!$pid) {
        open STDERR, '>&', $quiet or exit 127;
        alarm($args[0] eq 'gitleaks' ? 180 : 30);
        exec {$args[0]} @args or exit 127;
    }
    binmode $pipe;
    my $data = '';
    while (1) {
        my $bytes = read $pipe, my $chunk, 65536;
        defined $bytes or fail($diagnostic);
        last unless $bytes;
        $data .= $chunk;
        if (length($data) > $max_output) {
            kill 'KILL', $pid;
            close $pipe;
            fail("$diagnostic (output limit exceeded)");
        }
    }
    close $pipe;
    my $status = $?;
    return ($data, $status);
}

sub checked {
    my ($diagnostic, @args) = @_;
    my ($out, $status) = command($diagnostic, @args);
    $status == 0 or fail($diagnostic);
    return $out;
}

sub git { checked(shift, 'git', @_) }

sub args {
    while (@ARGV) {
        my $flag = shift @ARGV;
        if ($flag eq '--help') {
            print "Usage: publish-scan.sh [--surface tree|history|metadata|github|all] [--report <path>] [--resolve <location-id>]\n";
            exit 0;
        }
        @ARGV && $ARGV[0] !~ /\A--/ or fail('missing option value; see --help');
        my $value = shift @ARGV;
        if ($flag eq '--surface') { $scope = $value }
        elsif ($flag eq '--report') { $report = $value }
        elsif ($flag eq '--resolve') { $resolve = $value }
        else { fail('invalid option; see --help') }
    }
    $scope =~ /\A(?:tree|history|metadata|github|all)\z/ or fail('invalid surface; see --help');
    !defined($resolve) || ($resolve =~ /\A[a-f0-9]{12}\z/ && !defined($report))
        or fail('resolve needs a location ID and terminal output');
}

sub load_config {
    my ($root) = @_;
    for my $file (qw(publish-scan.tsv publish-scan-allow.tsv)) {
        open my $config, '<:raw', "$root/config/$file" or fail('could not read publication scan configuration');
        my (%seen, $rows);
        while (my $row = <$config>) {
            ++$rows <= 10000 && length($row) <= 8192 or fail('publication scan configuration limit exceeded');
            chomp $row;
            next if $row =~ /\A(?:#|\s*\z)/;
            my @columns = split /\t/, $row, -1;
            @columns == 4 && $columns[3] =~ /\S/ or fail('malformed publication scan configuration');
            my ($first, $second, $third) = @columns;
            if ($file eq 'publish-scan.tsv') {
                $first =~ /\A$rule_re\z/ && $second =~ /\A(?:all|tree|history|metadata|github|path)\z/
                    && length($third) && !$seen{"$first\t$second"}++ or fail('invalid publication scan rule');
                if ($third =~ /\Asha256:([a-f0-9]{64}(?:,[a-f0-9]{64})*)\z/) {
                    my %digests = map { $_ => 1 } split /,/, $1;
                    push @rules, [$first, $second, undef, \%digests];
                } else {
                    my $pattern = eval { qr/$third/ };
                    defined($pattern) && '' !~ $pattern or fail('invalid publication scan pattern');
                    push @rules, [$first, $second, $pattern, undef];
                }
            } else {
                $first =~ /\A[a-f0-9]{12}\z/ && $second =~ /\A$rule_re\z/ && $third =~ /\A[a-f0-9]{12}\z/
                    or fail('invalid publication scan allow-list key');
                $allowed{"$first $second $third"} = 1;
            }
        }
        close $config or fail('could not finish reading publication scan configuration');
    }
}

sub local_completeness {
    my $shallow = git('could not determine shallow repository state', 'rev-parse', '--is-shallow-repository');
    $shallow eq "false\n" or fail('shallow repository; full history is required');
    my ($partial, $config_status) = command('could not check clone configuration', 'git', 'config',
        '--get-regexp', '^(extensions\.partialclone|remote\..*\.promisor)$');
    $config_status == 0 || $config_status == 256 or fail('could not check clone configuration');
    $partial eq '' or fail('partial clone or promisor remote; all objects are required');
    my $grafts = git('could not locate Git graft data', 'rev-parse', '--git-path', 'info/grafts');
    chomp $grafts;
    !-s $grafts or fail('Git grafts alter reachable history');
}

sub local_refs {
    return git('could not enumerate local refs', 'for-each-ref', '--format=%(objectname)%09%(refname)');
}

sub remote_completeness {
    my ($refs) = @_;
    my %local;
    for my $line (split /\n/, $refs) {
        $line =~ /\A($oid_re)\t(refs\/[^\s]+)\z/ or fail('malformed local ref listing');
        $local{$2} = $1;
    }
    my $remote = git('could not list origin branches, tags and pull-request refs', 'ls-remote',
        '--refs', 'origin', 'refs/heads/*', 'refs/tags/*', 'refs/pull/*/head');
    my %seen;
    for my $line (split /\n/, $remote) {
        $line =~ /\A($oid_re)\t(refs\/[^\s]+)\z/ or fail('malformed origin ref listing');
        my ($object, $ref) = ($1, $2);
        !$seen{$ref}++ or fail('duplicate origin ref in listing');
        if ($ref =~ m{\Arefs/heads/(.+)\z}) {
            (grep { ($local{$_} // '') eq $object } ($ref, "refs/remotes/origin/$1"))
                or fail('remote branch is missing or at a different SHA');
        } elsif ($ref =~ m{\Arefs/tags/}) {
            ($local{$ref} // '') eq $object or fail('remote tag is missing or at a different SHA');
        } elsif ($ref =~ m{\Arefs/pull/($num_re)/head\z}) {
            (grep { ($local{$_} // '') eq $object } ($ref, "refs/remotes/origin/pull/$1/head"))
                or fail('pull-request ref is missing or at a different SHA');
        } else {
            fail('unexpected ref in origin listing');
        }
    }
    return $remote;
}

sub location {
    my ($name) = @_;
    my $id = short_hash($name);
    $resolved{$name} = 1 if defined($resolve) && $resolve eq $id;
    return $id;
}

sub finding {
    my ($surface, $object, $location_id, $rule, $value) = @_;
    my $key = join ' ', $location_id, $rule, short_hash($value);
    return if $allowed{$key};
    $findings{"$surface $object $key"} = 1;
}

sub patterns {
    my ($surface, $object, $id, $data, $is_path) = @_;
    for my $entry (@rules) {
        my ($rule, $rule_surface, $pattern, $digests) = @$entry;
        next unless $rule_surface eq 'all' || $rule_surface eq $surface || ($is_path && $rule_surface eq 'path');
        if (defined $digests) {
            while ($data =~ /[a-zA-Z0-9_.-]+/g) {
                my $value = $&;
                $value =~ s/^\.+|\.+$//g;
                my $without_suffix = $value;
                $without_suffix =~ s/\.git\z//;
                for my $name ($value, $without_suffix) {
                    finding($surface, $object, $id, $rule, $name) if $digests->{sha256_hex($name)};
                }
            }
            next;
        }
        while ($data =~ /$pattern/g) {
            my $value = $+{value} // $&;
            next unless length $value;
            finding($surface, $object, $id, $rule, $value);
        }
    }
}

sub corpus_entry {
    my ($surface, $object, $path, $data) = @_;
    my $id = location($path);
    return if defined $resolve;
    patterns($surface, $object, $id, $data, 0);
    $corpus_bytes += length $data;
    $corpus_bytes <= 1024 * 1024 * 1024 && @corpus < 250000 or fail('credential scan corpus limit exceeded');

    # A numeric parent keeps aliases and case variants distinct. Preserve the
    # filename for Gitleaks rules that use it, without trusting Git paths as
    # filesystem paths. Every staged blob is a regular file, including symlinks.
    my ($basename) = $path =~ m{([^/]+)\z};
    $basename //= 'content';
    $basename =~ s/[^a-zA-Z0-9_.-]/_/g;
    $basename = substr $basename, 0, 160;
    $basename = 'content' if $basename eq '.' || $basename eq '..';
    my $index = @corpus;
    my $dir = "$scratch/corpus/$index";
    mkdir $dir or fail('could not stage the credential scan corpus');
    my $file_name = "$dir/$basename";
    open my $file, '>:raw', $file_name or fail('could not stage the credential scan corpus');
    print {$file} $data and close $file or fail('could not write the credential scan corpus');
    push @corpus, [$surface, $object, $id, $file_name];
}

sub tree_paths {
    my ($commit, $surface) = @_;
    my $tree = git('could not read a commit tree', 'ls-tree', '-r', '-z', $commit);
    for my $entry (split /\0/, $tree) {
        ++$paths_seen <= 2000000 or fail('commit tree path limit exceeded');
        my ($mode, $type, $oid, $path) = $entry =~ /\A([0-7]{6}) (blob|commit) ($oid_re)\t(.+)\z/s
            or fail('malformed commit tree');
        my $short = substr $oid, 0, 12;
        my $id = location($path);
        next if $mode ne '160000' && $locations{$surface}{$oid}{$path}++;
        patterns($surface, $short, $id, $path, 1) unless defined $resolve;
    }
}

sub object_ids {
    my ($surface, $commits) = @_;
    if ($surface eq 'tree') {
        tree_paths($head, 'tree');
        return keys %{$locations{tree} // {}};
    }
    if (defined $commits && $surface eq 'history') {
        tree_paths($_, 'history') for @$commits;
    }
    return split /\n/, git('could not enumerate reachable objects', 'rev-list',
        '--objects', '--all', '--no-object-names', 'HEAD');
}

sub ssh_signer {
    my ($data) = @_;
    return unless $data =~ /-----BEGIN SSH SIGNATURE-----\n(.*?)-----END SSH SIGNATURE-----/s;
    my $signature = decode_base64($1);
    my ($version, $length) = unpack 'x6NN', $signature;
    substr($signature, 0, 6) eq 'SSHSIG' && ($version // 0) == 1 && $length && $length <= length($signature) - 14
        or fail('malformed SSH signing metadata');
    my $fingerprint = encode_base64(Digest::SHA::sha256(substr($signature, 14, $length)), '');
    $fingerprint =~ s/=+\z//;
    return "SHA256:$fingerprint";
}

sub commit_text {
    my ($oid, $data, $surfaces) = @_;
    my $object = substr $oid, 0, 12;
    my $path = "commit/$oid";
    my ($headers, $message) = split /\n\n/, $data, 2;
    defined $message or fail('malformed commit object');
    corpus_entry('history', $object, $path, $message) if $surfaces->{history};
    if ($surfaces->{metadata}) {
        my @identity = $headers =~ /^(?:author|committer) (.*) [0-9]+ [+-][0-9]{4}$/mg;
        @identity == 2 or fail('malformed commit identity');
        my $key = ssh_signer($headers);
        corpus_entry('metadata', $object, $path, join "\n", @identity, (defined($key) ? $key : ()));
    }
}

sub tag_text {
    my ($oid, $data) = @_;
    my ($headers, $message) = split /\n\n/, $data, 2;
    defined $message or fail('malformed tag object');
    my @metadata = $headers =~ /^(?:tag|tagger) (.+)$/mg;
    my $key = ssh_signer($message);
    corpus_entry('metadata', substr($oid, 0, 12), "tag/$oid",
        join "\n", @metadata, $message, (defined($key) ? $key : ()));
}

sub batch_objects {
    my ($ids, $surfaces) = @_;
    return unless @$ids;
    my ($input, $output);
    my $pid = open3($input, $output, '>&' . fileno($quiet), 'git', 'cat-file', '--batch');
    binmode $_ for ($input, $output);
    $input->autoflush(1);
    for my $oid (@$ids) {
        ++$objects_seen <= 250000 && $oid =~ /\A$oid_re\z/ or fail('object scan limit exceeded or invalid object ID');
        print {$input} "$oid\n" or fail('could not request a Git object');
        my $line = <$output> // '';
        my ($type, $length) = $line =~ /\A\Q$oid\E (blob|commit|tag|tree) ([0-9]{1,9})\n\z/
            or fail('reachable Git object is missing or unreadable');
        $length <= $max_output or fail('Git object exceeds the scan size limit');
        my $read = read($output, my $data, $length);
        defined($read) && $read == $length && (getc($output) // '') eq "\n"
            or fail('truncated Git object data');
        if ($type eq 'blob') {
            for my $surface (qw(tree history)) {
                next unless $surfaces->{$surface};
                my $paths = $locations{$surface}{$oid} // { "blob/$oid" => 1 };
                for my $path (keys %$paths) {
                    corpus_entry($surface, substr($oid, 0, 12), $path, $data);
                }
            }
        } elsif ($type eq 'commit') {
            commit_text($oid, $data, $surfaces);
        } elsif ($type eq 'tag' && $surfaces->{metadata}) {
            tag_text($oid, $data);
        }
    }
    close $input or fail('could not finish requesting Git objects');
    close $output or fail('could not finish reading Git objects');
    waitpid($pid, 0) == $pid && $? == 0 or fail('Git object scan failed');
}

sub history_and_metadata {
    return unless selected('history') || selected('metadata');
    my @commits = split /\n/, git('could not enumerate reachable commits', 'rev-list', '--all', 'HEAD');
    @commits <= 10000 && !grep { !/\A$oid_re\z/ } @commits or fail('commit scan limit exceeded or invalid commit ID');
    my $surface = selected('history') ? 'history' : 'metadata';
    my @oids = object_ids($surface, \@commits);
    batch_objects(\@oids, { history => selected('history'), metadata => selected('metadata') });
    return unless selected('metadata') && !defined $resolve;
    my $signers = git('could not read Git signing keys', 'log', '--no-show-signature', '--all', 'HEAD', '--format=%H%x09%GK');
    for my $line (split /\n/, $signers) {
        my ($commit, $key) = $line =~ /\A($oid_re)\t([^\r\n]*)\z/ or fail('malformed Git signing metadata');
        patterns('metadata', substr($commit, 0, 12), location("commit/$commit"), $key, 0) if length $key;
    }
}

sub github_repo {
    my $url = git('could not determine the GitHub repository from origin', 'remote', 'get-url', 'origin');
    chomp $url;
    my ($repo) = $url =~ m{\A(?:https://github\.com/|git\@github\.com:|ssh://git\@github\.com/)([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+?)(?:\.git)?\z};
    defined $repo && $repo !~ m{(?:\A|/)\.{1,2}(?:/|\z)} or fail('origin is not a supported GitHub repository URL');
    return $repo;
}

sub api {
    my ($endpoint) = @_;
    my $raw = checked('GitHub API request failed', 'gh', 'api', '--hostname', 'github.com',
        '--method', 'GET', '--include', $endpoint);
    my ($headers, $body) = split /\r?\n\r?\n/, $raw, 2;
    defined($body) && $headers =~ /\AHTTP\/\d(?:\.\d)? 200(?:[ \r\n]|\z)/
        or fail('GitHub API returned malformed headers or status');
    my $data = eval { $json->decode($body) };
    !$@ or fail('GitHub API returned malformed JSON');
    return ($data, $headers);
}

sub numeric_field {
    my ($row, $name, $positive) = @_;
    my $value = $row->{$name};
    defined($value) && !ref($value) && $value =~ /\A(?:$num_re|0)\z/ && (!$positive || $value > 0)
        or fail('GitHub API returned an invalid identifier or count');
    return $value;
}

sub github_pages {
    my ($endpoint, $expected, $visit) = @_;
    my %seen;
    my $total = 0;
    for my $page (1 .. 1000) {
        my $separator = index($endpoint, '?') == -1 ? '?' : '&';
        my ($rows, $headers) = api("${endpoint}${separator}per_page=100&page=$page");
        ref($rows) eq 'ARRAY' && @$rows <= 100 or fail('GitHub API returned an invalid page');
        my @links = $headers =~ /^link:[ \t]*(.*?)[ \t]*\r?$/gmi;
        @links <= 1 or fail('GitHub API returned ambiguous page links');
        my ($next, $last);
        if (@links) {
            for my $link (split /,\s*/, $links[0]) {
                my ($url, $rel) = $link =~ /\A<([^<>]+)>;\s*rel="(next|prev|first|last)"\z/
                    or fail('GitHub API returned a malformed page link');
                next unless $rel eq 'next' || $rel eq 'last';
                my ($query) = $url =~ m{\Ahttps://api\.github\.com/[^?]+\?([^#]+)\z}
                    or fail('GitHub API returned an unexpected page URL');
                my @page_numbers = $query =~ /(?:\A|&)page=($num_re)(?=&|\z)/g;
                @page_numbers == 1 or fail('GitHub API returned an invalid page number');
                my $target = $rel eq 'next' ? \$next : \$last;
                !defined $$target or fail('GitHub API returned ambiguous page links');
                $$target = $page_numbers[0];
            }
        }
        !defined($last) || $last <= $page || defined($next) or fail('GitHub API omitted a next-page link');
        !defined($next) || $next == $page + 1 or fail('GitHub API returned an unexpected next page');
        !defined($next) || @$rows == 100 or fail('GitHub API returned a truncated page');
        ++$api_rows <= 100000 or fail('GitHub API scan row limit exceeded') for @$rows;
        for my $row (@$rows) {
            ref($row) eq 'HASH' or fail('GitHub API returned an invalid row');
            my $id = numeric_field($row, 'id', 1);
            !$seen{$id}++ or fail('GitHub API repeated a row across pages');
            $visit->($row, $id);
        }
        $total += @$rows;
        if (!defined($next) && @$rows < 100) {
            !defined($expected) || $total == $expected or fail('GitHub API returned a truncated collection');
            return;
        }
    }
    fail('GitHub API page limit exceeded');
}

sub github_text {
    my ($url, $row, @fields) = @_;
    my @values;
    for my $field (@fields) {
        exists($row->{$field}) && !ref($row->{$field}) or fail('GitHub API omitted a text field');
        push @values, encode_utf8($row->{$field}) if defined $row->{$field};
    }
    corpus_entry('github', '-', $url, join "\n", @values);
}

sub github {
    my $repo = github_repo();
    my $endpoint = "repos/$repo";
    my $web = "https://github.com/$repo";
    my (%issue_prs, %issue_numbers, @issues, @pulls);
    github_pages("$endpoint/issues?state=all&sort=created&direction=asc", undef, sub {
        my ($row) = @_;
        my $number = numeric_field($row, 'number', 1);
        !$issue_numbers{$number}++ or fail('GitHub API repeated an issue number');
        my $comments = numeric_field($row, 'comments', 0);
        my $is_pr = exists $row->{pull_request};
        my $url = $is_pr ? "$web/pull/$number" : "$web/issues/$number";
        $issue_prs{$number} = 1 if $is_pr;
        github_text($url, $row, 'title', 'body');
        push @issues, [$number, $comments, $url];
    });
    github_pages("$endpoint/pulls?state=all&sort=created&direction=asc", undef, sub {
        my ($row) = @_;
        my $number = numeric_field($row, 'number', 1);
        delete $issue_prs{$number} or fail('GitHub issue and pull-request listings disagree');
        github_text("$web/pull/$number", $row, 'title', 'body');
        push @pulls, $number;
    });
    !%issue_prs or fail('GitHub pull-request listing is incomplete');
    for my $issue (@issues) {
        my ($number, $comments, $url) = @$issue;
        github_pages("$endpoint/issues/$number/comments", $comments, sub {
            my ($row, $id) = @_;
            github_text("$url#issuecomment-$id", $row, 'body');
        });
    }
    for my $number (@pulls) {
        my $url = "$web/pull/$number";
        my ($pull) = api("$endpoint/pulls/$number");
        ref($pull) eq 'HASH' && numeric_field($pull, 'number', 1) == $number
            or fail('GitHub API returned the wrong pull request');
        my $comments = numeric_field($pull, 'review_comments', 0);
        github_pages("$endpoint/pulls/$number/comments", $comments, sub {
            my ($row, $id) = @_;
            github_text("$url#discussion_r$id", $row, 'body');
        });
        github_pages("$endpoint/pulls/$number/reviews", undef, sub {
            my ($row, $id) = @_;
            github_text("$url#pullrequestreview-$id", $row, 'body');
        });
    }
    github_pages("$endpoint/releases", undef, sub {
        my ($row) = @_;
        my $url = $row->{html_url} // '';
        !ref($url) && $url =~ m{\A\Q$web\E/releases/[^\s[:cntrl:]]+\z}i
            or fail('GitHub API returned an invalid release URL');
        github_text($url, $row, 'name', 'body', 'tag_name');
    });
}

sub credentials {
    return if defined $resolve;
    open my $config, '>', "$scratch/gitleaks.toml" or fail('could not configure gitleaks');
    print {$config} "[extend]\nuseDefault = true\n" and close $config or fail('could not configure gitleaks');
    # The raw JSON stays inside the pipe so allow-list hashes use the actual secret.
    my ($raw, $status) = command('gitleaks failed', 'gitleaks', 'dir', '--no-banner', '--no-color',
        '--log-level', 'error', '--report-format', 'json', '--report-path', '-',
        '--config', "$scratch/gitleaks.toml", '--gitleaks-ignore-path', $scratch, '--ignore-gitleaks-allow',
        '--exit-code', '3', '--timeout', '165', "$scratch/corpus");
    $status == 0 || $status == 3 * 256 or fail('gitleaks failed');
    my $results = eval { $json->decode($raw) };
    ref($results) eq 'ARRAY' && (@$results > 0) == ($status != 0) or fail('gitleaks returned an invalid report');
    for my $row (@$results) {
        ref($row) eq 'HASH' && !ref($row->{File}) && !ref($row->{Secret}) && !ref($row->{RuleID})
            or fail('gitleaks returned an invalid finding');
        my ($index) = ($row->{File} // '') =~ m{(?:\A|/)([0-9]{1,6})/[^/]+\z};
        my $rule = $row->{RuleID} // '';
        my $value = $row->{Secret} // '';
        defined($index) && $index < @corpus && $rule =~ /\A$rule_re\z/ && length($value)
            or fail('gitleaks finding could not be mapped to the scanned corpus');
        my ($surface, $object, $id, $file) = @{$corpus[$index]};
        ($row->{File} eq $file || "$scratch/corpus/$row->{File}" eq $file)
            or fail('gitleaks finding refers to an unknown corpus file');
        finding($surface, $object, $id, $rule, encode_utf8($value));
    }
}

sub versions {
    $git_version = git('could not determine Git version', '--version');
    $leaks_version = checked('could not determine gitleaks version', 'gitleaks', 'version');
    $gh_version = checked('could not determine GitHub CLI version', 'gh', '--version') if selected('github');
    ($git_version) = $git_version =~ /\Agit version ([0-9][0-9.]+)/;
    ($leaks_version) = $leaks_version =~ /\Av?([0-9][0-9.]+)/;
    ($gh_version) = $gh_version =~ /\Agh version ([0-9][0-9.]+)/ if defined $gh_version;
    defined($git_version) && defined($leaks_version) && (!selected('github') || defined($gh_version))
        or fail('could not parse scan tool versions');
}

sub result {
    if (defined $resolve) {
        %resolved or fail('location ID was not found on the selected surface');
        for my $name (sort keys %resolved) {
            $name =~ s/([[:cntrl:]])/sprintf '\\x%02x', ord $1/ge;
            print "$name\n";
        }
        return 0;
    }
    my @rows = sort keys %findings;
    my %counts;
    for my $row (@rows) {
        my ($surface, undef, undef, $rule) = split / /, $row;
        ++$counts{$surface}{$rule};
    }
    my $date = POSIX::strftime('%Y-%m-%d', gmtime);
    my $tools = "Git $git_version, gitleaks $leaks_version";
    $tools .= ", GitHub CLI $gh_version" if defined $gh_version;
    my $status = @rows ? 'NO-GO' : 'GO';
    my $heading = $scope eq 'all' ? "Verdict (provisional): $status"
        : "Scoped result ($scope): " . (@rows ? 'findings' : 'clean');
    my $output = "# Pre-publication scan\n\n$heading\n\nCommit: `$head`\n\nDate: $date (UTC)\n\nTools: $tools\n\n";
    $output .= "A final `scripts/publish-scan.sh --surface all` must pass on the publication state immediately before the visibility change.\n\n";
    $output .= "## Counts\n\n";
    for my $surface (grep { selected($_) } qw(tree history metadata github)) {
        my $rules = $counts{$surface} // {};
        my $total = 0;
        $total += $_ for values %$rules;
        my $by_rule = join ', ', map { "$_: $rules->{$_}" } sort keys %$rules;
        $output .= "- $surface: $total" . ($total ? " ($by_rule)" : '') . "\n";
    }
    if (@rows) {
        $output .= "\n## Findings\n\nRotate any confirmed credential first. ";
        $output .= "For tree findings, fix the tracked content or record a reviewed false positive. ";
        $output .= "For history and metadata, the owner can rewrite history or accept the finding. ";
        $output .= "For GitHub, the owner can edit or delete the content or accept the finding.\n\n";
        $output .= "```text\n" . join("\n", @rows) . "\n```\n";
    }
    if (defined $report) {
        my ($volume, $directory) = File::Spec->splitpath($report);
        my $parent = File::Spec->catpath($volume, $directory, '');
        my ($file, $tmp) = tempfile('.publish-scan-XXXXXXXX', DIR => $parent || '.', UNLINK => 1);
        print {$file} $output and close $file and rename($tmp, $report) or fail('could not write the scan report');
    }
    print $output;
    return @rows ? 1 : 0;
}

require POSIX;
$SIG{ALRM} = sub { fail('publication scan timed out') };
$SIG{PIPE} = 'IGNORE';
$SIG{__WARN__} = sub { }; # Invalid input can be embedded in library warning text.
# Never replace objects or fetch missing objects implicitly during local reads.
local $ENV{GIT_NO_REPLACE_OBJECTS} = 1;
local $ENV{GIT_NO_LAZY_FETCH} = 1;
local $ENV{GIT_TERMINAL_PROMPT} = 0;
local $ENV{GH_PROMPT_DISABLED} = 1;
my $exit = eval {
    alarm 600;
    args();
    $report = File::Spec->rel2abs($report) if defined $report;
    my $root = git('could not find the Git working tree', 'rev-parse', '--show-toplevel');
    chomp $root;
    chdir $root or fail('could not enter the Git working tree');
    $head = git('could not resolve HEAD', 'rev-parse', '--verify', 'HEAD^{commit}');
    chomp $head;
    $head =~ /\A$oid_re\z/ or fail('invalid HEAD object');
    my ($refs, $remote);
    if (selected('history') || selected('metadata')) {
        local_completeness();
        $refs = local_refs();
        $remote = remote_completeness($refs) if $scope eq 'all';
        git('Git connectivity check failed', 'fsck', '--full', '--connectivity-only', '--no-reflogs');
    }
    load_config(-e "$root/config/publish-scan.tsv" ? $root : $scanner_root);
    umask 0077;
    $scratch = abs_path(tempdir('publish-scan-XXXXXXXX', TMPDIR => 1, CLEANUP => 1))
        or fail('could not locate the credential scan corpus');
    mkdir "$scratch/corpus" or fail('could not create the credential scan corpus');
    versions() unless defined $resolve;
    if (selected('tree')) {
        my @oids = object_ids('tree');
        batch_objects(\@oids, { tree => 1 });
    }
    history_and_metadata();
    github() if selected('github');
    credentials();
    "$head\n" eq git('could not recheck HEAD', 'rev-parse', '--verify', 'HEAD^{commit}')
        && (!defined($refs) || $refs eq local_refs()) or fail('local Git refs changed during the scan');
    !defined($remote) || $remote eq remote_completeness($refs) or fail('origin refs changed during the scan');
    result();
};
alarm 0;
if (!defined $exit) {
    print STDERR 'publish scan: ', ($error // 'scanner or report operation failed'), "\n";
    exit 5;
}
exit $exit;
PERL
