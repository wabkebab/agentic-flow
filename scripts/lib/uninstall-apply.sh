#!/usr/bin/env bash
# Write a per-run receipt, perform the one deletion, and verify against the plan.

uninstall_exclusive_file() { # <path>; copy stdin without reopening the destination
  perl -MFcntl=:DEFAULT -e '
    sysopen my $out, $ARGV[0], O_WRONLY | O_CREAT | O_EXCL, 0600 or die "$ARGV[0]: $!\n";
    while (1) {
        my $read = read STDIN, my $chunk, 65536;
        defined $read or die "receipt input: $!\n";
        last unless $read;
        print {$out} $chunk or die "$ARGV[0]: $!\n";
    }
    close $out or die "$ARGV[0]: $!\n";
  ' -- "$1"
}

uninstall_checkout_matches() {
  local current_branch status=0
  current_branch=$(uninstall_git symbolic-ref -q HEAD) || status=$?
  [ "$status" -le 1 ] && [ "$current_branch" = "$branch" ] &&
    [ "$(uninstall_git rev-parse --verify -q 'HEAD^{commit}')" = "$commit" ]
}

uninstall_write_receipt() {
  local expected entries
  expected=$(jq -r '.remove[] | "\(.mode) \(.blob)\t\(.path)"' <<< "$report" | LC_ALL=C sort) || return 1
  entries=$(jq -j '.remove[].path | . + "\u0000"' <<< "$report" |
    xargs -0 git -C "$uninstall_top" -c core.fsmonitor=false --literal-pathspecs ls-files -v --stage -z -- |
    perl -0ne '$. <= 2000 && s/\AH (100(?:644|755) [0-9a-f]+) 0\t([^\x00-\x1f\x7f]+)\0\z/$1\t$2\n/ or die "unexpected index entry\n"; print' |
    LC_ALL=C sort) || return 1
  if [ "$entries" != "$expected" ]; then
    printf 'The index changed while preparing the uninstall receipt.\n' >&2
    return 1
  fi
  [ ! -L "${receipt%/*}" ] && mkdir -p -- "${receipt%/*}" || return 1
  jq -j '.remove[].path | . + "\u0000"' <<< "$report" |
    uninstall_exclusive_file "$receipt.paths" || return 1
  printf '%s\n' "$entries" | tr '\n' '\000' | uninstall_exclusive_file "$receipt.index" || return 1
  {
    printf 'top=%q\nbranch=%q\ncommit=%q\nindex=%q\n' "$uninstall_top" "$branch" "$commit" "$receipt.index" &&
      cat "$UNINSTALL_LIB/uninstall-undo.sh"
  } | uninstall_exclusive_file "$receipt.undo"
}

uninstall_test_pause() {
  [ "${AGENTIC_UNINSTALL_TESTING:-}" = 1 ] && [ -n "${AGENTIC_UNINSTALL_TEST_PAUSES:-}" ] || return 0
  local point="$AGENTIC_UNINSTALL_TEST_PAUSES/$1" i
  [ -d "$point" ] || return 0
  : > "$point/ready" || return 1
  for ((i=0; i<400; i++)); do
    [ ! -f "$point/continue" ] || return 0
    sleep 0.05
  done
  printf 'Timed out at test pause %s.\n' "$1" >&2
  return 1
}

uninstall_apply_result() (
  local status_report=$1 outcome count
  outcome=$(jq -r '.outcome' <<< "$status_report")
  if [ "$output_json" = true ]; then
    printf '%s\n' "$report" "$status_report" | jq -s --arg commit "$commit" --arg receipt "$receipt" '
      (.[0] | del(._checkout, .remove[].blob)) + (.[1] | del(.incomplete[].state)) + {
        commit: $commit, receipt: {paths: ($receipt + ".paths"), index: ($receipt + ".index"), undo: ($receipt + ".undo")}
      }
    '
    exec >&2
  fi
  case "$outcome" in
    complete)
      count=$(jq '.verified_deletions | length' <<< "$status_report")
      printf 'Verified %s uninstall deletions against %s. Other staged changes are outside this check. Review git status and git diff --cached.\n' "$count" "$commit"
      return 0 ;;
    unchanged) printf 'Uninstall unchanged. Git refused and every listed path is still indexed and present. Review the Git error and run uninstall again.\n' ;;
    head-moved) printf 'Uninstall head-moved. Review git status. Restore selected paths manually with git checkout %q -- <path>.\n' "$commit" ;;
    incomplete)
      printf 'Uninstall incomplete. Review the listed paths and use the printed undo command to roll back.\n'
      jq -r '.incomplete[] |
        "  \(.path | @json): index \(if .index then "present" else "missing" end), worktree \(if .worktree then "present" else "missing" end)" +
        (if .state == "recorded" then " (matches the receipt)"
         elif .state == "different" then " (different content or mode: inspect it)"
         elif .state == "unreadable" then " (could not verify the file: inspect it)" else "" end)
      ' <<< "$status_report" ;;
  esac
  return 4
)

uninstall_apply() {
  local report=$1 output_json=$2 uninstall_top commit branch common receipt file_mode verifier
  local rm_status=0 pause_failed=false head_moved=false status_report outcome
  uninstall_top=$(jq -r '.root' <<< "$report")
  commit=$(jq -r '._checkout.commit' <<< "$report")
  branch=$(jq -r '._checkout.branch' <<< "$report")
  common=$(jq -r '._checkout.common' <<< "$report")
  file_mode=$(jq -r '._checkout.file_mode' <<< "$report")
  receipt="$common/agentic-flow/uninstall-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  verifier=$(cat "$UNINSTALL_LIB/uninstall-verify.pl")
  if ! uninstall_checkout_matches || ! uninstall_write_receipt; then
    report=$(jq '.refusals += [{reason: "receipt-failed", subject: "Could not prepare the uninstall receipt. The removal batch was skipped. Review the checkout and Git directory before retrying.", command: "git status"}]' <<< "$report")
    uninstall_print_plan "$report"
    return 4
  fi
  printf 'Undo now, before you change anything: bash %q\n' "$receipt.undo" >&2
  if ! uninstall_test_pause before-rm; then
    rm_status=1
  elif uninstall_checkout_matches; then
    uninstall_git --literal-pathspecs rm -q "--pathspec-from-file=$receipt.paths" --pathspec-file-nul || rm_status=$?
  else
    head_moved=true
  fi
  uninstall_test_pause before-check || pause_failed=true

  outcome=incomplete
  if [ "$head_moved" = true ] || ! uninstall_checkout_matches; then
    outcome=head-moved
  elif [ "$pause_failed" = false ] && status_report=$(
    cd -- "$uninstall_top" &&
      xargs -0 git -c core.fsmonitor=false --literal-pathspecs ls-files -z -- < "$receipt.paths" |
      perl -e "$verifier" -- "$rm_status" "$file_mode" 3<<< "$report"
  ); then
    if uninstall_checkout_matches; then
      uninstall_apply_result "$status_report"
      return $?
    fi
    outcome=head-moved
  else
    printf 'Could not verify every listed path. Inspect git status before proceeding.\n' >&2
  fi
  status_report=$(jq -cn --arg outcome "$outcome" '{outcome: $outcome, incomplete: [], verified_deletions: []}')
  uninstall_apply_result "$status_report"
}
