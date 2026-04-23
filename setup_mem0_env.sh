#!/bin/sh
# setup_mem0_env.sh — Write mem0 credentials to the correct env file
#
# iSH (runs as root):   writes /root/.mem0_env
# Linux VM (user):      writes ~/.mem0_env
#
# Usage:
#   sh /root/perplexity/setup_mem0_env.sh          # iSH
#   bash ~/pocket-lab-v2-6/setup_mem0_env.sh       # Linux VM

MEM0_API_KEY="m0-4szOQ3KGHPLqKcNzVc060nPxplieu2oxZh8OAlil"

# Determine target path — root uses /root/.mem0_env, others use ~/.mem0_env
if [ "$(id -u)" = "0" ]; then
  ENV_FILE="/root/.mem0_env"
else
  ENV_FILE="${HOME}/.mem0_env"
fi

# Remove any existing MEM0_API_KEY lines then write clean file
if [ -f "$ENV_FILE" ]; then
  grep -v "^MEM0_API_KEY" "$ENV_FILE" > /tmp/.mem0_env_tmp
else
  : > /tmp/.mem0_env_tmp
fi
echo "MEM0_API_KEY=$MEM0_API_KEY" >> /tmp/.mem0_env_tmp
mv /tmp/.mem0_env_tmp "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "[mem0] Written: $ENV_FILE"
echo "[mem0] Key:     ${MEM0_API_KEY:0:12}..."
