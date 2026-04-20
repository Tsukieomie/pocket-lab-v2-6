#!/bin/sh
# Homebrew iSH Compatibility Patches
# Run from iSH Alpine host (NOT inside chroot)
# Applies all patches to make Homebrew work with musl ruby 3.4.9 on iSH 4.20.69
# Usage: sh /root/perplexity/brew_apply_patches.sh
#
# Patches applied:
#   1. standalone/init.rb     - Accept Ruby 3.x (override HOMEBREW_REQUIRED_RUBY_VERSION >= 4)
#   2. vendor/bundle symlink  - ruby/3.4.0 -> ruby/4.0.0 so gems are found
#   3. shims/shared/curl      - Remove bash -p flag (getcwd issue on iSH)
#   4. shims/shared/svn       - Remove bash -p flag
#   5. shims/shared/git       - Remove bash -p flag  
#   6. shims/utils.sh         - Replace < <(type -aP) with <<< "$(...)" (no /dev/fd on iSH)
#   7. /usr/local/bin/curl    - musl curl wrapper (Alpine curl via musl linker)
#   8. /usr/local/musl/bin/curl - Copied Alpine curl binary
#   9. /usr/local/musl/lib/   - Copied libcurl.so.4, libssl, libcrypto, libnghttp2, libbrotli*

set -e

BREW_LIB=/mnt/debian/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew
SHIMS=$BREW_LIB/shims

echo "[brew_patch] === Homebrew iSH Compatibility Patcher ==="

# ── 1. standalone/init.rb ──────────────────────────────────────────────────
echo "[brew_patch] Patching standalone/init.rb..."
INIT="$BREW_LIB/standalone/init.rb"
cp "$INIT" "${INIT}.orig" 2>/dev/null || true

python3 - "$INIT" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

old = 'required_ruby_major, required_ruby_minor, = ENV.fetch("HOMEBREW_REQUIRED_RUBY_VERSION", "").split(".").map(&:to_i)'
new = '''required_ruby_major, required_ruby_minor, = ENV.fetch("HOMEBREW_REQUIRED_RUBY_VERSION", "").split(".").map(&:to_i)
# PATCH iSH: accept Ruby 3.x
if required_ruby_major.nil? || required_ruby_major >= 4
  required_ruby_major = 3
  required_ruby_minor = 0
end'''

src = src.replace(old, new) if old in src else src
src = src.replace('  vendored_versions = ["4.0"].freeze',
                   '  vendored_versions = ["4.0", "3.4", "3.3", "3.2", "3.1", "3.0"].freeze  # PATCH iSH')
with open(path, "w") as f:
    f.write(src)
print("  OK: standalone/init.rb")
PYEOF

# ── 2. vendor/bundle symlink ───────────────────────────────────────────────
echo "[brew_patch] Creating vendor/bundle ruby 3.4.0 symlink..."
BUNDLE=/mnt/debian/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby
if [ ! -e "$BUNDLE/3.4.0" ]; then
    ln -s "$BUNDLE/4.0.0" "$BUNDLE/3.4.0"
    echo "  OK: symlink $BUNDLE/3.4.0 -> 4.0.0"
else
    echo "  SKIP: $BUNDLE/3.4.0 already exists"
fi

# ── 3. Remove bash -p from shims ──────────────────────────────────────────
echo "[brew_patch] Removing bash -p from shims..."
for f in "$SHIMS/shared/curl" "$SHIMS/shared/svn" "$SHIMS/shared/git" \
         "$SHIMS/super/curl" "$SHIMS/super/svn" "$SHIMS/super/git" \
         "$SHIMS/linux/super/curl" "$SHIMS/linux/super/svn" "$SHIMS/linux/super/git"; do
    [ -f "$f" ] || continue
    if grep -q "#!/bin/bash -p" "$f" 2>/dev/null; then
        sed -i "s|#!/bin/bash -p|#!/bin/bash|" "$f"
        echo "  OK: $f"
    fi
done

# ── 4. Fix utils.sh process substitution ──────────────────────────────────
echo "[brew_patch] Patching shims/utils.sh..."
UTILS="$SHIMS/utils.sh"
if grep -q "< <(type -aP" "$UTILS" 2>/dev/null; then
    sed -i 's|  done < <(type -aP "${file}")|  done <<< "$(type -aP "${file}")"|' "$UTILS"
    echo "  OK: utils.sh process substitution fixed"
else
    echo "  SKIP: utils.sh already patched"
fi

# ── 5. musl curl wrapper ───────────────────────────────────────────────────
echo "[brew_patch] Setting up musl curl wrapper..."

# Copy Alpine curl and libs if not done
if [ ! -f /mnt/debian/usr/local/musl/bin/curl ]; then
    cp /usr/bin/curl /mnt/debian/usr/local/musl/bin/curl
    echo "  Copied: Alpine curl binary"
fi

# Copy and symlink libcurl
if [ ! -f /mnt/debian/usr/local/musl/lib/libcurl.so.4.8.0 ]; then
    cp /usr/lib/libcurl.so.4.8.0 /mnt/debian/usr/local/musl/lib/
fi
if [ ! -L /mnt/debian/usr/local/musl/lib/libcurl.so.4 ]; then
    cd /mnt/debian/usr/local/musl/lib/
    ln -sf libcurl.so.4.8.0 libcurl.so.4
fi

# Copy other required libs
for lib in libnghttp2.so.14 libssl.so.1.1 libcrypto.so.1.1 libbrotlidec.so.1 libbrotlicommon.so.1; do
    src=$(find /usr/lib /lib -name "$lib" 2>/dev/null | head -1)
    dest="/mnt/debian/usr/local/musl/lib/$lib"
    if [ -n "$src" ] && [ ! -f "$dest" ]; then
        cp "$src" "$dest"
        echo "  Copied: $lib"
    fi
done

# Write wrapper
cat > /mnt/debian/usr/local/bin/curl << 'CURLEOF'
#!/bin/sh
# Alpine musl curl wrapper (iSH compatible — no FUTEX issues)
exec /usr/local/musl/lib/ld-musl-1.2.6-i386.so.1 \
  --library-path /usr/local/musl/lib \
  /usr/local/musl/bin/curl "$@"
CURLEOF
chmod +x /mnt/debian/usr/local/bin/curl
echo "  OK: /usr/local/bin/curl wrapper"

echo ""
echo "[brew_patch] === All patches applied ==="
echo "[brew_patch] Test with:"
echo "  cd / && chroot /mnt/debian /bin/bash -c '"'
echo '  export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin'
echo '  export HOME=/root'
echo '  export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1'
echo '  export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1'
echo '  export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew'
echo '  export HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar'
echo '  export HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew'
echo '  export HOMEBREW_GIT_PATH=/usr/local/bin/git'
echo '  export HOMEBREW_RUBY_PATH=/usr/local/bin/ruby'
echo '  export HOMEBREW_DEVELOPER=1 HOMEBREW_USE_RUBY_FROM_PATH=1'
echo '  export GEM_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/3.4.0'
echo '  export BUNDLE_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle'
echo '  export HOMEBREW_CURL=/usr/local/bin/curl'
echo '  export HOMEBREW_FORCE_BREWED_CURL=1'
echo "  brew install hello'"
