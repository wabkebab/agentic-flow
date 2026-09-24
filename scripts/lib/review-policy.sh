#!/usr/bin/env bash
# Source this file, then call read_review_policy <project-root>.
# Identity configuration is reserved for F-3; it is accepted but not trusted here.
read_review_policy() {
  local root=$1 line key value seen_version=false seen_workflow=false \
    seen_identity_mode=false seen_accepted_risk=false
  REVIEW_WORKFLOW=""
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
        seen_identity_mode=true ;;
      accepted-risk)
        [ "$seen_accepted_risk" = false ] || { echo 'review policy duplicate accepted-risk' >&2; return 1; }
        seen_accepted_risk=true ;;
      reviewer|executor|approver) : ;;
      *) echo "review policy unknown key: $key" >&2; return 1 ;;
    esac
  done < "$root/.agentic-flow-review-policy"
  [ "$seen_version" = true ] && [ "$seen_workflow" = true ] || {
    echo 'review policy missing version or workflow' >&2; return 1;
  }
}
