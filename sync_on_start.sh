#!/bin/bash

# ================= 設定區 =================
REMOTE_NAME="origin"
STASH_REF="refs/remote-stash/auto-sync"
# =========================================

cd "$(dirname "$0")" || exit

git fetch "$REMOTE_NAME" "$STASH_REF:refs/stash-remote-tmp" --force -q 2>/dev/null || exit 0

REMOTE_STASH=$(git rev-parse --verify --quiet refs/stash-remote-tmp)
LOCAL_STASH=$(git rev-parse --verify --quiet refs/stash 2>/dev/null)

# remote stash 與本地相同，不需要 pop
[ "$REMOTE_STASH" = "$LOCAL_STASH" ] && git update-ref -d refs/stash-remote-tmp && exit 0

git update-ref -d refs/stash-remote-tmp

git stash drop 2>/dev/null || true
git stash store -m "auto-sync from remote" "$REMOTE_STASH"
git stash pop
