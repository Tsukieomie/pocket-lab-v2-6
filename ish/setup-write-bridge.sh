#!/bin/sh
# setup-write-bridge.sh — create a writable bridge into the iSH app-group
# container so output written from the Alpine side actually persists in iOS
# and is visible to the iSH "Files" provider.
#
# Background: on iSH, /mnt/ios is the iOS file system bridge. Many paths
# under /mnt/ios/private/var/{mobile,tmp} are mounted read-write but iOS
# sandboxing returns "Operation not permitted" on actual writes. The iSH
# app group container under
#   /mnt/ios/private/var/mobile/Containers/Shared/AppGroup/<UUID>
# *is* writable because the iSH app owns it.
#
# This script discovers that path (the UUID is device/runtime-specific —
# never hard-coded), creates a PocketLabWriteBridge/{inbox,outbox,logs}
# tree, drops a README.txt, and links it as /root/ios-write and
# <repo>/ios-write for convenience. It self-tests with a marker file
# create/read/delete.
#
# Idempotent. Safe to re-run. Refuses to write to protected iOS system
# paths. No secrets, no live ports.

set -eu

APPGROUP_ROOT="/mnt/ios/private/var/mobile/Containers/Shared/AppGroup"
BRIDGE_NAME="PocketLabWriteBridge"
LINK_HOME="/root/ios-write"

log()  { printf '[setup-write-bridge] %s\n' "$*"; }
warn() { printf '[setup-write-bridge] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup-write-bridge] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Locate the writable app-group container.
#
# Strategy, in order:
#   a) If /mnt/ios mount source already points inside an AppGroup UUID,
#      derive the UUID from it.
#   b) Otherwise scan APPGROUP_ROOT for entries that contain the iSH
#      Alpine root layout (`roots/*/data` is a strong signal).
#   c) As a last resort, accept the first writable UUID-shaped directory.
# ---------------------------------------------------------------------------

discover_appgroup_uuid() {
    # (a) derive from mount source
    if [ -r /proc/mounts ]; then
        src=$(awk '$2 == "/mnt/ios" {print $1; exit}' /proc/mounts 2>/dev/null || true)
        case "$src" in
            */AppGroup/*)
                uuid=$(printf '%s\n' "$src" \
                    | sed -n 's#.*/AppGroup/\([^/][^/]*\).*#\1#p')
                if [ -n "$uuid" ] && [ -d "$APPGROUP_ROOT/$uuid" ]; then
                    printf '%s\n' "$uuid"
                    return 0
                fi
                ;;
        esac
    fi

    [ -d "$APPGROUP_ROOT" ] || return 1

    # (b) prefer a UUID dir that looks like an iSH roots store
    for d in "$APPGROUP_ROOT"/*/; do
        [ -d "$d" ] || continue
        for r in "$d"roots/*/data; do
            [ -d "$r" ] || continue
            uuid=$(basename "${d%/}")
            printf '%s\n' "$uuid"
            return 0
        done
    done

    # (c) fallback: first writable UUID-shaped dir
    for d in "$APPGROUP_ROOT"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "${d%/}")
        case "$name" in
            [0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*)
                if [ -w "$d" ] 2>/dev/null; then
                    printf '%s\n' "$name"
                    return 0
                fi
                ;;
        esac
    done

    return 1
}

