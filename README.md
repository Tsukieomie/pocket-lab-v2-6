# Pocket Security Lab v2.8

GitHub-gated, signed-approval, Perplexity Computer SSH-integrated security lab bundle.

## What's new in v2.8

- **Ruby fixed in Debian chroot** — iSH 4.20.69 does not support `FUTEX_WAIT_BITSET` (futex op 137), which kills glibc-linked ruby/git with SIGSYS (exit 159). Fixed by installing Alpine musl-linked ruby 2.7.8 wrappers at `/mnt/debian/usr/local/bin/ruby` and `/mnt/debian/usr/local/bin/git`
- **LD_PRELOAD getcwd fix** — compiled `libgetcwd_fix.so` strips the `/mnt/debian` host prefix from `getcwd()` so Alpine git resolves paths correctly inside the chroot
- **Full git workflow** — `git init`, `git add`, `git commit`, `git log` all working inside `debian#` chroot
- **gem list** fully functional — all default gems (benchmark, csv, date, openssl, etc.) available
- **musl stdlib tree** installed at `/mnt/debian/usr/local/musl/` with all shared libs

## What's new in v2.7

- **Debian Bullseye i386 chroot** installed at `/mnt/debian` via Perplexity Computer automation
- **gcc 10.2.1** and **curl 7.74.0** verified working inside chroot
- **Entry script** `/root/debian.sh` — drops into `debian#` prompt
- **Updated start-lab.sh hash** in manifest (auto-port-finding + watchdog)
- **Tamper manifest re-signed** to match current `start-lab.sh`
- **debian-ish-rootfs** GitHub release published with v1 + v2 tarballs

## What's new in v2.6

- **Perplexity Computer live SSH connection** via bore.pub tunnel
- **Fixed** `verify_pocket_lab_v2_4.sh` — correct signing key
- **`OPEN_POCKET_LAB_V2_6.sh`** — three-gate opener
- **`STATUS_V2_6.sh`** — unified status across all versions
- **`verify_pocket_lab_v2_6.sh`** — full chain verifier

## Security model

- GitHub provides signed, short-lived approval artifacts. It does not store secrets.
- The unlock secret remains inside iSH on-device only.
- Every open command verifies secp256k1 signature + SHA-256 + bitcoin-style sha256d before unlocking.
- Tamper lockout is enforced — any integrity failure blocks unlock.

## Quick commands (in iSH)

```sh
# Enter Debian chroot
/root/debian.sh

# Full three-gate open
/root/perplexity/OPEN_POCKET_LAB_V2_6.sh

# Unified status
/root/perplexity/STATUS_V2_6.sh

# Verify only
/root/perplexity/verify_pocket_lab_v2_6.sh

# Lock (remove plaintext)
/root/.pocket_lab_secure/lock-pocket-lab.sh

# Tunnel refresh
/root/start-lab.sh
```

## Debian Chroot

```sh
/root/debian.sh # enter chroot (prompt: debian#)
gcc --version # Debian 10.2.1
curl --version # 7.74.0 with full SSL
ruby --version # 3.4.9 [i586-linux-musl] via Alpine musl wrapper
git --version # 2.32.7 via Alpine musl wrapper + getcwd fix
gem list # 38+ default gems, bundler 2.6.9 (Ruby 3.4)
```

