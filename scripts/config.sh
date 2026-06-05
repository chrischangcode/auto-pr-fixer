#!/usr/bin/env bash
# config.sh — load and parse .github/auto-pr-fixer.yml from the default branch
# Uses yq-style jq parsing on YAML converted to JSON via gh api (base64 decode).

# Config variables (set by load_config)
CFG_MODE="comment"
CFG_MAX_RETRIES=2
CFG_REQUIRE_LABEL="auto-fix"
CFG_WORKFLOWS="CI"
CFG_BRANCH_INCLUDE="**"
CFG_BRANCH_EXCLUDE="main"
CFG_AUTHOR_EXCLUDE="dependabot[bot] renovate[bot]"
CFG_FORKS_ENABLED="false"
CFG_LOG_MAX_LENGTH=8000
CFG_LOG_REDACT="true"
CFG_PROTECTED_PATHS=".github/workflows/** .github/auto-pr-fixer.yml **/*.lock **/*.sum"

load_config() {
  local owner="$1" repo="$2" config_path="$3"

  # Get default branch
  local default_branch
  default_branch=$(gh api "repos/$owner/$repo" --jq '.default_branch')

  # Try to fetch the config file
  local raw_content
  raw_content=$(gh api "repos/$owner/$repo/contents/$config_path?ref=$default_branch" --jq '.content' 2>/dev/null || true)

  if [[ -z "$raw_content" || "$raw_content" == "null" ]]; then
    echo "No config file found at $config_path, using defaults."
    return
  fi

  # Decode base64 content — the API returns it with newlines, so strip them
  local config_json
  config_json=$(echo "$raw_content" | base64 -d | python3 -c "
import sys, json
try:
    import yaml
    data = yaml.safe_load(sys.stdin)
    json.dump(data if data else {}, sys.stdout)
except ImportError:
    # Fallback: no PyYAML, try a simple key-value parse
    import re
    data = {}
    for line in sys.stdin:
        line = line.strip()
        if line and not line.startswith('#'):
            m = re.match(r'^(\w+):\s*(.+)$', line)
            if m:
                data[m.group(1)] = m.group(2)
    json.dump(data, sys.stdout)
" 2>/dev/null || echo '{}')

  # Parse values with jq, falling back to defaults
  CFG_MODE=$(echo "$config_json" | jq -r '.mode // "comment"')
  CFG_MAX_RETRIES=$(echo "$config_json" | jq -r '.maxRetries // 2')
  CFG_REQUIRE_LABEL=$(echo "$config_json" | jq -r '.requireLabel // "auto-fix"')
  CFG_WORKFLOWS=$(echo "$config_json" | jq -r '(.workflows // ["CI"]) | join(" ")')
  CFG_BRANCH_INCLUDE=$(echo "$config_json" | jq -r '(.branches.include // ["**"]) | join(" ")')
  CFG_BRANCH_EXCLUDE=$(echo "$config_json" | jq -r '(.branches.exclude // ["main"]) | join(" ")')
  CFG_AUTHOR_EXCLUDE=$(echo "$config_json" | jq -r '(.authors.exclude // ["dependabot[bot]", "renovate[bot]"]) | join(" ")')
  CFG_FORKS_ENABLED=$(echo "$config_json" | jq -r '.forks.enabled // false')
  CFG_LOG_MAX_LENGTH=$(echo "$config_json" | jq -r '.logs.maxLength // 8000')
  CFG_LOG_REDACT=$(echo "$config_json" | jq -r '.logs.redactSecrets // true')
  CFG_PROTECTED_PATHS=$(echo "$config_json" | jq -r '(.protectedPaths // [".github/workflows/**", ".github/auto-pr-fixer.yml", "**/*.lock", "**/*.sum"]) | join(" ")')

  echo "Config loaded: mode=$CFG_MODE retries=$CFG_MAX_RETRIES label=$CFG_REQUIRE_LABEL"
}

workflow_matches() {
  local workflow_name="$1"
  for w in $CFG_WORKFLOWS; do
    if [[ "$w" == "$workflow_name" ]]; then
      return 0
    fi
  done
  return 1
}

pr_matches() {
  local pr_json="$1" workflow_name="$2"

  # Check fork policy
  local is_fork
  is_fork=$(echo "$pr_json" | jq -r '.head.repo.fork // false')
  if [[ "$is_fork" == "true" && "$CFG_FORKS_ENABLED" != "true" ]]; then
    echo "  Skipping: fork PR and forks not enabled."
    return 1
  fi

  # Check required label
  if [[ -n "$CFG_REQUIRE_LABEL" && "$CFG_REQUIRE_LABEL" != "null" ]]; then
    local has_label
    has_label=$(echo "$pr_json" | jq -r --arg label "$CFG_REQUIRE_LABEL" \
      '[.labels[].name] | any(. == $label)')
    if [[ "$has_label" != "true" ]]; then
      echo "  Skipping: missing required label '$CFG_REQUIRE_LABEL'."
      return 1
    fi
  fi

  # Check author exclusion
  local author
  author=$(echo "$pr_json" | jq -r '.user.login // ""')
  for excluded in $CFG_AUTHOR_EXCLUDE; do
    if [[ "$author" == "$excluded" ]]; then
      echo "  Skipping: author '$author' is excluded."
      return 1
    fi
  done

  # Check branch exclusion
  local branch
  branch=$(echo "$pr_json" | jq -r '.head.ref')
  for excluded in $CFG_BRANCH_EXCLUDE; do
    # Simple glob match using bash pattern matching
    # shellcheck disable=SC2254
    case "$branch" in
      $excluded) echo "  Skipping: branch '$branch' is excluded."; return 1 ;;
    esac
  done

  return 0
}