# Refuse to operate on known-protected iOS roots even if asked.
guard_protected() {
    case "$1" in
        /mnt/ios/private/var/tmp|/mnt/ios/private/var/tmp/*)
            die "refusing to write into protected path: $1" ;;
        /mnt/ios/private/var/mobile|/mnt/ios/private/var/mobile/Library*|/mnt/ios/private/var/mobile/Documents*|/mnt/ios/private/var/mobile/Media*)
            die "refusing to write into protected path: $1" ;;
    esac
}

if [ ! -d "$APPGROUP_ROOT" ]; then
    die "$APPGROUP_ROOT not found — are we running inside iSH with /mnt/ios mounted?"
fi

UUID=$(discover_appgroup_uuid) || die "could not discover writable app-group UUID under $APPGROUP_ROOT"
APPGROUP_DIR="$APPGROUP_ROOT/$UUID"
BRIDGE_DIR="$APPGROUP_DIR/$BRIDGE_NAME"

guard_protected "$BRIDGE_DIR"
log "discovered app-group: $APPGROUP_DIR"
log "bridge target:        $BRIDGE_DIR"

# ---------------------------------------------------------------------------
# 2. Create the bridge tree (idempotent).
# ---------------------------------------------------------------------------
for sub in "" inbox outbox logs; do
    target="$BRIDGE_DIR${sub:+/$sub}"
    if [ ! -d "$target" ]; then
        mkdir -p "$target" || die "mkdir failed for $target"
        log "created $target"
    fi
done

README="$BRIDGE_DIR/README.txt"
cat > "$README" <<'EOF'
PocketLabWriteBridge
====================

This directory lives inside the iSH iOS app-group container — one of the
few paths writable from Alpine via /mnt/ios. Use it for any file that
needs to leave the iSH chroot/Alpine root and be readable by other iOS
apps (Files, Shortcuts, etc).

Conventions
-----------
  inbox/   Files dropped by iOS / other apps for Alpine to pick up.
  outbox/  Files Alpine produces for iOS / other apps to pick up.
  logs/    Long-running log output that should survive reboots.

Access from Alpine
------------------
  /root/ios-write                  -> this directory (symlink)
  <repo>/ios-write                 -> this directory (symlink, if repo present)

The app-group UUID this lives under is device- and install-specific. Do
not hard-code it; rerun ish/setup-write-bridge.sh on each device to
(re)discover and (re)link it.
EOF
log "wrote $README"

# ---------------------------------------------------------------------------
# 3. (Re)create the convenience symlinks.
# ---------------------------------------------------------------------------
relink() {
    link=$1
    dest=$2
    parent=$(dirname "$link")
    [ -d "$parent" ] || mkdir -p "$parent"
    if [ -L "$link" ]; then
        cur=$(readlink "$link" || true)
        if [ "$cur" = "$dest" ]; then
            log "symlink already correct: $link -> $dest"
            return 0
        fi
        rm -f "$link"
    elif [ -e "$link" ]; then
        warn "$link exists and is not a symlink — leaving it alone"
        return 0
    fi
    ln -s "$dest" "$link"
    log "linked $link -> $dest"
}

relink "$LINK_HOME" "$BRIDGE_DIR"

# Repo-local link: only create when an obvious repo dir exists.
REPO_DIR=${POCKET_LAB_REPO:-/root/pocket-lab-v2-6}
if [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/README.md" ]; then
    relink "$REPO_DIR/ios-write" "$BRIDGE_DIR"
else
    log "repo dir $REPO_DIR not found — skipping repo symlink (set POCKET_LAB_REPO to override)"
fi

# ---------------------------------------------------------------------------
# 4. Self-test: create -> read -> delete a marker.
# ---------------------------------------------------------------------------
MARKER="$BRIDGE_DIR/.write-test-$$"
EXPECTED="pocket-lab-write-bridge-ok"
if ! printf '%s\n' "$EXPECTED" > "$MARKER" 2>/dev/null; then
    die "write test failed: cannot create $MARKER"
fi
got=$(cat "$MARKER" 2>/dev/null || true)
if [ "$got" != "$EXPECTED" ]; then
    rm -f "$MARKER" 2>/dev/null || true
    die "read-back test failed: expected '$EXPECTED', got '$got'"
fi
if ! rm -f "$MARKER"; then
    die "delete test failed: cannot remove $MARKER"
fi
log "self-test ok: create/read/delete succeeded under $BRIDGE_DIR"

log "done. Use \$LINK_HOME or <repo>/ios-write to write files iOS can see."