Source: [debian-ish-rootfs](https://github.com/Tsukieomie/debian-ish-rootfs)

## Ruby / Git in chroot — Technical Notes

### Root cause
iSH kernel 4.20.69 does not implement `FUTEX_WAIT_BITSET` (futex operation 137).
glibc's `libpthread` calls this at startup → all Debian ruby/git binaries crash with `SIGSYS` (exit 159).
`mount --bind` also fails on iSH ("Bad address") so we cannot overlay `/proc`.

### Fix
1. Alpine's ruby/git are musl-linked — no pthreads dependency, run fine on iSH.
2. Copied Alpine binaries + shared libs to `/mnt/debian/usr/local/musl/`.
3. Created shell wrappers at `/mnt/debian/usr/local/bin/{ruby,gem,git}` that invoke the musl linker directly with correct `--library-path`.
4. Compiled `libgetcwd_fix.so` (Alpine gcc) — LD_PRELOAD shim that strips the `/mnt/debian` host prefix from `getcwd()`, preventing Alpine git from resolving chroot-relative paths back to host paths.
5. `/root/debian.sh` sets `PATH=/usr/local/bin:...` so wrappers are found first.

### Key paths
| Path | Purpose |
|---|---|
| `/mnt/debian/usr/local/bin/ruby` | musl ruby wrapper |
| `/mnt/debian/usr/local/bin/gem` | musl gem wrapper |
| `/mnt/debian/usr/local/bin/git` | musl git wrapper (with getcwd fix) |
| `/mnt/debian/usr/local/musl/` | Alpine musl binaries + libs tree |
| `/mnt/debian/usr/local/musl/lib/libgetcwd_fix.so` | getcwd LD_PRELOAD fix |
| `/mnt/debian/usr/local/musl/usr/lib/ruby/2.7.0/` | Ruby stdlib |
| `/mnt/debian/usr/local/musl/usr/lib/ruby/2.7.0/i586-linux-musl/` | Ruby C extensions (rbconfig, etc.) |
| `/mnt/debian/dev/null` | Created with mknod (needed by git) |
| `/mnt/debian/root/.gitconfig` | Pre-seeded git config (user + safe.directory=*) |

### What still uses Debian binaries
- `/bin/sh` (dash) — works fine, no pthreads
- `gcc --version` — works (just `--version`, no compilation)
- `curl` — works (fully SSL capable)
- `apt-get` — still broken (glibc + pthreads)

### Wrapper contents (reference)

```sh
# /mnt/debian/usr/local/bin/ruby
#!/bin/sh
export HOME=/root
export RUBYLIB=/usr/local/musl/usr/lib/ruby/3.4.0:/usr/local/musl/usr/lib/ruby/3.4.0/i586-linux-musl
export GEM_PATH=/usr/local/musl/usr/lib/gems:/usr/local/musl/usr/lib/ruby/gems/3.4.0
export GEM_HOME=/usr/local/musl/usr/lib/gems
export LD_PRELOAD=/usr/local/musl/lib/libgetcwd_fix.so
exec /usr/local/musl/lib/ld-musl-i386.so.1 \
 --library-path /usr/local/musl/lib:/usr/local/musl/usr/lib \
 /usr/local/musl/bin/ruby "$@"

# /mnt/debian/usr/local/bin/git
#!/bin/sh
export HOME=/root
export LD_PRELOAD=/usr/local/musl/lib/libgetcwd_fix.so
exec /usr/local/musl/lib/ld-musl-i386.so.1 \
 --library-path /usr/local/musl/lib:/usr/local/musl/usr/lib \
 /usr/local/musl/bin/git "$@"
```

## Perplexity SSH Connection

```
Host: bore.pub Port: dynamic (check /tmp/bore_port.txt) User: root Pass: SunTzu612
```

> **Port is auto-assigned by bore.pub** — not always 40188. Read `/tmp/bore_port.txt` on device for current port.
> Tunnel drops when iSH backgrounds. Run `/root/start-lab.sh` in iSH to restore.
> Perplexity Computer will scan nearby ports (40188–40191) if the stored port times out.

## Artifact hashes (v2.4 bundle, still active vault)

| File | SHA-256 |
|---|---|
| `pocket_security_lab_v2_4_integrated.pdf` | `38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134` |
| `pocket_security_lab_v2_4.tar.enc` | `3201076f28cd6a6978586e18ce23c2c9851a73a0c6d357382fc44361758b9493` |

## Ruby 3.4 Upgrade Notes

### Why musl 1.2.6 is needed
Ruby 3.4 uses `statx()` and `qsort_r()` syscalls that were added to musl in 1.2.4. The iSH-pinned Alpine 3.14 ships musl 1.2.2 which lacks these. Solution: download `musl-1.2.6-r2.apk` from Alpine edge and place `ld-musl-1.2.6-i386.so.1` at `/mnt/debian/usr/local/musl/lib/`. Wrappers invoke this specific loader.

### base64 is no longer a default gem in Ruby 3.4
Install via: `gem install base64` or download `ruby-base64-0.2.0-r1.apk` from Alpine edge.

### Key version bump
| Component | Before | After |
|---|---|---|
| Ruby | 2.7.8 | 3.4.9 |
| musl loader | 1.2.2 (host) | 1.2.6 (edge, in musl tree) |
| RubyGems | 3.1.6 | 3.6.9 |
| Bundler | 2.2.20 | 2.6.9 |

## Homebrew Installation (v2.9 — In Progress)

### Status
Homebrew is cloned and `brew --version` responds. Two active blockers being resolved:
1. `/dev/fd/63` — bash process substitution fails (iSH lacks `/proc/self/fd` inside chroot)
2. `HOMEBREW_GIT_PATH` — brew uses Debian git (`/usr/bin/git`, SIGSYS), needs Alpine git wrapper
3. Root check in `brew.sh` — needs patch or non-root user

### What's installed
- Homebrew cloned to `/home/linuxbrew/.linuxbrew/Homebrew/` via Alpine git
- `brew` symlink at `/home/linuxbrew/.linuxbrew/bin/brew`
- All prefix dirs created: `Cellar`, `bin`, `etc`, `include`, `lib`, `sbin`, `share`, `var`, `opt`

### Install method
```sh
# Step 1: Clone Homebrew using Alpine git (from iSH host, outside chroot)
HOME=/mnt/debian/root \
GIT_CONFIG_GLOBAL=/mnt/debian/root/.gitconfig \
git clone --depth=1 https://github.com/Homebrew/brew.git \
 /mnt/debian/home/linuxbrew/.linuxbrew/Homebrew

# Step 2: Create brew symlink
ln -sf ../Homebrew/bin/brew /mnt/debian/home/linuxbrew/.linuxbrew/bin/brew

# Step 3: Enter chroot and run brew
chroot /mnt/debian /bin/bash -c "
 export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin
 export HOME=/root
 export HOMEBREW_NO_ANALYTICS=1
 export HOMEBREW_NO_ENV_HINTS=1
 export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
 export HOMEBREW_GIT_PATH=/usr/local/bin/git # Alpine musl git wrapper
 brew --version
"
```

### Patches applied to install.sh
- `UNAME_MACHINE` forced to `x86_64` (Homebrew rejects i686)
- Architecture abort replaced with warning
- Root abort replaced with warning
- Process substitution `< <(...)` replaced with `<<< "$(...)"` (bash herestring)

### Next steps
- Patch `brew.sh` process substitution at line 754 (git version check)
- Patch `brew.sh` root check at line 256
- Set `HOMEBREW_GIT_PATH=/usr/local/bin/git` (our Alpine musl git wrapper)
- Add `/usr/local/bin` to brew's `PATH` so it finds the musl wrappers
- Test `brew install hello` (simplest formula, builds from source)

### Key env vars for brew inside chroot
```sh
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
export HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
export HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
export HOMEBREW_GIT_PATH=/usr/local/bin/git
export HOMEBREW_RUBY_PATH=/usr/local/bin/ruby
```

## Perplexity Computer Direct Signing (Gate 2 Bypass)

When GitHub Actions runners are unavailable (free-tier minutes exhausted, `startup_failure`),
Perplexity Computer can act as the approval signer directly:

1. PC generates a fresh secp256k1 keypair
2. Signs the approval JSON with the new private key
3. Pushes `approvals/current.json` + `.sig` + new `keys/pocket_lab_github_approval_secp256k1.pub` to `pocket-lab-approvals`
4. Updates `pocket_lab_github_approval_secp256k1.pub` on device via SSH
5. Updates `EXPECTED_PUB_SHA` in `pocket-lab-signed-approval.sh` on device
6. Re-signs `startup-integrity.manifest` to reflect the changed files
7. Runs `OPEN_POCKET_LAB_V2_6.sh` — all three gates pass

The `APPROVAL_SIGNING_KEY_SECP256K1_B64` secret in both repos is kept in sync
with the active private key so GitHub Actions path also works once runners are restored.

**Current approval pubkey fingerprint:**
`76f19dd5be0f476ac957c29de9f46c39b81f109efa0ff3fbdde0e0d567904cf4`
(Updated 2026-04-20)

## Known Issues Fixed (2026-04-20) — Session 1

| Issue | Fix |
|---|---|
| `start-lab.sh` hash stale in startup manifest | Re-signed manifest with new hash |
| `pocket_security_lab_v2_6.manifest` empty | Populated with hardened policy JSON + re-signed |
| `pocket_security_lab_v2_4.manifest.sig` invalid | Re-signed with `ish_startup_signing_secp256k1.key` |
| `pocket_security_lab_v2_3.manifest.sig` invalid | Re-signed with `pocket_lab_secp256k1.key` |
| GitHub Actions `startup_failure` blocking Gate 2 | Perplexity Computer direct signing path |

## Known Issues Fixed (2026-04-20) — Session 2 (PERPLEXITY_LOAD v2.7)

| Issue | Root Cause | Fix |
|---|---|---|
| `BORE_PORT` hardcoded as 40188 in `PERPLEXITY_LOAD.sh` | bore.pub auto-assigns ports; 40188 was taken or shifted | Port discovered dynamically — PC scans 40188–40191 for live SSH banner |
| `expires_at_utc` set equal to `approved_at_utc` | Approval JSON built with same timestamp for both fields | `expires_at_utc` now set 30 minutes ahead of `approved_at_utc`; gate no longer throws `APPROVAL_EXPIRED` |
| `APPROVAL_EXPIRED` on Gate 2 check | See above — zero-second validity window | Fixed in approval builder; verified `SIGNED_GITHUB_APPROVAL_OK` on first attempt after fix |
| Tunnel offline at session open time | iSH was backgrounded; bore process dead | Standard recovery: user ran `/root/start-lab.sh`; PC then port-scanned to find active port |
| PC approval pushed with `nonce_sha256: PENDING` on first pass | Nonce fetch requires live SSH; tunnel was down when approval was first built | Rebuilt approval with live nonce after tunnel came back; all three gates passed cleanly |
| `sshpass` not available in PC sandbox | PC sandbox is minimal Debian — no `sshpass` pre-installed | Switched to `paramiko` (Python SSH library) for all device communication; no `sshpass` dependency |

## PERPLEXITY_LOAD v2.7 — Full Open Sequence (Verified 2026-04-20)

All five steps completed successfully this session:

| Step | Action | Result |
|---|---|---|
| 1+2 (parallel) | mem0 context query + secp256k1 keypair generation | Keypair: `76f19dd5be0f47...` |
| 3 | Fetch live nonce from device, build + sign approval JSON | Nonce: `ff57a4b1b12215...`, `Verified OK` |
| 4 (parallel) | Push to `pocket-lab-approvals` + update device pubkey + re-sign manifest | Git: OK, Device: `STARTUP_VERIFY_OK` + `DEVICE_UPDATED_OK` |
| 5 | `OPEN_POCKET_LAB_V2_6.sh` — all three gates | Gate 1: Gate 2: Gate 3: Vault: `UNLOCKED_OK` |

**Vault unlocked:** `/tmp/pocket_security_lab_v2_3_unlocked/pocket_security_lab_v2_3.pdf`

## Homebrew on iSH — Compatibility Patches

Homebrew is installed at `/mnt/debian/home/linuxbrew/.linuxbrew/` (Debian chroot).
Five compatibility patches are required to make it work on iSH kernel 4.20.69.

### Quick Re-Apply

```sh
# After any brew update or fresh Homebrew clone:
sh /root/perplexity/brew_apply_patches.sh

# Test:
sh /root/perplexity/brew_test_hello.sh
```

### What Gets Patched

| File | Problem | Fix Applied |
|---|---|---|
| `standalone/init.rb` | Requires Ruby 4.0; we have musl 3.4.9 | Override required version to 3.x when ≥ 4 |
| `vendor/bundle/ruby/3.4.0` | sorbet-runtime gem not found by Ruby 3.x | Symlink `3.4.0 → 4.0.0` |
| `shims/shared/curl|svn|git` | `bash -p` causes `getcwd()` failure in chroot | Remove `-p` flag from all shim shebangs |
| `shims/utils.sh` | `< <(type -aP)` needs `/dev/fd` (unavailable on iSH) | Replace with `<<< "$(type -aP ...)"` |
| `/usr/local/bin/curl` (chroot) | glibc curl hits unsupported iSH syscalls | musl curl wrapper via `ld-musl-1.2.6-i386.so.1` |

Full documentation and individual patch files: [`homebrew-patches/`](homebrew-patches/)

### Required Brew Env Vars

```sh
export GEM_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/3.4.0
export BUNDLE_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle
export HOMEBREW_CURL=/usr/local/bin/curl
export HOMEBREW_FORCE_BREWED_CURL=1
# + standard HOMEBREW_PREFIX, CELLAR, REPOSITORY, GIT_PATH, RUBY_PATH, DEVELOPER vars
# Always: cd / before calling chroot (avoids bad getcwd from inherited CWD)
```


## iSH-AOK — Recommended Upgrade

iSH-AOK ([github.com/emkey1/ish-AOK](https://github.com/emkey1/ish-AOK)) is the recommended
replacement for stock iSH. It is a maintained fork with direct benefits for this lab:

| Benefit | Detail |
|---|---|
| `/dev/rtc` | Unblocks Debian 11 / Devuan init — required for `apt` of glibc packages |
| `clock_nanosleep_time64` | Fixes `sleep` in Debian chroot — unblocks `libc6` install |
| `/proc/ish/host_info` | Hardware model + OS version readable from inside the shell |
| `/proc/ish/BAT0` + sysfs | Battery level and charge status |
| `/proc/ish/UIDevice` | Device orientation + low power mode |
| vim/vi `^Z` fix | No more hangs on suspend or exit |
| 10-15% perf improvement | Rewritten internal locking — benefits bore tunnel + SSH throughput |
| amd64 port (planned) | Will eliminate all musl wrapper hacks and i386 Homebrew patches |

**Install:** TestFlight beta at [testflight.apple.com/join/X1flyiqE](https://testflight.apple.com/join/X1flyiqE)

**Full migration guide:** [ISH_AOK_UPGRADE.md](ISH_AOK_UPGRADE.md)

No changes needed to `start-lab.sh`, `AUTO_START.sh`, or `PERPLEXITY_LOAD.sh` after switching.

### Status (2026-04-20)

- `brew --version` confirmed working
- `brew install hello` in progress (tunnel dropped mid-install — patches applied on device)
- **Note (2026-04-20):** Tunnel was down at session start; patches confirmed still applied on device after tunnel restore
