#!/bin/bash
echo "=== Installing Ollama ==="
curl -fsSL https://ollama.ai/install.sh | sh

echo "=== Starting Ollama ==="
ollama serve &
sleep 3

echo "=== Pulling Dolphin3 ==="
ollama pull nchapman/dolphin3.0-qwen2.5

echo "=== Done. Testing ==="
ollama list
