#!/bin/bash

# ================= 設定區 =================
LOG_BRANCH="history"
REMOTE_NAME="origin"
TEMP_INDEX_FILE=".git/temp_snap"
STASH_REF="refs/remote-stash/auto-sync"
# =========================================

cd "$(dirname "$0")" || exit

git fetch "$REMOTE_NAME" "$LOG_BRANCH" -q 2>/dev/null || true

# --- 1. 快照當前工作區（含 uncommitted 變更）寫入 history ---
export GIT_INDEX_FILE="$TEMP_INDEX_FILE"
rm -f "$TEMP_INDEX_FILE"

git rev-parse --verify HEAD -q 2>/dev/null && git read-tree HEAD

git add -A
TREE=$(git write-tree)

unset GIT_INDEX_FILE
rm -f "$TEMP_INDEX_FILE"

REMOTE_TIP=$(git rev-parse --verify --quiet "refs/remotes/$REMOTE_NAME/$LOG_BRANCH")
LOCAL_TIP=$(git rev-parse --verify --quiet "refs/heads/$LOG_BRANCH")

if [ -n "$REMOTE_TIP" ] && [ -n "$LOCAL_TIP" ]; then
    if git merge-base --is-ancestor "$LOCAL_TIP" "$REMOTE_TIP" 2>/dev/null; then
        PARENT="$REMOTE_TIP"
    else
        PARENT="$LOCAL_TIP"
    fi
elif [ -n "$REMOTE_TIP" ]; then
    PARENT="$REMOTE_TIP"
else
    PARENT="$LOCAL_TIP"
fi

PARENT_TREE=$(git rev-parse --verify --quiet "$PARENT^{tree}" 2>/dev/null)

if [ "$TREE" != "$PARENT_TREE" ]; then
    TS=$(date +"%Y-%m-%d %H:%M:%S")
    if [ -n "$PARENT" ]; then
        C=$(echo "$TS" | git commit-tree "$TREE" -p "$PARENT")
    else
        C=$(echo "$TS" | git commit-tree "$TREE")
    fi

    git update-ref "refs/heads/$LOG_BRANCH" "$C"
    git update-ref "refs/remotes/$REMOTE_NAME/$LOG_BRANCH" "$C"
    git push "$REMOTE_NAME" "$LOG_BRANCH" -q > /dev/null 2>&1
fi

# --- 2. 同步 uncommitted 變更到 remote（供換機器時還原）---
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || \
   [ -n "$(git ls-files --others --exclude-standard)" ]; then

    git stash drop 2>/dev/null || true
    git stash push -u -m "auto-sync"
    git push "$REMOTE_NAME" "refs/stash:$STASH_REF" --force -q 2>/dev/null
    # stash pop 還原工作區，讓下次快照仍能照到變更
    git stash pop -q 2>/dev/null
fi
