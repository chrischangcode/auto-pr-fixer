#!/usr/bin/env bash
# auto-pr-fixer: main entry point
# Triggered by workflow_run events. Finds failing CI, fetches logs,
# and invokes Copilot CLI to suggest or commit a fix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${CONFIG_PATH:-.github/auto-pr-fixer.yml}"
DRY_RUN="${DRY_RUN:-false}"

# shellcheck source=scripts/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=scripts/logs.sh
source "$SCRIPT_DIR/logs.sh"
# shellcheck source=scripts/fixer.sh
source "$SCRIPT_DIR/fixer.sh"

# --- Read the workflow_run event payload ---
EVENT=$(cat "$GITHUB_EVENT_PATH")

CONCLUSION=$(echo "$EVENT" | jq -r '.workflow_run.conclusion // empty')
if [[ "$CONCLUSION" != "failure" ]]; then
  echo "Workflow run concluded with '$CONCLUSION', skipping."
  exit 0
fi

RUN_ID=$(echo "$EVENT" | jq -r '.workflow_run.id')
RUN_NAME=$(echo "$EVENT" | jq -r '.workflow_run.name')
HEAD_SHA=$(echo "$EVENT" | jq -r '.workflow_run.head_sha')
HEAD_BRANCH=$(echo "$EVENT" | jq -r '.workflow_run.head_branch')
REPO_FULL=$(echo "$EVENT" | jq -r '.repository.full_name')
OWNER="${REPO_FULL%%/*}"
REPO="${REPO_FULL##*/}"

echo "Processing failed run: $RUN_NAME (#$RUN_ID) on $HEAD_BRANCH @ $HEAD_SHA"

# --- Load config from default branch ---
load_config "$OWNER" "$REPO" "$CONFIG_PATH"

EFFECTIVE_MODE="$CFG_MODE"
if [[ "$DRY_RUN" == "true" ]]; then
  EFFECTIVE_MODE="comment"
fi

echo "Mode: $EFFECTIVE_MODE | Workflow: $RUN_NAME"

# --- Check if the workflow matches the config ---
if ! workflow_matches "$RUN_NAME"; then
  echo "Workflow '$RUN_NAME' not in configured list, skipping."
  exit 0
fi

# --- Find open PRs for this branch ---
PRS=$(gh api "repos/$OWNER/$REPO/pulls?state=open&head=$OWNER:$HEAD_BRANCH" --jq '.[].number' 2>/dev/null || true)

if [[ -z "$PRS" ]]; then
  echo "No open PRs found for branch '$HEAD_BRANCH', skipping."
  exit 0
fi

# --- Process each matching PR ---
for PR_NUM in $PRS; do
  echo "--- Checking PR #$PR_NUM ---"

  PR_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM")
  PR_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')

  # Verify SHA matches (avoid acting on stale data)
  if [[ "$PR_SHA" != "$HEAD_SHA" ]]; then
    echo "PR #$PR_NUM: head SHA mismatch ($PR_SHA != $HEAD_SHA), skipping."
    continue
  fi

  # Check PR filters (labels, authors, forks, branches)
  if ! pr_matches "$PR_JSON" "$RUN_NAME"; then
    echo "PR #$PR_NUM: does not match config filters, skipping."
    continue
  fi

  # Check retry state
  ATTEMPTS=$(get_attempt_count "$OWNER" "$REPO" "$PR_NUM" "$HEAD_SHA")
  if [[ "$ATTEMPTS" -ge "$CFG_MAX_RETRIES" ]]; then
    echo "PR #$PR_NUM: max retries ($CFG_MAX_RETRIES) reached for SHA $HEAD_SHA, skipping."
    continue
  fi

  echo "PR #$PR_NUM: fetching failure logs..."

  # Fetch build logs
  LOGS=$(fetch_failed_logs "$OWNER" "$REPO" "$RUN_ID")
  if [[ -z "$LOGS" ]]; then
    echo "PR #$PR_NUM: could not fetch failure logs, skipping."
    continue
  fi

  echo "PR #$PR_NUM: invoking fix (mode=$EFFECTIVE_MODE)..."

  # Run the fixer
  fix_pr "$OWNER" "$REPO" "$PR_NUM" "$HEAD_SHA" "$LOGS" "$EFFECTIVE_MODE"

  # Record attempt
  record_attempt "$OWNER" "$REPO" "$PR_NUM" "$HEAD_SHA" "$((ATTEMPTS + 1))"
done

echo "Done."
