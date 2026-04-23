#!/bin/sh
# ============================================================
# load_pocket_lab.sh — Pocket Lab v2.6 Unified Loader
#
# One command on ANY platform:
#   sh load_pocket_lab.sh          # auto-detect
#   sh load_pocket_lab.sh open     # explicit
#   sh load_pocket_lab.sh mem0     # mem0 context only
#
# Platform detection:
#   iSH (iPhone) — /proc/ish exists OR uname contains "iSH"
#   Linux VM     — everything else
#
# What it does (both platforms):
#   1. Detect platform
#   2. Find the repo root + load mem0 library
#   3. Load mem0 context (bucketed: bypass/keys/issues/infra/ai)
#   4. Route to the right opener:
#        iSH   → PERPLEXITY_LOAD.sh  (3-gate fast open, ≤15s)
#        Linux → PERPLEXITY_LOAD.sh  via SSH tunnel to iSH
# ============================================================
set -eu

# ── Platform detection ────────────────────────────────────
_is_ish() {
  [ -f /proc/ish ] && return 0
  uname -a 2>/dev/null | grep -qi "ish" && return 0
  [ "$(uname -s)" = "Linux" ] && [ -d /root/.pocket_lab_secure ] && return 0
  return 1
}

# ── Locate repo root ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if _is_ish; then
  PLATFORM="iSH"
  WORK="${POCKET_LAB_DIR:-/root/perplexity}"
  MEM0_ENV="/root/.mem0_env"
  BORE_ENV="/root/.bore_env"
else
  PLATFORM="Linux"
  WORK="$SCRIPT_DIR"
  MEM0_ENV="${HOME}/.mem0_env"
  BORE_ENV="${HOME}/.bore_env"
fi

CMD="${1:-open}"

echo "╔══════════════════════════════════════════════════════╗"
echo "║        POCKET LAB v2.6 — LOADING ($PLATFORM)$(printf '%*s' $((18 - ${#PLATFORM})) '')║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Load mem0 library ─────────────────────────────────────
MEM0_LIB="$WORK/mem0.sh"
if [ ! -f "$MEM0_LIB" ]; then
  # Try repo root (Linux running from cloned repo)
  MEM0_LIB="$SCRIPT_DIR/mem0.sh"
fi

if [ -f "$MEM0_LIB" ]; then
  MEM0_ENV_FILE="$MEM0_ENV" . "$MEM0_LIB"
else
  echo "[mem0] WARNING: mem0.sh not found — skipping context load" >&2
fi

# ── Step 1: mem0 context ──────────────────────────────────
echo "[1/2] Loading mem0 context..."
CACHE=/tmp/mem0_context.txt

if [ -f "$CACHE" ] && [ -n "$(find $CACHE -mmin -10 2>/dev/null)" ]; then
  echo "      (cache hit, < 10 min old)"
  cat "$CACHE"
elif [ -f "$MEM0_ENV" ]; then
  # shellcheck disable=SC1090
  . "$MEM0_ENV"
  if command -v mem0_query_bulk >/dev/null 2>&1; then
    mem0_query_bulk 2>/dev/null | tee "$CACHE"
  else
    echo "      [mem0] library not loaded — skipping"
  fi
else
  echo "      [mem0] No credentials found at $MEM0_ENV"
  echo "      Run: sh $SCRIPT_DIR/setup_mem0_env.sh"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo ""

# ── mem0-only mode ────────────────────────────────────────
if [ "$CMD" = "mem0" ]; then
  echo "[done] mem0 context loaded."
  exit 0
fi

# ── Step 2: Open the lab ──────────────────────────────────
echo "[2/2] Opening Pocket Lab v2.6 ($PLATFORM)..."
echo ""

if _is_ish; then
  # ── iSH path: run PERPLEXITY_LOAD.sh directly ─────────
  LOADER="$WORK/PERPLEXITY_LOAD.sh"
  if [ ! -f "$LOADER" ]; then
    echo "ERROR: $LOADER not found." >&2
    echo "  Make sure /root/perplexity/ is up to date:" >&2
    echo "    cd /root/perplexity && git pull" >&2
    exit 1
  fi
  exec sh "$LOADER"

else
  # ── Linux path: SSH via bore tunnel to iSH ────────────
  if [ ! -f "$BORE_ENV" ]; then
    echo "ERROR: $BORE_ENV not found." >&2
    echo "  Run: bash $SCRIPT_DIR/linux/install.sh" >&2
    exit 1
  fi

  BORE_HOST=$(grep '^BORE_HOST=' "$BORE_ENV" | cut -d= -f2 || echo "bore.pub")
  BORE_PORT=$(grep '^BORE_PORT=' "$BORE_ENV" | cut -d= -f2 || echo "40188")
  SSH_KEY_PATH=$(grep '^SSH_KEY_PATH=' "$BORE_ENV" | cut -d= -f2 || echo "")

  # Read live port from bore-port.txt if present and BORE_PORT empty
  BORE_PORT_FILE="$SCRIPT_DIR/bore-port.txt"
  if [ -z "$BORE_PORT" ] && [ -f "$BORE_PORT_FILE" ]; then
    BORE_PORT=$(cat "$BORE_PORT_FILE" | tr -d '[:space:]')
    echo "      (port from bore-port.txt: $BORE_PORT)"
  fi

  echo "      Connecting → $BORE_HOST:$BORE_PORT"
  echo ""

  if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -p "$BORE_PORT" root@"$BORE_HOST" \
      "sh /root/perplexity/PERPLEXITY_LOAD.sh"
  else
    SSH_PASS=$(grep '^SSH_PASS=' "$BORE_ENV" | cut -d= -f2 || echo "")
    if [ -n "$SSH_PASS" ]; then
      sshpass -p "$SSH_PASS" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        -p "$BORE_PORT" root@"$BORE_HOST" \
        "sh /root/perplexity/PERPLEXITY_LOAD.sh"
    else
      echo "ERROR: No SSH key or password found in $BORE_ENV" >&2
      echo "  Set SSH_KEY_PATH or SSH_PASS in $BORE_ENV" >&2
      exit 1
    fi
  fi
fi
