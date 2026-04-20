#!/usr/bin/env sh
# LOAD_CONTEXT.sh — Pocket Security Lab session bootstrapper
# Run this first when starting a new Perplexity Computer session.
# Queries mem0 for all operational context so the AI skips diagnosis.
#
# Usage (from iSH via SSH):
#   sh /root/perplexity/LOAD_CONTEXT.sh
#
# Usage (tell Perplexity Computer):
#   "Check mem0 for pocket lab context, then open the lab"

set -eu
. /root/.mem0_env
MEM0_API="https://api.mem0.ai/v1"
AGENT="pocket-lab"

echo "============================================================"
echo " POCKET LAB — MEM0 CONTEXT LOADER"
echo "============================================================"
echo ""

for QUERY in \
  "bypass procedure signing gate" \
  "key inventory manifest signing" \
  "known issues GitHub Actions" \
  "infrastructure ports tunnel"; do
  echo "--- $QUERY ---"
  curl -sf -X POST "$MEM0_API/memories/search/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$QUERY\",\"agent_id\":\"$AGENT\",\"limit\":2}" \
  | python3 -c "
import sys, json
results = json.load(sys.stdin)
for r in results.get('results', results if isinstance(results, list) else []):
    print(' >', r.get('memory',''))
" 2>/dev/null || true
  echo ""
done

echo "============================================================"
echo " Context loaded. Perplexity Computer is ready to operate."
echo "============================================================"
