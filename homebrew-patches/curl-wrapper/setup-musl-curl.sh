#!/bin/sh
# Set up Alpine musl curl inside Debian chroot for iSH compatibility
# iSH kernel 4.20.69 cannot run glibc curl (/usr/bin/curl in chroot)
# This copies the Alpine musl curl + libs into the chroot's musl tree
# Run from iSH Alpine host (not inside chroot)
#
# After running:
#   /mnt/debian/usr/local/bin/curl --version  (via chroot) should show Alpine curl
#   Set HOMEBREW_CURL=/usr/local/bin/curl + HOMEBREW_FORCE_BREWED_CURL=1

set -e

MUSL=/mnt/debian/usr/local/musl

echo "[curl-setup] Copying Alpine musl curl binary..."
cp /usr/bin/curl "$MUSL/bin/curl"
chmod +x "$MUSL/bin/curl"

echo "[curl-setup] Copying libcurl and dependencies..."
# libcurl
cp /usr/lib/libcurl.so.4.8.0 "$MUSL/lib/"
cd "$MUSL/lib"
ln -sf libcurl.so.4.8.0 libcurl.so.4

# SSL / crypto
cp /usr/lib/libssl.so.1.1  "$MUSL/lib/" 2>/dev/null || true
cp /usr/lib/libcrypto.so.1.1 "$MUSL/lib/" 2>/dev/null || true

# HTTP/2
cp /usr/lib/libnghttp2.so.14 "$MUSL/lib/" 2>/dev/null || true

# Brotli
cp /usr/lib/libbrotlidec.so.1    "$MUSL/lib/" 2>/dev/null || true
cp /usr/lib/libbrotlicommon.so.1 "$MUSL/lib/" 2>/dev/null || true

echo "[curl-setup] Writing /usr/local/bin/curl wrapper..."
cat > /mnt/debian/usr/local/bin/curl << 'CURLEOF'
#!/bin/sh
# Alpine musl curl wrapper for Debian chroot on iSH
# Uses musl 1.2.6 dynamic linker with musl lib path
# Bypasses glibc curl (incompatible with iSH kernel 4.20.69)
exec /usr/local/musl/lib/ld-musl-1.2.6-i386.so.1 \
  --library-path /usr/local/musl/lib \
  /usr/local/musl/bin/curl "$@"
CURLEOF
chmod +x /mnt/debian/usr/local/bin/curl

echo "[curl-setup] Testing curl from chroot..."
chroot /mnt/debian /usr/local/bin/curl --version 2>&1 | head -1
echo "[curl-setup] Done."

echo ""
echo "Required brew env vars:"
echo "  export HOMEBREW_CURL=/usr/local/bin/curl"
echo "  export HOMEBREW_FORCE_BREWED_CURL=1"
