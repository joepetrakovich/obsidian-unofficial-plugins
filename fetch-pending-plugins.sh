#!/bin/bash

# Fetch pending Obsidian community plugins from open PRs
# 
# This script:
# 1. Fetches open PR numbers for community-plugins.json via gh CLI
# 2. Batch fetches all merge refs at once (fast!)
# 3. Locally extracts plugin data from each PR
# 4. Outputs pending-plugins.json with all pending plugin submissions
#
# Requirements: git, jq, gh

set -e

REPO_URL="https://github.com/obsidianmd/obsidian-releases.git"
API_REPO="obsidianmd/obsidian-releases"
OUTPUT_DIR="_data"
WORK_DIR=""
CLEANUP=true
STATE_FILE=""
INCREMENTAL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -w|--workdir)
      WORK_DIR="$2"
      CLEANUP=false
      shift 2
      ;;
    -s|--state)
      STATE_FILE="$2"
      INCREMENTAL=true
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [-o|--output <directory>] [-w|--workdir <directory>] [-s|--state <file>]"
      echo ""
      echo "Fetches pending plugin submissions from open PRs in obsidian-releases."
      echo ""
      echo "Options:"
      echo "  -o, --output <dir>   Output directory (default: current directory)"
      echo "  -w, --workdir <dir>  Working directory for git clone (default: temp dir)"
      echo "                       If specified, the directory will not be cleaned up"
      echo "  -s, --state <file>   State file for incremental updates"
      echo "                       Tracks last processed PR to only fetch new ones"
      echo ""
      echo "Output files:"
      echo "  pending-plugins.json  - Array of pending plugin objects"
      echo "  current-plugins.json  - Current plugins from master branch"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check dependencies
for cmd in git jq gh; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is required but not installed."
    exit 1
  fi
done

# Create output directory and convert to absolute path
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

# Convert state file to absolute path if specified
if [ -n "$STATE_FILE" ]; then
  STATE_DIR=$(dirname "$STATE_FILE")
  mkdir -p "$STATE_DIR"
  STATE_DIR=$(cd "$STATE_DIR" && pwd)
  STATE_FILE="$STATE_DIR/$(basename "$STATE_FILE")"
fi

# Create or use work directory and convert to absolute path
if [ -z "$WORK_DIR" ]; then
  WORK_DIR=$(mktemp -d)
  echo "Using temporary directory: $WORK_DIR"
else
  mkdir -p "$WORK_DIR"
  WORK_DIR=$(cd "$WORK_DIR" && pwd)
  echo "Using working directory: $WORK_DIR"
fi

