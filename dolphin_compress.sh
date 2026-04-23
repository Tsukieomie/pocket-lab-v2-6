#!/bin/bash
# ============================================================
# dolphin_compress.sh — Dolphin3 Token Pre-Processor
#
# Sends your message to local Dolphin3 first.
# Dolphin compresses it to a dense, minimal prompt.
# Only the compressed version reaches Perplexity Computer.
#
# Result: near-zero token overhead on the Perplexity side.
#
# Usage:
#   bash dolphin_compress.sh "your message"
#   eval $(bash dolphin_compress.sh "your message")  # prints compressed
# ============================================================

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL="${DOLPHIN_MODEL:-nchapman/dolphin3.0-qwen2.5:latest}"

RESET="\033[0m"
DIM="\033[2m"
CYAN="\033[96m"
YELLOW="\033[93m"

INPUT="$*"

if [ -z "$INPUT" ]; then
    echo "Usage: bash dolphin_compress.sh \"your message\""
    exit 1
fi

# Dolphin's job: compress the input to its minimal intent
SYSTEM="You are a prompt compressor. Your only job is to rewrite the user's message as the shortest possible prompt that preserves 100% of the intent and context. Remove all filler words, pleasantries, redundancy. Output ONLY the compressed prompt, nothing else. No explanation. No preamble."

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'system': sys.argv[2],
    'prompt': sys.argv[3],
    'stream': False
}))
" "$MODEL" "$SYSTEM" "$INPUT")

echo -e "${DIM}[dolphin] compressing...${RESET}" >&2

COMPRESSED=$(curl -sf --max-time 60 "${OLLAMA_URL}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('response', '').strip())
")

echo -e "${CYAN}Original (${#INPUT} chars)${RESET} → ${YELLOW}Compressed (${#COMPRESSED} chars)${RESET}" >&2
echo -e "${DIM}$COMPRESSED${RESET}" >&2
echo ""

# Output compressed prompt for use
echo "$COMPRESSED"
