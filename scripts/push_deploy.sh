#!/usr/bin/env bash
set -euo pipefail

# Push current branch and stream GitHub Actions logs for the run
# that corresponds to the exact commit SHA we push. This avoids
# races when multiple runs start nearly simultaneously.
#
# Usage:
#   scripts/push_deploy.sh [optional commit message]
#
# Env overrides:
#   WORKFLOW_FILE   Path or name for workflow filter (default: .github/workflows/pages.yml)
#   REMOTE          Git remote to push to (default: origin)
#   BRANCH          Branch to push (default: current branch)
#
# Requirements:
#   - gh (GitHub CLI) authenticated for this repo
#   - git

WORKFLOW_FILE="${WORKFLOW_FILE:-.github/workflows/pages.yml}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-}"

# Ensure we are in a git repo
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_DIR}" ]]; then
  echo "Error: not inside a git repository" >&2
  exit 1
fi
cd "$REPO_DIR"

if [[ -z "${BRANCH}" ]]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

# Determine owner/repo slug
if REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
  :
else
  ORIGIN_URL=$(git remote get-url "$REMOTE")
  if [[ "$ORIGIN_URL" =~ github.com[:/]{1}([^/]+)/([^/.]+)(\.git)?$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "Error: unable to determine GitHub repo slug (owner/name)" >&2
    exit 1
  fi
fi

echo "Repo: $REPO_SLUG"
echo "Branch: $BRANCH"
echo "Workflow filter: $WORKFLOW_FILE"

# Optionally commit changes
COMMIT_MSG="${1:-}"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  git add -A
  if [[ -z "$COMMIT_MSG" ]]; then
    COMMIT_MSG="chore: deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  # If nothing to commit (race), ignore error
  git commit -m "$COMMIT_MSG" || true
fi

# Record SHA before push (in case nothing changed)
SHA_BEFORE=$(git rev-parse HEAD)

echo "Pushing $SHA_BEFORE to $REMOTE/$BRANCH ..."
# Push current HEAD to the tracked remote branch
# Use HEAD to respect current branch name
git push -u "$REMOTE" HEAD

SHA=$(git rev-parse HEAD)
echo "HEAD after push: $SHA"

# Find the workflow run for exactly this commit SHA.
echo "Waiting for workflow run of '$WORKFLOW_FILE' on commit $SHA ..."
RUN_ID=""
ATTEMPTS=0
MAX_ATTEMPTS=150  # ~5 minutes
SLEEP=2

while [[ -z "$RUN_ID" && $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
  # Filter by workflow file/name and headSha so we pick the correct run
  RUN_ID=$(gh run list -R "$REPO_SLUG" \
            --workflow "$WORKFLOW_FILE" \
            --json databaseId,headSha,createdAt \
            -q ".[] | select(.headSha==\"$SHA\") | .databaseId" \
            | head -n 1 || true)
  if [[ -n "$RUN_ID" ]]; then
    break
  fi
  sleep "$SLEEP"
  ATTEMPTS=$((ATTEMPTS+1))
  echo -n "." >&2
done

echo
if [[ -z "$RUN_ID" ]]; then
  echo "Error: timed out waiting for workflow run for commit $SHA" >&2
  gh run list -R "$REPO_SLUG" --workflow "$WORKFLOW_FILE" -L 10 || true
  exit 1
fi

echo "Found run id: $RUN_ID"

echo "Streaming logs... (Ctrl+C to stop)"
TMP_LOG=$(mktemp)
trap 'rm -f "$TMP_LOG"' EXIT
LAST_LINES=0

while :; do
  STATUS=$(gh run view -R "$REPO_SLUG" "$RUN_ID" --json status,conclusion -q '.status' 2>/dev/null || echo "unknown")
  # Collect cumulative logs; may be empty early in the run
  gh run view -R "$REPO_SLUG" "$RUN_ID" --log > "$TMP_LOG" 2>/dev/null || true

  TOTAL_LINES=$(wc -l < "$TMP_LOG" | tr -d ' ')
  if [[ -n "$TOTAL_LINES" && "$TOTAL_LINES" -gt "$LAST_LINES" ]]; then
    sed -n "$((LAST_LINES+1)),${TOTAL_LINES}p" "$TMP_LOG"
    LAST_LINES=$TOTAL_LINES
  fi

  if [[ "$STATUS" == "completed" ]]; then
    CONCLUSION=$(gh run view -R "$REPO_SLUG" "$RUN_ID" --json conclusion -q '.conclusion' 2>/dev/null || echo "unknown")
    echo "Run completed with conclusion: $CONCLUSION"
    if [[ "$CONCLUSION" == "success" ]]; then
      exit 0
    else
      # Print full logs once more on failure for completeness
      echo "----- Full Logs (final) -----"
      gh run view -R "$REPO_SLUG" "$RUN_ID" --log || true
      exit 1
    fi
  fi
  sleep 5
done
