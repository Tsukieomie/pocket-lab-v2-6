#!/bin/sh
# Fix duplicate/empty MEM0_API_KEY in /root/.mem0_env
ENV_FILE="/root/.mem0_env"
KEY="m0-4szOQ3KGHPLqKcNzVc060nPxplieu2oxZh8OAlil"

# Remove all MEM0_API_KEY lines, then write clean file
grep -v "^MEM0_API_KEY" "$ENV_FILE" > /tmp/.mem0_env_tmp
echo "MEM0_API_KEY=$KEY" >> /tmp/.mem0_env_tmp
mv /tmp/.mem0_env_tmp "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "=== /root/.mem0_env ==="
cat "$ENV_FILE"
