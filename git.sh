#!/bin/bash
# update-remote-branch.sh
#
# Description: Updates a specified local branch with the latest changes from its remote counterpart
# without switching to that branch. Perfect when working on a feature branch but need to refresh
# other branches (like 'dev' or 'main') in the background.
#
# Usage: ./update-remote-branch.sh <branch-name>
# Example: ./update-remote-branch.sh dev
#          (Updates local 'dev' from origin/dev while staying on current branch)
#
# Key Features:
# - Stays on current branch (no checkout/switching)
# - Fast-forwards local branch to match remote
# - Safe - doesn't affect working directory or current branch
# - Shows before/after status for verification

BRANCH_NAME="$1"

if [ -z "$BRANCH_NAME" ]; then
    echo "❌ Error: Please specify a branch name"
    echo "Usage: $0 <branch-name>"
    echo "Example: $0 dev"
    exit 1
fi

echo "🔄 Updating local '$BRANCH_NAME' from origin/$BRANCH_NAME"
echo "📍 Current branch: $(git branch --show-current)"
echo ""

# Check if local branch exists
if ! git show-ref --verify --quiet refs/heads/"$BRANCH_NAME"; then
    echo "⚠️  Local '$BRANCH_NAME' branch doesn't exist. Creating..."
fi

# Show status before update
echo "📊 Before update:"
git log --oneline origin/"$BRANCH_NAME".."$BRANCH_NAME" 2>/dev/null | head -5 || echo "Local branch is ahead or up-to-date"
echo ""

# Perform the update using refspec
git fetch origin "$BRANCH_NAME":"$BRANCH_NAME"

# Show status after update
echo "✅ Update complete!"
echo "📊 After update:"
if git log --oneline origin/"$BRANCH_NAME".."$BRANCH_NAME" 2>/dev/null | grep -q .; then
    echo "   Local '$BRANCH_NAME' is behind origin/$BRANCH_NAME"
else
    echo "   ✓ Local '$BRANCH_NAME' matches origin/$BRANCH_NAME"
fi

echo ""
echo "💡 When ready to switch: git checkout $BRANCH_NAME (already up-to-date!)"
