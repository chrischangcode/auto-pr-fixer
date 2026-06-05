#!/usr/bin/env bash
# logs.sh — fetch and process failed CI build logs

fetch_failed_logs() {
  local owner="$1" repo="$2" run_id="$3"

  # Get failed jobs
  local jobs_json
  jobs_json=$(gh api "repos/$owner/$repo/actions/runs/$run_id/jobs?filter=latest" --jq \
    '[.jobs[] | select(.conclusion == "failure") | {id, name, steps: [.steps[] | select(.conclusion == "failure") | .name]}]')

  local job_count
  job_count=$(echo "$jobs_json" | jq 'length')

  if [[ "$job_count" -eq 0 ]]; then
    return
  fi

  local all_logs=""

  # Fetch logs for each failed job
  while IFS= read -r job_entry; do
    local job_id job_name failed_steps
    job_id=$(echo "$job_entry" | jq -r '.id')
    job_name=$(echo "$job_entry" | jq -r '.name')
    failed_steps=$(echo "$job_entry" | jq -r '.steps | join(", ")')

    # Download job logs
    local raw_log
    raw_log=$(gh api "repos/$owner/$repo/actions/jobs/$job_id/logs" 2>/dev/null || true)

    if [[ -z "$raw_log" ]]; then
      continue
    fi

    # Extract error window — lines around error/failure patterns
    local error_lines
    error_lines=$(extract_error_window "$raw_log")

    all_logs+="--- Job: $job_name | Failed steps: $failed_steps ---"$'\n'
    all_logs+="$error_lines"$'\n\n'

  done < <(echo "$jobs_json" | jq -c '.[]')

  # Redact secrets if configured
  if [[ "$CFG_LOG_REDACT" == "true" ]]; then
    all_logs=$(redact_secrets "$all_logs")
  fi

  # Truncate if needed
  if [[ "${#all_logs}" -gt "$CFG_LOG_MAX_LENGTH" ]]; then
    all_logs="${all_logs:0:$CFG_LOG_MAX_LENGTH}"$'\n... [truncated]'
  fi

  echo "$all_logs"
}

extract_error_window() {
  local log="$1"

  # Grep for error-like lines with 3 lines of context, or fall back to last 50 lines
  local result
  result=$(echo "$log" | grep -i -n -C 3 \
    -e 'error' -e 'FAIL' -e 'exception' -e 'TypeError' \
    -e 'SyntaxError' -e 'cannot find' -e 'not found' \
    -e 'exit code [1-9]' 2>/dev/null | head -200 || true)

  if [[ -z "$result" ]]; then
    # No error patterns found, return last 50 lines
    result=$(echo "$log" | tail -50)
  fi

  echo "$result"
}

redact_secrets() {
  local text="$1"
  # Redact common token/key patterns
  echo "$text" | sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9_]{36,}/[REDACTED]/g' \
    -e 's/Bearer [A-Za-z0-9._-]+/Bearer [REDACTED]/g' \
    -e 's/(token|key|secret|password|credential)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gi'
}
