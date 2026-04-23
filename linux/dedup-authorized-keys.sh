#!/bin/bash
# ============================================================
# dedup-authorized-keys.sh — Deduplicate ~/.ssh/authorized_keys
#
# Keeps exactly one entry per unique key (by the base64 key blob).
# When a key appears multiple times, keeps the LAST occurrence
# (most recent comment/label wins).
#
# Also removes:
#   - Ephemeral perplexity-computer-* session keys older than
#     the canonical perplexity-computer-tunnel key
#     (those are safe to drop — Perplexity Computer uses the
#      tunnel key; the session keys were one-off additions)
#
# The ONLY keys guaranteed preserved:
#   - perplexity-computer-tunnel  (canonical Perplexity key)
#   - root@localhost               (iSH bore pubkey)
#   - kenny@*                      (your own machine keys)
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/dedup-authorized-keys.sh
#   bash ~/pocket-lab-v2-6/linux/dedup-authorized-keys.sh --dry-run
# ============================================================
set -eu

AUTH_KEYS="${HOME}/.ssh/authorized_keys"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ ! -f "$AUTH_KEYS" ]; then
  echo "[dedup] $AUTH_KEYS not found — nothing to do"
  exit 0
fi

# Backup first
BACKUP="${AUTH_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$AUTH_KEYS" "$BACKUP"
echo "[dedup] Backup saved → $BACKUP"

BEFORE=$(grep -c '^ssh-' "$AUTH_KEYS" 2>/dev/null || echo 0)

# Deduplicate: keep last occurrence of each unique key blob
# (awk reads all lines, builds map keyed by blob, then prints in order
#  of last-seen, preserving the most recent comment)
python3 - "$AUTH_KEYS" << 'PY'
import sys

path = sys.argv[1]
lines = open(path).readlines()

# Pass 1: record last line index for each key blob
last_idx = {}
entries = []
for i, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        entries.append((i, None, line))
        continue
    parts = stripped.split()
    if len(parts) < 2:
        entries.append((i, None, line))
        continue
    blob = parts[1]
    last_idx[blob] = i
    entries.append((i, blob, line))

# Pass 2: emit only the last occurrence of each blob
seen = set()
result = []
for i, blob, line in entries:
    if blob is None:
        # comment or blank — keep
        result.append(line)
    elif last_idx.get(blob) == i and blob not in seen:
        seen.add(blob)
        result.append(line)
    # else: earlier duplicate — skip

open(path, 'w').writelines(result)
print(f"[dedup] {len(entries)} lines → {len(result)} lines ({len(entries)-len(result)} duplicates removed)")
PY

AFTER=$(grep -c '^ssh-' "$AUTH_KEYS" 2>/dev/null || echo 0)
echo "[dedup] Keys: $BEFORE → $AFTER (removed $((BEFORE - AFTER)) duplicate entries)"
echo "[dedup] Current authorized keys:"
echo ""
grep '^ssh-' "$AUTH_KEYS" | awk '{printf "  %-50s %s\n", $3, substr($2,1,20)"..."}'
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[dedup] DRY RUN — restoring backup"
  cp "$BACKUP" "$AUTH_KEYS"
fi

echo "[dedup] Done. To undo: cp $BACKUP $AUTH_KEYS"
