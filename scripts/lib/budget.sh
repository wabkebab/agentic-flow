#!/usr/bin/env bash
# Shared budget resolution and local overrun reporting.
# shellcheck source=scripts/lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

budget_context() {
  if [ "${CI:-}" = true ]; then printf 'ci\n'; else printf 'local\n'; fi
}

budget_resolve() { # project root [--shard]; an explicit snapshot replaces the mutable layers
  local mode operator
  mode=$(budget_context)
  if [ "${AGENTIC_FLOW_BUDGET_POLICY+x}" = x ]; then
    local root=$1
    shift
    perl "$CONFIG_LIB/config-data.pl" "$root" '' "$mode" budget "$AGENTIC_FLOW_BUDGET_POLICY" "$@"
  else
    operator=$(config_operator_path "$1")
    perl "$CONFIG_LIB/config-data.pl" "$1" "$operator" "$mode" budget
  fi
}

budget_capture() { # project root, submitted SHA
  local operator
  operator=$(config_operator_path "$1")
  perl "$CONFIG_LIB/config-data.pl" "$1" "$operator" "$(budget_context)" budget-overrides "$2"
}

budget_key() { # project root, SHA, red base, command plan, explicit overrides
  perl "$CONFIG_LIB/config-data.pl" "$1" '' "$(budget_context)" budget-key "$2" "$3" "$4" "$5"
}

budget_overrun_dir() { # Refuse to inherit an enclosing repository from a fixture.
  local root=$1 top common
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$root" ] || return 1
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir) || return 1
  printf '%s/agentic-flow/state/budget-overruns\n' "$common"
}

budget_overrun_files() { # directory, prune|recent
  perl -e '
    use strict;
    use warnings;
    use Errno qw(ENOENT);
    use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
    my ($dir, $action) = @ARGV;
    opendir(my $dh, $dir) or do { exit if $! == ENOENT; die "$dir: $!" };
    my (@files, $scanned);
    while (defined(my $name = readdir $dh)) {
      ++$scanned <= 10000 or die "$dir: too many budget overrun entries\n";
      next unless $name =~ /\A[0-9]{10,}\.[0-9]{6}-[A-Za-z0-9]+\.tsv\z/;
      my $file = "$dir/$name";
      push @files, $file if lstat($file) && -f _ && !-l _;
    }
    @files = sort {$b cmp $a} @files;
    if ($action eq "prune") {
      for my $i (20 .. $#files) {
        unlink $files[$i] or $! == ENOENT or die "$files[$i]: $!";
      }
    } else {
      splice @files, 20 if @files > 20;
      my @rows;
      for my $i (0 .. $#files) {
        my $file = $files[$i];
        sysopen(my $fh, $file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or next;
        next unless -f $fh; # A concurrent writer may have pruned it.
        my $bytes;
        next unless read($fh, $bytes, 65537) && length($bytes) <= 65536;
        my $index = 0;
        for my $row (reverse split /\n/, $bytes) {
          next unless $row =~ /\A([0-9T:Z-]{20})\t[^\r\n]+\z/;
          push @rows, [$1, $i, $index++, $row];
        }
      }
      @rows = sort { $b->[0] cmp $a->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @rows;
      splice @rows, 10 if @rows > 10;
      print "$_->[3]\n" for @rows;
    }
  ' "$@"
}

budget_publish_overruns() { # project root, rows accumulated by this run
  local dir pending stamp
  dir=$(budget_overrun_dir "$1") || return 1
  mkdir -p "$dir" || return 1
  stamp=$(perl -MTime::HiRes=time -e 'printf "%.6f", time') || return 1
  pending=$(mktemp "$dir/.overruns.XXXXXX") || return 1
  if ! cat "$2" > "$pending" || ! mv "$pending" "$dir/$stamp-${pending##*.}.tsv"; then
    rm -f "$pending"
    return 1
  fi
  budget_overrun_files "$dir" prune
}

budget_doctor() { # project root
  local policy dir
  policy=$(budget_resolve "$1") || return $?
  echo 'Test budgets'
  jq -r --rawfile walls "$1/config/test-wall-ceilings.tsv" '
    (if .effective.wall_mode=="warn" then
      .sources.wall_mode as $source | $walls|split("\n")[]|select(startswith("#")|not)|
      split("\t")|select(length==2)|"  wall \(.[0]): warn (\($source))"
    else empty end),
    (if .effective.fixtures_mode=="warn" then
      .sources.fixtures_mode as $source | ["fixtures.fast","fixtures.full","fixtures.exported"][] |
      "  \(.): warn (\($source))"
    else empty end)
  ' <<< "$policy" || return 1
  if dir=$(budget_overrun_dir "$1"); then budget_overrun_files "$dir" recent; fi
}