# Cleanup function
cleanup() {
  if [ "$CLEANUP" = true ] && [ -n "$WORK_DIR" ]; then
    echo "Cleaning up temporary directory..."
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# Step 1: Fetch open PR numbers that modify community-plugins.json
echo ""
echo "=== Step 1: Fetching open PR numbers ==="

PR_LIST_FILE="$WORK_DIR/open_prs.txt"

# Filter to only PRs that modify community-plugins.json
gh pr list -R "${API_REPO}" --limit 5000 \
  --search "community-plugins in:path" \
  --json number -q '.[].number' | sort -n > "$PR_LIST_FILE"

total_prs=$(wc -l < "$PR_LIST_FILE" | tr -d ' ')
echo "Found ${total_prs} open PRs modifying community-plugins.json"

# Check for incremental mode
last_pr=0
if [ "$INCREMENTAL" = true ] && [ -f "$STATE_FILE" ]; then
  last_pr=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
  echo "Incremental mode: last processed PR was #${last_pr}"
  
  # Filter to only new PRs
  awk -v last="$last_pr" '$1 > last' "$PR_LIST_FILE" > "$WORK_DIR/new_prs.txt"
  new_count=$(wc -l < "$WORK_DIR/new_prs.txt" | tr -d ' ')
  echo "Found ${new_count} new PRs since last run"
  
  if [ "$new_count" -eq 0 ]; then
    echo "No new PRs to process."
    exit 0
  fi
  
  mv "$WORK_DIR/new_prs.txt" "$PR_LIST_FILE"
  total_prs=$new_count
fi

# Step 2: Clone the repo and batch fetch all merge refs
echo ""
echo "=== Step 2: Setting up git repository ==="

REPO_DIR="$WORK_DIR/repo"

if [ -d "$REPO_DIR/.git" ]; then
  echo "Repository already exists, updating..."
  cd "$REPO_DIR"
  git fetch origin master --depth=1 2>/dev/null || true
else
  echo "Cloning repository..."
  git clone --depth=1 "$REPO_URL" "$REPO_DIR" 2>&1 | grep -v "^remote:" || true
  cd "$REPO_DIR"
fi

echo "Batch fetching all PR merge refs (this is fast!)..."
git fetch origin 'refs/pull/*/merge:refs/remotes/origin/pr/*/merge' 2>&1 | tail -1 || true

# Count how many refs we fetched
ref_count=$(git show-ref | grep -c "refs/remotes/origin/pr" || echo "0")
echo "Fetched ${ref_count} merge refs"

# Step 3: Get current plugins from master
echo ""
echo "=== Step 3: Extracting current plugins from master ==="

# Use jq to ensure proper Unicode encoding (git show can output escaped surrogates)
git show HEAD:community-plugins.json | jq '.' > "$OUTPUT_DIR/current-plugins.json"
CURRENT_COUNT=$(jq 'length' "$OUTPUT_DIR/current-plugins.json")
echo "Current plugins in master: $CURRENT_COUNT"

# Step 4: Process each PR locally (no network calls!)
echo ""
echo "=== Step 4: Processing PRs (local, fast!) ==="

PENDING_FILE="$WORK_DIR/pending.jsonl"
> "$PENDING_FILE"

processed=0
extracted=0
skipped=0
max_pr=0

while IFS= read -r pr_number; do
  processed=$((processed + 1))
  
  # Track highest PR number for state
  if [ "$pr_number" -gt "$max_pr" ]; then
    max_pr=$pr_number
  fi
  
  # Progress update every 100 PRs
  if [ $((processed % 100)) -eq 0 ]; then
    echo "  Progress: ${processed}/${total_prs} PRs (extracted: ${extracted}, skipped: ${skipped})"
  fi
  
  # Check if we have a merge ref for this PR
  ref="refs/remotes/origin/pr/${pr_number}/merge"
  if ! git show-ref --verify --quiet "$ref" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  
  # Extract the community-plugins.json from this PR (local operation!)
  pr_json=$(git show "${ref}:community-plugins.json" 2>/dev/null) || {
    skipped=$((skipped + 1))
    continue
  }
  
  # Validate JSON
  if ! echo "$pr_json" | jq empty 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  
  # Find new plugin IDs in this PR
  new_plugins=$(echo "$pr_json" | jq -c --slurpfile current "$OUTPUT_DIR/current-plugins.json" '
    ($current[0] | map(.id) | INDEX(.)) as $currentIds |
    [.[] | select(type == "object" and .id != null and ($currentIds[.id] == null))]
  ' 2>/dev/null) || {
    skipped=$((skipped + 1))
    continue
  }
  
  # Skip if no new plugins or empty result
  if [ -z "$new_plugins" ] || [ "$new_plugins" = "[]" ]; then
    continue
  fi
  
  # Add PR number to each new plugin and append to output
  echo "$new_plugins" | jq -c --arg pr "$pr_number" '.[] | . + {pr_number: ($pr | tonumber)}' >> "$PENDING_FILE" 2>/dev/null || continue
  
  new_count=$(echo "$new_plugins" | jq 'length' 2>/dev/null) || continue
  if [ "$new_count" -gt 0 ]; then
    extracted=$((extracted + new_count))
  fi
  
done < "$PR_LIST_FILE"

echo "  Progress: ${processed}/${total_prs} PRs (extracted: ${extracted}, skipped: ${skipped})"

# Step 5: Deduplicate and create final output
echo ""
echo "=== Step 5: Creating final output ==="

# Handle incremental mode - merge with existing pending plugins
if [ "$INCREMENTAL" = true ] && [ -f "$OUTPUT_DIR/pending-plugins.json" ]; then
  echo "Merging with existing pending-plugins.json..."
  
  # Convert JSONL to array, then merge with existing
  jq -s '.' "$PENDING_FILE" > "$WORK_DIR/new_pending.json"
  
  # Combine existing and new, deduplicate by ID (prefer newer)
  jq -s '
    add |
    group_by(.id) | 
    map(last) |
    sort_by(.name)
  ' "$OUTPUT_DIR/pending-plugins.json" "$WORK_DIR/new_pending.json" > "$OUTPUT_DIR/pending-plugins.json.tmp"
  mv "$OUTPUT_DIR/pending-plugins.json.tmp" "$OUTPUT_DIR/pending-plugins.json"
else
  # Fresh run - just deduplicate
  jq -s '
    group_by(.id) | 
    map(.[0]) |
    sort_by(.name)
  ' "$PENDING_FILE" > "$OUTPUT_DIR/pending-plugins.json"
fi

PENDING_COUNT=$(jq 'length' "$OUTPUT_DIR/pending-plugins.json")

# Save state for incremental mode
if [ "$INCREMENTAL" = true ] && [ "$max_pr" -gt 0 ]; then
  echo "$max_pr" > "$STATE_FILE"
  echo "Saved state: last PR #${max_pr}"
fi

echo ""
echo "========================================="
echo "Done!"
echo "========================================="
echo "Open PRs processed:  ${processed}"
echo "Skipped:             ${skipped}"
echo "Current plugins:     ${CURRENT_COUNT}"
echo "Pending plugins:     ${PENDING_COUNT}"
echo "========================================="
echo ""
echo "Output files:"
echo "  ${OUTPUT_DIR}/current-plugins.json"
echo "  ${OUTPUT_DIR}/pending-plugins.json"
