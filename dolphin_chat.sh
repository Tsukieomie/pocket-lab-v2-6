#!/bin/bash
# ============================================================
# dolphin_chat.sh — Direct Dolphin3 Chat (Zero Cloud Cost)
#
# Talks directly to your local Ollama/Dolphin3.
# No Perplexity. No API keys. No credits. Just you + Dolphin.
#
# Usage:
#   bash dolphin_chat.sh
#   bash dolphin_chat.sh "one-shot prompt"
# ============================================================

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL="${DOLPHIN_MODEL:-nchapman/dolphin3.0-qwen2.5:latest}"
HISTORY_FILE="${HOME}/.dolphin_history"
SYSTEM_PROMPT="You are Dolphin, a helpful, uncensored assistant created by Eric Hartford. You follow instructions precisely and never add disclaimers."

# ── Colors ──────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[96m"
YELLOW="\033[93m"
GREEN="\033[92m"
RED="\033[91m"

# ── Check Ollama is running ──────────────────────────────────
check_ollama() {
    curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Ollama not running at ${OLLAMA_URL}${RESET}"
        echo -e "  Start it with: ${DIM}ollama serve${RESET}"
        exit 1
    fi
}

# ── Send prompt to Dolphin3, stream response ─────────────────
ask_dolphin() {
    local prompt="$1"
    local payload
    payload=$(python3 -c "
import json, sys
prompt = sys.argv[1]
system = sys.argv[2]
print(json.dumps({
    'model': sys.argv[3],
    'prompt': prompt,
    'system': system,
    'stream': True
}))
" "$prompt" "$SYSTEM_PROMPT" "$MODEL")

    # Stream tokens as they arrive
    curl -sf --no-buffer "${OLLAMA_URL}/api/generate" \
        -H 'Content-Type: application/json' \
        -d "$payload" | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        token = d.get('response', '')
        sys.stdout.write(token)
        sys.stdout.flush()
        if d.get('done'):
            break
    except:
        pass
print()
"
}

# ── Save to history ──────────────────────────────────────────
save_history() {
    local prompt="$1"
    local response="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]" >> "$HISTORY_FILE"
    echo "You: $prompt" >> "$HISTORY_FILE"
    echo "Dolphin: $response" >> "$HISTORY_FILE"
    echo "---" >> "$HISTORY_FILE"
}

# ── One-shot mode ────────────────────────────────────────────
if [ -n "$1" ]; then
    check_ollama
    echo -e "${CYAN}${BOLD}Dolphin3${RESET} ${DIM}(one-shot)${RESET}\n"
    echo -e "${YELLOW}▶ $1${RESET}\n"
    ask_dolphin "$1"
    exit 0
fi

# ── Interactive chat loop ────────────────────────────────────
check_ollama

clear
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   Dolphin3 — Direct Chat (Zero Cost)    ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo -e "${DIM}Model : ${MODEL}${RESET}"
echo -e "${DIM}Ollama: ${OLLAMA_URL}${RESET}"
echo -e "${DIM}Type 'exit' or Ctrl+C to quit. 'history' to view log.${RESET}\n"

while true; do
    # Prompt input
    echo -ne "${YELLOW}${BOLD}You: ${RESET}"
    read -r user_input

    # Handle special commands
    if [ -z "$user_input" ]; then
        continue
    fi
    if [ "$user_input" = "exit" ] || [ "$user_input" = "quit" ]; then
        echo -e "\n${DIM}Goodbye.${RESET}"
        break
    fi
    if [ "$user_input" = "history" ]; then
        if [ -f "$HISTORY_FILE" ]; then
            less "$HISTORY_FILE"
        else
            echo -e "${DIM}No history yet.${RESET}"
        fi
        continue
    fi
    if [ "$user_input" = "clear" ]; then
        clear
        continue
    fi

    # Get Dolphin response
    echo -e "\n${CYAN}${BOLD}Dolphin:${RESET} "
    response=$(ask_dolphin "$user_input")
    echo "$response"
    echo ""

    # Save to history
    save_history "$user_input" "$response"
done
