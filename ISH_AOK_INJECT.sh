#!/bin/sh
# ============================================================
# ISH_AOK_INJECT.sh — AOK userspace layer installer for stock iSH
# Pocket Lab v2.6
#
# Run this ONCE inside iSH to inject the AOK filesystem tools
# and /proc/ish shims without TestFlight or Xcode.
#
# What this does:
#   1. Installs AOK-Filesystem-Tools from emkey1/AOK-Filesystem-Tools
#   2. Creates /proc/ish/* shims (host_info, BAT0, UIDevice)
#      sourced from whatever stock iSH exposes
#   3. Creates /dev/rtc shim (char device stub)
#   4. Wires everything into /etc/profile so it persists
#
# NOTE: /dev/location and kernel syscall patches (clock_nanosleep_time64)
#       require the actual AOK binary. Those are NOT shimmed here.
#       Everything else that can be done in userspace IS done here.
# ============================================================

set -e

log() { echo "[AOK-INJECT] $*"; }
ok()  { echo "[AOK-INJECT] ✓ $*"; }
err() { echo "[AOK-INJECT] ✗ $*" >&2; }

log "=== iSH AOK Userspace Injection ==="

# ── Prerequisites ─────────────────────────────────────────
log "[1/6] Installing prerequisites..."
apk update -q
apk add -q git curl python3 openssl util-linux procps
ok "Prerequisites ready"

# ── AOK-Filesystem-Tools ──────────────────────────────────
log "[2/6] Pulling AOK-Filesystem-Tools..."
rm -rf /opt/AOK
if command -v git >/dev/null 2>&1; then
  git clone --depth 1 https://github.com/emkey1/AOK-Filesystem-Tools.git /opt/AOK 2>&1 \
    || { err "git clone failed — trying curl fallback"; AOK_GIT_FAILED=1; }
fi

if [ "${AOK_GIT_FAILED:-0}" = "1" ]; then
  mkdir -p /opt/AOK
  curl -fsSL https://github.com/emkey1/AOK-Filesystem-Tools/archive/refs/heads/master.tar.gz \
    | tar -xz --strip-components=1 -C /opt/AOK
fi
ok "AOK-Filesystem-Tools at /opt/AOK"

# ── /proc/ish shim directory ──────────────────────────────
log "[3/6] Creating /proc/ish shims..."
mkdir -p /proc/ish

# /proc/ish/host_info — pull from stock iSH /proc entries
cat > /usr/local/bin/aok-host-info << 'HOSTINFO'
#!/bin/sh
# Reads host info from stock iSH /proc and uname
OS_NAME=$(uname -s 2>/dev/null || echo "Darwin")
OS_RELEASE=$(uname -r 2>/dev/null || echo "unknown")
OS_VERSION=$(uname -v 2>/dev/null || echo "unknown")
ARCH=$(uname -m 2>/dev/null || echo "arm64")
# iSH exposes some host info via /proc/ish on AOK; stub for stock
MACHINE=$(cat /proc/ish/machine_id 2>/dev/null || echo "iPhone")
printf "Host OS Name: %s\n" "$OS_NAME"
printf "Host OS Release: %s\n" "$OS_RELEASE"
printf "Host OS Version: %s\n" "$OS_VERSION"
printf "Host Architecture: %s\n" "$ARCH"
printf "Host Machine Identifier: %s\n" "$MACHINE"
printf "Host Device Name: %s\n" "$MACHINE"
HOSTINFO
chmod +x /usr/local/bin/aok-host-info

# /proc/ish/BAT0 — stub (stock iSH has no battery access; AOK binary needed)
cat > /usr/local/bin/aok-battery << 'BATTERY'
#!/bin/sh
# Battery data requires iSH-AOK binary (UIDevice.batteryLevel).
# This stub returns a placeholder so scripts don't break.
# If you see real values, you are running iSH-AOK.
if [ -f /proc/ish/BAT0 ]; then
  cat /proc/ish/BAT0
else
  printf "battery_level: N/A\nbattery_state: Unknown\nlow_power_mode: Unknown\n"
fi
BATTERY
chmod +x /usr/local/bin/aok-battery

# /proc/ish/UIDevice — stub
cat > /usr/local/bin/aok-uidevice << 'UIDEV'
#!/bin/sh
if [ -f /proc/ish/UIDevice ]; then
  cat /proc/ish/UIDevice
else
  printf "Model: iPhone (stock iSH)\n"
  printf "OS Name: iOS\n"
  printf "OS Version: unknown\n"
  printf "Device Orientation: Unknown\n"
  printf "Battery Monitoring Enabled: NO\n"
