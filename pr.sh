#!/bin/bash

# Create a (draft) pull request using GitHub CLI.
# It assigns the PR to the current user, fills in the title from the first commit,
# and uses the PR template file for the description.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NO_COLOR='\033[0m'

# Helper functions
print_message() { echo -e "\n${1}${2}${NO_COLOR}\n"; }
error_message() { print_message "${RED}" "Error: $1"; }
warning_message() { print_message "${YELLOW}" "Warning: $1"; }
success_message() { print_message "${GREEN}" "$1"; }

PR_TEMPLATE=$(curl -s https://raw.githubusercontent.com/gumroad/.github/main/pull_request_template.md)

gh_pr_create() {
  gh pr create -a @me --fill-first --body "$PR_TEMPLATE" "$@"
}

create_pr() {
  git push || {
    error_message "Failed to push changes."
    exit 1
  }

  if gh_pr_create "--draft"; then
    success_message "Draft pull request created successfully!"
  elif gh_pr_create; then
    success_message "Pull request created!"
  else
    error_message "Failed to create PR."
    exit 1
  fi
}

build_pr_description() {
  local pr_title=$(gh pr view --json title -q .title)
  local current_description=$(gh pr view --json body -q .body)

  # Get the diff for files in select folders and root, excluding all other folders
  local pr_diff=$(gh pr diff | awk '/^diff --git/ {in_folder=($0 ~ " b/(app|config|db|scripts)/| b/[^/]+$")} in_folder {print}')

  local system_content="You are an expert software engineer. that writes high-quality, concise pull request descriptions based on code diffs,
titles, and existing descriptions."

  local user_content="Carefully review the provided context: title, PR template, and diff.
  Update the placeholder content from the What section, and the placeholder content from the Why section.
Under the Checklist section, update the checklist items that are relevant to the changes (don't update self-review,
that will be done manually).
The content generated MUST use the imperative tense.

Title:
<title>
$pr_title
</title>

PR Template:
<pr_template>
$PR_TEMPLATE
</pr_template>

Current Description:
<current_description>
$current_description
</current_description>

Diff (excluding test files):
<diff>
$pr_diff
</diff>"

  local payload=$(jq -n \
    --arg system_content "$system_content" \
    --arg user_content "$user_content" \
    '{
      model: "gpt-3.5-turbo",
      messages: [
        { role: "system", content: $system_content },
        { role: "user", content: $user_content }
      ]
    }')

  local response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PERSONAL_OPENAI_API_KEY:-}" \
    -d "$payload")

  local content=$(echo "$response" | jq -r '.choices[0].message.content')

  if [ -z "$content" ] || [ "$content" == "null" ]; then
    echo "$response" | jq '.' >&2
    return 1
  fi

  printf '%s' "$content"
}

# Use OpenAI API to generate an updated description
function update_pr_description() {
  if [ -z "${PERSONAL_OPENAI_API_KEY:-}" ]; then
    warning_message "Set PERSONAL_OPENAI_API_KEY in .env.development.local for AI-generated PR descriptions."
    return 0
  fi

  local updated_description
  if ! updated_description=$(build_pr_description 2>&1); then
    error_message "Failed to build PR description."
    error_message "$updated_description"
    return 0
  fi

  echo "Updating pull request description..."
  echo "$updated_description" | gh pr edit --body-file - || {
    error_message "Failed to update PR description."
    return 0
  }

  success_message "Pull request description updated successfully!"
}

function open_pr_in_browser() {
  gh pr view --web
}

# Check if GitHub CLI is installed
if ! command -v gh &>/dev/null; then
  error_message "GitHub CLI (gh) is not installed. Please visit https://cli.github.com/"
  exit 1
fi

# Source the .env.development.local file if it exists
if [ -f .env.development.local ]; then
  source .env.development.local
fi

create_pr
update_pr_description
open_pr_in_browser
