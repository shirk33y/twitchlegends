#!/bin/sh
# POSIX-compatible script to push changes and trigger a GitHub Actions workflow.
# Behavior:
# - If there are uncommitted changes, commit them and push.
# - Else if there are commits ahead of remote, push them.
# - Else create an empty commit to trigger the workflow and push.
# - Then watch the workflow run for the current branch (if gh CLI is available).
#
# Usage:
#   scripts/run_github_action.sh [optional commit message]
#
# Env overrides:
#   WORKFLOW_FILE  Path or name for workflow filter (default: .github/workflows/pages.yml)
#   REMOTE         Git remote to push to (default: origin)
#   BRANCH         Branch to push (default: current branch)
#
# Requirements:
#   - git
#   - gh (optional: for streaming/watching the workflow run)

set -eu

# --- Configuration (with sensible defaults) ---
WORKFLOW_FILE=${WORKFLOW_FILE:-.github/workflows/pages.yml}
REMOTE=${REMOTE:-origin}
BRANCH=${BRANCH:-}
COMMIT_MSG=${1:-"ci: trigger GitHub Actions"}

# --- Helpers ---
err() { printf '%s\n' "$*" >&2; }

die() { err "Error: $*"; exit 1; }

basename_posix() {
  # Minimal POSIX-safe basename
  p=$1
  case "$p" in
    */) p=${p%/} ;;
  esac
  p=${p##*/}
  printf '%s' "$p"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

push_branch() {
  # Push to REMOTE/BRANCH, setting upstream if it doesn't exist
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    git push "$REMOTE" "$BRANCH"
  else
    git push -u "$REMOTE" "$BRANCH"
  fi
}

# --- Ensure repo context ---
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || printf '')
[ -n "$REPO_DIR" ] || die "not inside a git repository"
cd "$REPO_DIR" || die "cannot cd to repo root"

# Determine branch
if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

# Reduce workflow filter to filename (gh expects a name, not a path)
WF_FILTER=$(basename_posix "$WORKFLOW_FILE")

# Try to compute repo slug for messaging
REPO_SLUG=""
if have_cmd gh; then
  REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || printf '')
fi
if [ -z "$REPO_SLUG" ]; then
  ORIGIN_URL=$(git remote get-url "$REMOTE" 2>/dev/null || printf '')
  if [ -n "$ORIGIN_URL" ]; then
    # Handle git@github.com:owner/repo(.git)? and https://github.com/owner/repo(.git)?
    REPO_SLUG=$(printf '%s' "$ORIGIN_URL" | sed -n 's#.*github.com[:/]\([^/][^/]*\)/\([^/.][^/]*\)\(.git\)*$#\1/\2#p')
  fi
fi

printf 'Repository: %s\n' "${REPO_SLUG:-unknown}"
printf 'Branch:     %s\n' "$BRANCH"
printf 'Workflow:   %s\n' "$WF_FILTER"

# Ensure we have the latest refs
# If fetch fails (e.g., shallow or no upstream), continue anyway.
(git fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1 || true)

pushed=0

# 1) Stage and commit uncommitted changes, if any
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
  git add -A
  git commit -m "$COMMIT_MSG"
  push_branch
  pushed=1
fi

# 2) If there are commits ahead of the upstream, push them
if [ "$pushed" -eq 0 ]; then
  AHEAD=0
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    AHEAD=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || printf '0')
  else
    # No upstream configured yet – treat as ahead to force the initial push
    AHEAD=1
  fi
  # If ahead of upstream, push
  case "$AHEAD" in
    ''|*[!0-9]*) AHEAD=0 ;;
  esac
  if [ "$AHEAD" -gt 0 ]; then
    push_branch
    pushed=1
  fi
fi

# 3) If nothing was pushed, create an empty commit and push to trigger the workflow
if [ "$pushed" -eq 0 ]; then
  git commit --allow-empty -m "$COMMIT_MSG"
  push_branch
  pushed=1
fi

HEAD_SHA=$(git rev-parse HEAD)
printf 'Pushed commit: %s\n' "$HEAD_SHA"

