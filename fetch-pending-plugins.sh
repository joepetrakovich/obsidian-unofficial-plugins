#!/bin/bash

# Fetch pending Obsidian community plugins from open PRs
# 
# This script:
# 1. Fetches open PR numbers for community-plugins.json via gh CLI
# 2. Batch fetches all merge refs
# 3. Locally extracts plugin data from each PR
# 4. Outputs pending-plugins.json with all pending plugin submissions
#
# Requirements: git, jq, gh

set -e

REPO_URL="https://github.com/obsidianmd/obsidian-releases.git"
API_REPO="obsidianmd/obsidian-releases"
OUTPUT_DIR="_data"
WORK_DIR="_work"
CLEANUP=true

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      echo "Usage: $0"
      echo ""
      echo "Fetches pending plugin submissions from open PRs in obsidian-releases."
      echo ""
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
# Save PR number + owner login + title for matching at the end
PR_MAP_FILE="$WORK_DIR/pr_map.json"
gh pr list -R "${API_REPO}" --limit 5000 \
  --search "community-plugins in:path" \
  --json number,headRepositoryOwner,title > "$PR_MAP_FILE"

# Extract just PR numbers for processing
PR_ORDER_FILE="$WORK_DIR/pr_order.txt"
jq -r '.[].number' "$PR_MAP_FILE" > "$PR_ORDER_FILE"

# Sort for processing (batch fetch works better with sorted refs)
sort -n "$PR_ORDER_FILE" > "$PR_LIST_FILE"

total_prs=$(wc -l < "$PR_LIST_FILE" | tr -d ' ')
echo "Found ${total_prs} open PRs modifying community-plugins.json"

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

echo "Batch fetching all PR merge refs..."
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
echo "=== Step 4: Processing PRs ==="

PENDING_FILE="$WORK_DIR/pending.jsonl"
> "$PENDING_FILE"

processed=0
extracted=0
skipped=0

while IFS= read -r pr_number; do
  processed=$((processed + 1))
  
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

# Deduplicate and fix PR numbers by matching repo owner to PR headRepositoryOwner
# When an owner has multiple PRs, fuzzy match plugin name against PR title
# Fallback to name-based matching across all PRs if no owner match
# Output warnings for unmatched plugins

UNMATCHED_FILE="$WORK_DIR/unmatched.jsonl"

jq -s --slurpfile prmap "$PR_MAP_FILE" '
  # Build owner (lowercase) -> [{number, title, index}] map from PR list
  # Group by owner since one owner can have multiple PRs
  ($prmap[0] | to_entries | map({
    owner: (.value.headRepositoryOwner.login | ascii_downcase),
    number: .value.number,
    title: (.value.title // ""),
    index: .key
  })) as $allPRs |
  
  ($allPRs | group_by(.owner) | map({key: .[0].owner, value: .}) | from_entries) as $ownerPRs |
  
  # Deduplicate plugins by id
  group_by(.id) | 
  map(.[0]) |
  
  # Match each plugin to correct PR
  map(
    (.repo | split("/")[0] | ascii_downcase) as $owner |
    .name as $pluginName |
    ($pluginName | ascii_downcase) as $nameLower |
    
    # Get PRs for this owner
    ($ownerPRs[$owner] // []) as $prs |
    
    if ($prs | length) == 1 then
      # Single PR for owner - direct match
      { plugin: ., pr_number: $prs[0].number, pr_order: $prs[0].index, status: "owner_match" }
    elif ($prs | length) > 1 then
      # Multiple PRs for same owner - fuzzy match plugin name against PR title
      # PR titles should follow "Add plugin: {Plugin Name}" pattern
      ($prs | map(select(.title | ascii_downcase | contains("add plugin:") and contains($nameLower))) | .[0]) as $matched |
      
      if $matched then
        { plugin: ., pr_number: $matched.number, pr_order: $matched.index, status: "owner_name_match" }
      else
        # Multiple PRs but no title match - output warning
        { plugin: ., pr_number: null, pr_order: null, status: "owner_multiple_no_title_match" }
      end
    else
      # No owner match - try name-based fallback across ALL PRs
      # Require "Add plugin:" prefix to avoid false positives
      ($allPRs | map(select(.title | ascii_downcase | contains("add plugin:") and contains($nameLower))) | .[0]) as $nameMatch |
      
      if $nameMatch then
        { plugin: ., pr_number: $nameMatch.number, pr_order: $nameMatch.index, status: "name_fallback" }
      else
        # No match at all
        { plugin: ., pr_number: null, pr_order: null, status: "no_match" }
      end
    end
  ) |
  
  # Separate matched and unmatched
  {
    matched: [.[] | select(.pr_number != null) | .plugin + {pr_number: .pr_number, pr_order: .pr_order}],
    unmatched: [.[] | select(.pr_number == null)]
  }
' "$PENDING_FILE" > "$WORK_DIR/matched_result.json"

# Extract unmatched plugins and output warnings
jq -r '.unmatched[] | "WARNING: No matching PR for plugin: \(.plugin.id) (name: \"\(.plugin.name)\", repo: \"\(.plugin.repo)\", status: \(.status))"' "$WORK_DIR/matched_result.json"

# Save unmatched to file for reference
jq '.unmatched' "$WORK_DIR/matched_result.json" > "$UNMATCHED_FILE"
unmatched_count=$(jq '.unmatched | length' "$WORK_DIR/matched_result.json")

# Create final output from matched plugins
jq '.matched | sort_by(.pr_order) | map(del(.pr_order))' "$WORK_DIR/matched_result.json" > "$OUTPUT_DIR/pending-plugins.json"

PENDING_COUNT=$(jq 'length' "$OUTPUT_DIR/pending-plugins.json")

echo ""
echo "========================================="
echo "Done!"
echo "========================================="
echo "Open PRs processed:  ${processed}"
echo "Skipped:             ${skipped}"
echo "Current plugins:     ${CURRENT_COUNT}"
echo "Pending plugins:     ${PENDING_COUNT}"
echo "Unmatched plugins:   ${unmatched_count}"
echo "========================================="
echo ""
echo "Output files:"
echo "  ${OUTPUT_DIR}/current-plugins.json"
echo "  ${OUTPUT_DIR}/pending-plugins.json"
if [ "$unmatched_count" -gt 0 ]; then
  echo ""
  echo "Review unmatched plugins above and fix manually if needed."
fi
