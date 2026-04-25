#!/bin/bash

# ================= 設定區 =================
LOG_BRANCH="history"
REMOTE_NAME="origin"
TEMP_INDEX_FILE=".git/temp_snap"

source ~/.env
# =========================================

cd "$(dirname "$0")" || exit

git fetch "$REMOTE_NAME" "$LOG_BRANCH" -q 2>/dev/null || true

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
[ "$TREE" = "$PARENT_TREE" ] && exit 0

TS=$(date +"%Y-%m-%d %H:%M:%S")
if [ -n "$PARENT" ]; then
    C=$(echo "$TS" | git commit-tree "$TREE" -p "$PARENT")
else
    C=$(echo "$TS" | git commit-tree "$TREE")
fi

git update-ref "refs/heads/$LOG_BRANCH" "$C"
git update-ref "refs/remotes/$REMOTE_NAME/$LOG_BRANCH" "$C"

git push "$REMOTE_NAME" "$LOG_BRANCH" > /dev/null 2>&1
