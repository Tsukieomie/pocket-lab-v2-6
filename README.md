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
/root/debian.sh       # enter chroot (prompt: debian#)
gcc --version         # Debian 10.2.1
curl --version        # 7.74.0 with full SSL
ruby --version        # 3.4.9 [i586-linux-musl] via Alpine musl wrapper
git --version         # 2.32.7 via Alpine musl wrapper + getcwd fix
gem list              # 38+ default gems, bundler 2.6.9 (Ruby 3.4)
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
Host: bore.pub  Port: 40188  User: root  Pass: SunTzu612
```

> Tunnel drops when iSH backgrounds. Run `/root/start-lab.sh` in iSH to restore.

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