# 4) Stream workflow logs for the run matching this commit (best-effort)
if have_cmd gh; then
  printf 'Waiting for workflow run of "%s" on commit %s ...\n' "$WF_FILTER" "$HEAD_SHA"
  RUN_ID=""
  ATTEMPTS=0
  MAX_ATTEMPTS=150  # ~5 minutes
  SLEEP=2

  while [ -z "$RUN_ID" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    # Filter by workflow and exact commit SHA, pick newest by createdAt
    if [ -n "$REPO_SLUG" ]; then
      RUN_ID=$(gh run list -R "$REPO_SLUG" \
                --workflow "$WF_FILTER" \
                --json databaseId,headSha,createdAt \
                -q ". | map(select(.headSha==\"$HEAD_SHA\")) | sort_by(.createdAt) | last | .databaseId" 2>/dev/null || printf '')
    else
      RUN_ID=$(gh run list \
                --workflow "$WF_FILTER" \
                --json databaseId,headSha,createdAt \
                -q ". | map(select(.headSha==\"$HEAD_SHA\")) | sort_by(.createdAt) | last | .databaseId" 2>/dev/null || printf '')
    fi
    if [ -n "$RUN_ID" ]; then
      break
    fi
    printf '.' >&2
    ATTEMPTS=$((ATTEMPTS+1))
    sleep "$SLEEP"
  done
  printf '\n'

  if [ -z "$RUN_ID" ]; then
    err "timed out waiting for workflow run for commit $HEAD_SHA"
    if [ -n "$REPO_SLUG" ]; then
      gh run list -R "$REPO_SLUG" --workflow "$WF_FILTER" -L 10 || true
    else
      gh run list --workflow "$WF_FILTER" -L 10 || true
    fi
    exit 1
  fi

  printf 'Found run id: %s\n' "$RUN_ID"
  printf 'Streaming logs... (Ctrl+C to stop)\n'
  TMP_LOG=$(mktemp 2>/dev/null || echo "/tmp/gh_run_$$.log")
  trap 'rm -f "$TMP_LOG"' EXIT HUP INT TERM
  LAST_LINES=0

  while :; do
    if [ -n "$REPO_SLUG" ]; then
      STATUS=$(gh run view -R "$REPO_SLUG" "$RUN_ID" --json status -q '.status' 2>/dev/null || printf 'unknown')
      gh run view -R "$REPO_SLUG" "$RUN_ID" --log > "$TMP_LOG" 2>/dev/null || true
    else
      STATUS=$(gh run view "$RUN_ID" --json status -q '.status' 2>/dev/null || printf 'unknown')
      gh run view "$RUN_ID" --log > "$TMP_LOG" 2>/dev/null || true
    fi

    TOTAL_LINES=$(wc -l < "$TMP_LOG" | tr -d ' ')
    case "$TOTAL_LINES" in
      ''|*[!0-9]*) TOTAL_LINES=0 ;;
    esac
    if [ "$TOTAL_LINES" -gt "$LAST_LINES" ]; then
      sed -n "$((LAST_LINES+1)),${TOTAL_LINES}p" "$TMP_LOG"
      LAST_LINES=$TOTAL_LINES
    fi

    if [ "$STATUS" = "completed" ]; then
      if [ -n "$REPO_SLUG" ]; then
        CONCLUSION=$(gh run view -R "$REPO_SLUG" "$RUN_ID" --json conclusion -q '.conclusion' 2>/dev/null | tr -d '\n' || printf 'unknown')
      else
        CONCLUSION=$(gh run view "$RUN_ID" --json conclusion -q '.conclusion' 2>/dev/null | tr -d '\n' || printf 'unknown')
      fi
      printf 'Run completed with conclusion: %s\n' "$CONCLUSION"
      if [ "$CONCLUSION" = "success" ]; then
        exit 0
      else
        echo "----- Full Logs (final) -----"
        if [ -n "$REPO_SLUG" ]; then
          gh run view -R "$REPO_SLUG" "$RUN_ID" --log || true
        else
          gh run view "$RUN_ID" --log || true
        fi
        exit 1
      fi
    fi
    sleep 5
  done
else
  err 'gh (GitHub CLI) not found; skipping workflow watch.'
fi
