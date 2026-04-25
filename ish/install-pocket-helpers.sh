#!/bin/sh
# install-pocket-helpers.sh — copy pocket-* helpers into /usr/local/bin.
#
# Run on the iSH (Alpine) host. Re-runs are idempotent.
#
# Usage:
#   sh ish/install-pocket-helpers.sh                # install to /usr/local/bin
#   PREFIX=$HOME/.local/bin sh ish/install-pocket-helpers.sh
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"

mkdir -p "$PREFIX"

for name in pocket-connect pocket-status pocket-stop pocket-watch pocket-auto; do
  src="$SRC_DIR/$name"
  if [ ! -r "$src" ]; then
    echo "skip: $src not found" >&2
    continue
  fi
  install -m 0755 "$src" "$PREFIX/$name" 2>/dev/null \
    || { cp "$src" "$PREFIX/$name" && chmod 0755 "$PREFIX/$name"; }
  echo "installed: $PREFIX/$name"
done

echo
echo "Done. Try:"
echo "  POCKET_SSH_PORT=2232 POCKET_BORE_SERVER=bore.pub $PREFIX/pocket-connect restart"
echo "  $PREFIX/pocket-watch start"
echo "  $PREFIX/pocket-status"
