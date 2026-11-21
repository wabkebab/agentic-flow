#!/usr/bin/env bash
# Read the negated App filter from the workflow that ran paths-filter. Both the
# cache key and the contracts test use this list.
ci_bookkeeping_globs() { # <workflow.yml> [--check-docs]
  awk -v quote="'" -v check_docs="${2:-}" '
    /^  [^ ]/ { changes=($1=="changes:"); step=0; filters=0; area="" }
    !changes { next }
    /^      - / { step=0; filters=0; area="" }
    /^        id: filter$/ { step=1 }
    step && /^          predicate-quantifier: every$/ { every++ }
    step && /^          filters: \|$/ { filters=1; next }
    filters && /^            app:$/ { area="app:"; app_lists++; next }
    filters && /^            docs:$/ { area="docs:"; next }
    filters && area=="app:" && /^              - / {
      rule=substr($0, 17)
      if (rule !~ ("^" quote "![A-Za-z0-9_./*-]+" quote "$")) invalid=1
      else print substr(rule, 3, length(rule)-3)
      app++
      next
    }
    filters && area=="app:" && !/^[[:space:]]*(#|$)/ { invalid=1 }
    filters && area=="docs:" && /^              - / {
      if (substr($0, 17) != quote "{docs/**,*.md,.github/workflows/ci.yml}" quote) invalid_docs=1
      docs++
    }
    END { exit (invalid || every!=1 || app_lists!=1 || app<1 ||
      (check_docs && (invalid_docs || docs!=1))) }
  ' "$1"
}