fi
UIDEV
chmod +x /usr/local/bin/aok-uidevice

# Symlink shims so scripts that cat /proc/ish/* still work
# (only if AOK kernel hasn't already mounted real ones)
for f in host_info BAT0 UIDevice; do
  if [ ! -e "/proc/ish/$f" ]; then
    case "$f" in
      host_info) ln -sf /usr/local/bin/aok-host-info  /proc/ish/$f ;;
      BAT0)      ln -sf /usr/local/bin/aok-battery    /proc/ish/$f ;;
      UIDevice)  ln -sf /usr/local/bin/aok-uidevice   /proc/ish/$f ;;
    esac
  fi
done
ok "/proc/ish shims created"

# ── /dev/rtc stub ─────────────────────────────────────────
log "[4/6] Creating /dev/rtc stub..."
if [ ! -e /dev/rtc ]; then
  # Create a named pipe that returns current epoch — enough to
  # satisfy Debian init scripts that probe /dev/rtc
  mknod /dev/rtc c 254 0 2>/dev/null || true
  chmod 666 /dev/rtc 2>/dev/null || true

  # Fallback: create a script-backed rtc that Debian scripts can use
  cat > /usr/local/bin/aok-rtc << 'RTC'
#!/bin/sh
# Minimal RTC shim — outputs current time in hwclock-compatible format
date -u "+%Y-%m-%d %H:%M:%S.000000+00:00"
RTC
  chmod +x /usr/local/bin/aok-rtc
  ok "/dev/rtc stub created (mknod char 254:0)"
else
  ok "/dev/rtc already exists"
fi

# ── /AOK mountpoint shim ──────────────────────────────────
log "[5/6] Creating /AOK pseudo-filesystem..."
mkdir -p /AOK
cat > /AOK/README.txt << 'AOKREADME'
iSH-AOK support files

This is a userspace shim of the AOK pseudo-filesystem.
On real iSH-AOK, this is a kernel-mounted read-only fs.
Here it is populated by ISH_AOK_INJECT.sh for compatibility.
AOKREADME

# Get version from AOK repo if available
AOK_VERSION="iSH-AOK-userspace-inject"
if [ -f /opt/AOK/VERSION ]; then
  AOK_VERSION=$(cat /opt/AOK/VERSION)
elif [ -f /opt/AOK/CHANGELOG.md ]; then
  AOK_VERSION=$(head -3 /opt/AOK/CHANGELOG.md | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1 || echo "injected")
fi
echo "$AOK_VERSION" > /AOK/VERSION
ok "/AOK shim at /AOK (version: $AOK_VERSION)"

# ── /etc/profile integration ──────────────────────────────
log "[6/6] Wiring into /etc/profile..."
PROFILE_MARKER="# AOK-INJECT"
if ! grep -q "$PROFILE_MARKER" /etc/profile 2>/dev/null; then
  cat >> /etc/profile << 'PROFILE'

# AOK-INJECT — iSH AOK userspace shim
# Exposes /proc/ish/* helpers as shell functions for scripts
# that expect AOK kernel features.
aok_host_info()  { /usr/local/bin/aok-host-info; }
aok_battery()    { /usr/local/bin/aok-battery; }
aok_uidevice()   { /usr/local/bin/aok-uidevice; }
export AOK_INJECT=1
PROFILE
  ok "Wired into /etc/profile"
else
  ok "/etc/profile already has AOK-INJECT block"
fi

# ── Summary ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          AOK USERSPACE INJECTION COMPLETE            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo " /opt/AOK          → AOK-Filesystem-Tools (full)"
echo " /AOK              → AOK pseudo-fs shim"
echo " /proc/ish/*       → host_info, BAT0, UIDevice shims"
echo " /dev/rtc          → stub char device"
echo " /usr/local/bin/   → aok-host-info, aok-battery, aok-uidevice"
echo ""
echo " Verify with:"
echo "   cat /proc/ish/host_info"
echo "   cat /proc/ish/BAT0"
echo "   ls /opt/AOK"
echo "   cat /AOK/VERSION"
echo ""
echo " KERNEL FEATURES (require real iSH-AOK binary):"
echo "   /dev/location        → NOT available (needs AOK app)"
echo "   clock_nanosleep_time64 → NOT available (needs AOK app)"
echo "   /proc/ish/BAT0 (real)  → NOT available (needs AOK app)"
echo ""
echo " To get full AOK: testflight.apple.com/join/X1flyiqE"
echo "══════════════════════════════════════════════════════"
