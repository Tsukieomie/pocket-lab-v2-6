#!/bin/bash
# ============================================================
# bootstrap.sh — One-time setup after a fresh git clone
#
# Installs git hooks and registers the merge.ours driver so
# .gitattributes protection for bore-port.txt is active before
# install.sh is run.
#
# Usage (immediately after cloning):
#   git clone https://github.com/Tsukieomie/pocket-lab-v2-6
#   bash pocket-lab-v2-6/bootstrap.sh
#   bash pocket-lab-v2-6/linux/install.sh   # full setup
#
# Safe to re-run — all operations are idempotent.
# ============================================================
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$REPO_ROOT/linux/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

echo "[bootstrap] Registering merge.ours driver..."
git -C "$REPO_ROOT" config merge.ours.driver true
echo "  merge.ours.driver = true "

echo "[bootstrap] Setting skip-worktree on bore-port.txt..."
git -C "$REPO_ROOT" update-index --skip-worktree bore-port.txt 2>/dev/null || true
echo "  bore-port.txt skip-worktree "

echo "[bootstrap] Installing git hooks..."
for HOOK in post-merge post-checkout; do
  SRC="$HOOKS_SRC/$HOOK"
  DST="$HOOKS_DST/$HOOK"
  if [ ! -f "$SRC" ]; then
    echo "  [skip] $HOOK not found in linux/hooks/"
    continue
  fi
  if [ ! -f "$DST" ]; then
    # No existing hook — install directly
    cp "$SRC" "$DST" && chmod +x "$DST"
    echo "  $HOOK installed "
  elif diff -q "$SRC" "$DST" >/dev/null 2>&1; then
    # Already identical — skip
    echo "  $HOOK already up to date – skipping"
  elif grep -qF "$(head -2 "$SRC" | tail -1)" "$DST" 2>/dev/null; then
    # Our hook content is already present in the file (appended previously)
    echo "  $HOOK already present in existing hook – skipping"
  else
    # Existing hook is someone else's — append ours, don't overwrite
    printf '\n' >> "$DST"
    cat "$SRC" >> "$DST"
    echo "  $HOOK appended to existing hook "
  fi
done

echo ""
echo "[bootstrap] Done. bore-port.txt merge conflicts are now blocked on this machine."
echo "[bootstrap] Run 'bash linux/install.sh' for full setup."
