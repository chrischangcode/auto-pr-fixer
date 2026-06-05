#!/usr/bin/env bash
# fixer.sh — analyze CI failures with GitHub Models API and commit fixes

COMMIT_MARKER="[auto-pr-fixer]"
STATE_MARKER="<!-- auto-pr-fixer-state:"
MODELS_API="https://models.github.ai/inference/chat/completions"
MODEL="openai/gpt-4.1"

fix_pr() {
  local owner="$1" repo="$2" pr_num="$3" head_sha="$4" logs="$5"

  # Truncate logs for the prompt
  local trimmed_logs="$logs"
  if [[ "${#trimmed_logs}" -gt 4000 ]]; then
    trimmed_logs="${trimmed_logs:0:4000}"$'\n... [truncated]'
  fi

  # Get PR title and body for context
  local pr_title pr_body_text
  pr_title=$(gh api "repos/$owner/$repo/pulls/$pr_num" --jq '.title' 2>/dev/null || true)
  pr_body_text=$(gh api "repos/$owner/$repo/pulls/$pr_num" --jq '.body // ""' 2>/dev/null || true)

  # Get the list of changed files in the PR
  local pr_files
  pr_files=$(gh api "repos/$owner/$repo/pulls/$pr_num/files" --jq '.[].filename' 2>/dev/null)

  # Fetch the content of each changed file
  local file_contents=""
  for f in $pr_files; do
    # Skip binary / lock files
    case "$f" in
      *.lock|*.sum|*.png|*.jpg|*.gif|*.ico) continue ;;
    esac
    local content
    content=$(gh api "repos/$owner/$repo/contents/$f?ref=$head_sha" --jq '.content' 2>/dev/null || true)
    if [[ -n "$content" && "$content" != "null" ]]; then
      local decoded
      decoded=$(echo "$content" | base64 -d 2>/dev/null || true)
      file_contents+="--- FILE: $f ---"$'\n'"$decoded"$'\n\n'
    fi
  done

  # Build the prompt
  local system_prompt
  system_prompt='You are a CI build fixer. Given error logs and source files from a pull request, output ONLY a JSON array of file edits. Each element must have "path" (file path) and "content" (the complete new file content as a single string). Rules: 1) The "content" field must contain the ENTIRE file, not a partial diff. 2) Preserve the intent of the PR — if the PR is bumping a dependency version, do NOT revert that bump. Instead, fix the other dependencies to be compatible. 3) Output valid JSON only — no markdown fences, no explanation, no comments.'

  local user_prompt
  user_prompt=$(cat <<EOF
PR #$pr_num: "$pr_title"
$pr_body_text

The CI build failed with these errors:

$trimmed_logs

Here are the current source files in the PR:

$file_contents

Fix the build failure while preserving the intent of the PR changes. If a dependency was bumped, keep that bump and update other dependencies to be compatible. Return a JSON array like:
[{"path": "requirements.txt", "content": "flask==3.0.0\nwerkzeug==3.0.0\n..."}]
EOF
)

  echo "PR #$pr_num: calling GitHub Models API for fix..."

  # Call GitHub Models API
  local request_body
  request_body=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$system_prompt" \
    --arg user "$user_prompt" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      temperature: 0.2
    }')

  local response
  response=$(curl -s -X POST "$MODELS_API" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$request_body" 2>/dev/null)

  local reply
  reply=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  if [[ -z "$reply" ]]; then
    local err_msg
    err_msg=$(echo "$response" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null)
    echo "PR #$pr_num: Models API failed: $err_msg"
    # Fall back to just posting an error analysis comment
    post_error_comment "$owner" "$repo" "$pr_num" "$head_sha" "$trimmed_logs"
    return
  fi

  # Strip markdown code fences if the model wrapped the JSON
  reply=$(echo "$reply" | sed -n '/^\[/,/^\]/p')
  if [[ -z "$reply" ]]; then
    # Try stripping ```json ... ``` wrapper
    reply=$(echo "$response" | jq -r '.choices[0].message.content // empty' | sed 's/^```json//;s/^```//;s/```$//' | jq '.' 2>/dev/null || true)
  fi

  # Validate JSON
  local file_count
  file_count=$(echo "$reply" | jq 'length' 2>/dev/null || echo "0")

  if [[ "$file_count" -eq 0 ]]; then
    echo "PR #$pr_num: model returned no file changes."
    post_error_comment "$owner" "$repo" "$pr_num" "$head_sha" "$trimmed_logs"
    return
  fi

  echo "PR #$pr_num: model suggested $file_count file change(s). Committing..."

  # Commit each file change via GitHub API
  local pr_branch
  pr_branch=$(gh api "repos/$owner/$repo/pulls/$pr_num" --jq '.head.ref')
  local committed=0
  local changed_files_list=""

  for i in $(seq 0 $((file_count - 1))); do
    local file_path file_content
    file_path=$(echo "$reply" | jq -r ".[$i].path")
    file_content=$(echo "$reply" | jq -r ".[$i].content")

    # Check protected paths
    local blocked=false
    for pattern in $CFG_PROTECTED_PATHS; do
      # shellcheck disable=SC2254
      case "$file_path" in
        $pattern) blocked=true; break ;;
      esac
    done

    if [[ "$blocked" == "true" ]]; then
      echo "  Skipping protected path: $file_path"
      continue
    fi

    # Get current file SHA (needed for update)
    local file_sha
    file_sha=$(gh api "repos/$owner/$repo/contents/$file_path?ref=$pr_branch" --jq '.sha' 2>/dev/null || true)

    # Base64 encode the new content
    local encoded_content
    encoded_content=$(echo -n "$file_content" | base64 -w 0)

    # Commit via Contents API
    local commit_msg="fix: auto-fix CI failure in $file_path $COMMIT_MARKER"

    if [[ -n "$file_sha" && "$file_sha" != "null" ]]; then
      # Update existing file
      gh api "repos/$owner/$repo/contents/$file_path" \
        -X PUT \
        -f message="$commit_msg" \
        -f content="$encoded_content" \
        -f sha="$file_sha" \
        -f branch="$pr_branch" --silent 2>/dev/null && committed=$((committed + 1)) || {
        echo "  Failed to update $file_path"
      }
    else
      # Create new file
      gh api "repos/$owner/$repo/contents/$file_path" \
        -X PUT \
        -f message="$commit_msg" \
        -f content="$encoded_content" \
        -f branch="$pr_branch" --silent 2>/dev/null && committed=$((committed + 1)) || {
        echo "  Failed to create $file_path"
      }
    fi

    echo "  Committed fix to $file_path"
    changed_files_list+="- \`$file_path\`"$'\n'
  done

  # Post a summary comment (includes hidden state marker)
  if [[ "$committed" -gt 0 ]]; then
    local summary_body
    summary_body=$(cat <<EOF
## 🔧 Auto PR Fixer — CI failure fixed $COMMIT_MARKER

Detected a build failure and committed a fix ($committed file(s) updated):

$changed_files_list
<details>
<summary>Build error logs</summary>

\`\`\`
$trimmed_logs
\`\`\`
</details>

> A new CI run should start automatically. If the fix isn't right, revert the commit and fix manually.

_Generated by [auto-pr-fixer](https://github.com/chrischangcode/auto-pr-fixer) for SHA \`$head_sha\`_
$STATE_MARKER$head_sha:1 -->
EOF
)
    gh api "repos/$owner/$repo/issues/$pr_num/comments" \
      -f body="$summary_body" --silent
  fi

  echo "PR #$pr_num: committed $committed file(s)."
}

post_error_comment() {
  local owner="$1" repo="$2" pr_num="$3" head_sha="$4" logs="$5"

  local body
  body=$(cat <<EOF
## ⚠️ Auto PR Fixer — could not auto-fix $COMMIT_MARKER

Detected a CI build failure but couldn't generate a fix automatically. Please review the errors below and fix manually.

<details>
<summary>Build error logs</summary>

\`\`\`
$logs
\`\`\`
</details>

---
_Generated by [auto-pr-fixer](https://github.com/chrischangcode/auto-pr-fixer) for SHA \`$head_sha\`_
$STATE_MARKER$head_sha:1 -->
EOF
)

  gh api "repos/$owner/$repo/issues/$pr_num/comments" \
    -f body="$body" --silent
}

# --- State tracking via PR comments ---

get_attempt_count() {
  local owner="$1" repo="$2" pr_num="$3" head_sha="$4"

  local comments
  comments=$(gh api "repos/$owner/$repo/issues/$pr_num/comments" --jq \
    "[.[].body | select(contains(\"$STATE_MARKER$head_sha:\"))] | length" 2>/dev/null || echo "0")

  echo "$comments"
}

record_attempt() {
  # State is now embedded in the summary/error comment — this is a no-op.
  # Kept for interface compatibility with main.sh.
  local owner="$1" repo="$2" pr_num="$3" head_sha="$4" attempt_num="$5"
  echo "PR #$pr_num: recorded attempt $attempt_num for SHA $head_sha (embedded in comment)"
}
