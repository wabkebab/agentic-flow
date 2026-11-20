#!/usr/bin/env bash
# Source this file, then call read_review_policy <project-root>.
review_valid_login() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?(\[bot\])?$ ]]
}

# REST user.type=Bot uses slug[bot]; GraphQL author.__typename=Bot uses slug.
# gh issue view --json comments drops the type. Read typed API data instead;
# never infer bot identity merely because a slug appears in the policy.
review_normalize_comments() {
  jq 'map((.author // .user) as $a | .author = ($a |
    if ((.__typename // .type) == "Bot") and (.login | endswith("[bot]") | not)
    then .login += "[bot]" else . end))'
}

# No output files: caller captures the child's inherited stdout in memory.
review_bounded() {
  local limit=${AGENTIC_REVIEW_TIMEOUT:-20}
  case "$limit" in
    [1-9]|1[0-9]|20) ;;
    *) echo 'review_bounded: timeout must be an integer from 1 to 20' >&2; return 2 ;;
  esac
  # One supervisor owns both the alarm and the command: no sleep child to leak.
  # Only signal an unreaped child, so a recycled PID can never be targeted.
  perl -e '
    use POSIX ();
    my ($limit, @command) = @ARGV;
    my $pid = fork;
    die "review_bounded: fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      exec { $command[0] } @command;
      POSIX::_exit($!{ENOENT} ? 127 : 126);
    }
    my $status;
    $SIG{ALRM} = sub {
      local $?;
      my $done = waitpid($pid, POSIX::WNOHANG());
      if ($done == 0) { kill "TERM", $pid; }
      elsif ($done == $pid) { $status = $?; }
    };
    alarm $limit;
    while (!defined $status) {
      my $done = waitpid($pid, 0);
      if ($done == $pid) { $status = $?; }
      elsif ($done < 0 && !$!{EINTR} && !defined $status) {
        die "review_bounded: wait failed: $!\n";
      }
    }
    alarm 0;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$limit" "$@"
}

read_review_policy() {
  local root=$1 line key value seen_version=false seen_workflow=false \
    seen_identity_mode=false seen_accepted_risk=false login role seen_login
  REVIEW_OWNER=""
  REVIEW_WORKFLOW="" REVIEW_IDENTITY_MODE="" REVIEW_ACCEPTED_RISK=""
  REVIEW_REVIEWERS=" " REVIEW_EXECUTORS=" " REVIEW_APPROVERS=" "
  [ -f "$root/.agentic-flow-review-policy" ] || {
    echo 'review policy missing' >&2; return 1;
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) echo 'review policy malformed line' >&2; return 1 ;; esac
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      version)
        [ "$seen_version" = false ] || { echo 'review policy duplicate version' >&2; return 1; }
        seen_version=true
        [ "$value" = 1 ] || { echo 'review policy invalid version' >&2; return 1; } ;;
      workflow)
        [ "$seen_workflow" = false ] || { echo 'review policy duplicate workflow' >&2; return 1; }
        seen_workflow=true
        [[ "$value" =~ ^\.github/workflows/[A-Za-z0-9_-]+\.ya?ml$ ]] || {
          echo 'review policy invalid workflow path' >&2; return 1;
        }
        # shellcheck disable=SC2034 # Set for sourcing callers.
        REVIEW_WORKFLOW=$value ;;
      identity-mode)
        [ "$seen_identity_mode" = false ] || { echo 'review policy duplicate identity-mode' >&2; return 1; }
        seen_identity_mode=true
        case "$value" in distinct-account|single-operator) ;; *) return 1 ;; esac
        REVIEW_IDENTITY_MODE=$value ;;
      accepted-risk)
        [ "$seen_accepted_risk" = false ] || { echo 'review policy duplicate accepted-risk' >&2; return 1; }
        seen_accepted_risk=true
        [[ "$value" =~ ^docs/accepted_risks\.md#[A-Za-z0-9_-]+$ ]] || return 1
        REVIEW_ACCEPTED_RISK=$value ;;
      owner)
        [ -z "$REVIEW_OWNER" ] && review_valid_login "$value" && [[ "$value" != *"[bot]" ]] || { echo "review policy invalid or duplicate owner" >&2; return 1; }
        REVIEW_OWNER=$value ;;
      reviewer|executor|approver)
        review_valid_login "$value" || {
          echo "review policy invalid $key login: $value; set a GitHub login in $root/.agentic-flow-review-policy" >&2
          return 1
        }
        case "$key" in
          reviewer) role=REVIEW_REVIEWERS ;;
          executor) role=REVIEW_EXECUTORS ;;
          approver) role=REVIEW_APPROVERS ;;
        esac
        seen_login=${!role}
        case "$seen_login" in *" $value "*) echo "review policy duplicate $key" >&2; return 1 ;; esac
        printf -v "$role" '%s%s ' "$seen_login" "$value" ;;
      *) echo "review policy unknown key: $key" >&2; return 1 ;;
    esac
  done < "$root/.agentic-flow-review-policy"
  [ "$seen_version" = true ] && [ "$seen_workflow" = true ] &&
    [ "$seen_identity_mode" = true ] || { echo 'review policy missing required field' >&2; return 1; }
  for key in reviewer executor approver; do
    case "$key" in reviewer) value=$REVIEW_REVIEWERS ;; executor) value=$REVIEW_EXECUTORS ;; approver) value=$REVIEW_APPROVERS ;; esac
    [ "$value" != ' ' ] || { echo "review policy missing $key login" >&2; return 1; }
  done
  if [ "$REVIEW_IDENTITY_MODE" = distinct-account ]; then
    [ "$seen_accepted_risk" = false ] && [ "$REVIEW_REVIEWERS" != ' ' ] &&
      [ "$REVIEW_EXECUTORS" != ' ' ] && [ "$REVIEW_APPROVERS" != ' ' ] || return 1
    for login in $REVIEW_REVIEWERS; do
      case "$REVIEW_EXECUTORS$REVIEW_APPROVERS" in *" $login "*) return 1 ;; esac
    done
  else
    [ "$seen_accepted_risk" = true ] || return 1
    local anchor=${REVIEW_ACCEPTED_RISK#*#}
    grep -Fq "id=\"$anchor\"" "$root/docs/accepted_risks.md" || return 1
  fi
}
