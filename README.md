# Pocket Security Lab v2.8

GitHub-gated, signed-approval, Perplexity Computer SSH-integrated security lab bundle.

---

## What's new in v2.8

### Performance (2026-04-21)
- **Open time: ≤15s** (was ~40-60s) — see [Performance](#performance--timing)
- **SSH ControlMaster** — persistent channel opened at `AUTO_START` boot; all subsequent SSH calls pay ~50ms RTT instead of ~2s handshake
- **Device pubkey deploy moved to `AUTO_START`** — startup manifest re-signed once at boot, not on every open; removes largest serial block from the hot path
- **Gate 2 reads local file** — approval JSON passed inline via SSH heredoc; eliminates flaky GitHub raw propagation race and 1–5s GitHub fetch on every open
- **Gate 1 sentinel** — `/tmp/.startup-verified-<boot_id>` set at boot; skipped on open if present
- **GitHub publish async** — Contents API PUT fires in background after lab opens (no git clone in hot path)
- **Single python3 invocation** — JSON build + sign + verify collapsed from 5 calls to 1
- **`pocket_lab.sh`** — unified entrypoint: `open`, `lock`, `status`, `verify`, `tunnel up/down`, `mem0 sync/save`, `rotate-key`, `boot`
- **`mem0.sh`** — shared library: structured JSON event saves, bulk query, rotation ledger

### Security (2026-04-21)
- **`schema/pins.json`** — single source of truth for `pdf_sha256`, `approval_pubkey_sha256`, TTL, key history
- **`signature_algorithm` pinned** — Gate 2 now asserts `ECDSA-secp256k1-SHA256`; silent algorithm substitution blocked
- **SSH key auth** — `PERPLEXITY_LOAD.sh` reads `SSH_KEY_PATH` from `/root/.bore_env`; hardcoded password removed from repo
- **WireGuard-native tunnel** — `BORE_HOST`/`BORE_PORT`/`BORE_SECRET` sourced from `/root/.bore_env`; bore.pub is fallback only
- **`EXPIRES_AT` bug fixed** — was `= now` (zero-second window); now `+5 min` (open) / `+30 min` (pre-sign)
- **Approval key rotation ledger** — `pocket-lab-approvals/approvals/.rotation-history` append-only chain

### Chroot / Toolchain (2026-04-20 → 2026-04-21)
- **Ruby fixed in Debian chroot** — iSH 4.20.69 does not support `FUTEX_WAIT_BITSET` (futex op 137); fixed with Alpine musl-linked ruby 3.4.9 wrappers
- **LD_PRELOAD getcwd fix** — `libgetcwd_fix.so` strips `/mnt/debian` host prefix from `getcwd()`
- **Full git workflow** — `git init`, `git add`, `git commit`, `git log` all working inside `debian#` chroot
- **Homebrew compatibility patches** — 5 patches; `brew --version` works; `brew install hello` in progress

---

## Quick start (iSH)

```sh
# Unified entrypoint (v2.8)
sh /root/perplexity/pocket_lab.sh open      # 3-gate open (≤15s)
sh /root/perplexity/pocket_lab.sh status    # system status
sh /root/perplexity/pocket_lab.sh lock      # wipe plaintext
sh /root/perplexity/pocket_lab.sh tunnel up # start/check tunnel
sh /root/perplexity/pocket_lab.sh mem0 sync # display AI context
sh /root/perplexity/pocket_lab.sh help      # all commands

# Boot sequence (run when iSH starts — warms everything for fast open)
sh /root/perplexity/AUTO_START.sh

# Direct openers (still available)
sh /root/perplexity/OPEN_POCKET_LAB_V2_6.sh   # on-device 3-gate open
sh /root/perplexity/PERPLEXITY_LOAD.sh        # Perplexity Computer fast open (≤15s)
```

---

## Performance / Timing

| Phase | v2.7 | v2.8 | Saving |
|---|---:|---:|---:|
| SSH handshakes (3×) | ~6s | ~0.15s (ControlMaster) | ~6s |
| Device pubkey deploy | ~9s | 0s (done at boot) | ~9s |
| GitHub fetch in Gate 2 | ~3s | 0s (local file) | ~3s |
| git clone + push | ~7s | 0s (async API) | ~7s |
| python3 cold-starts (5×) | ~2.5s | ~0.5s (1×) | ~2s |
| Gate 1 (duplicate) | ~1.5s | 0s (sentinel) | ~1.5s |
| **Total warm** | **~28s** | **~5s** | **~23s** |
| **Total cold** | **~50s** | **~14s** | **~36s** |

**Critical path (warm):** Step 1 nonce fetch (~1.5s) → Step 2 sign (~0.5s) → Step 3 SSH heredoc open (~3.5s) = **~5.5s**

### What `AUTO_START.sh` pre-warms at boot (not user-visible)
1. Starts bore tunnel + sshd (skipped if already running)
2. Opens SSH ControlMaster persistent channel
3. Generates secp256k1 keypair + pre-signs approval (30-min window)
4. Fetches mem0 context → `/tmp/mem0_context.txt`
5. Deploys new pubkey to device + re-signs startup manifest (only if pubkey changed)
6. Sets `/tmp/.startup-verified-<boot_id>` sentinel on device

---

## Security model

- GitHub provides signed, short-lived approval artifacts. It does not store secrets.
- The unlock secret remains inside iSH on-device only.
- Every open verifies secp256k1 signature + SHA-256 + bitcoin-style sha256d before unlocking.
- Tamper lockout enforced — any integrity failure blocks unlock and alerts.
- `schema/pins.json` is the single source of truth for all cryptographic pins.

### Three-gate unlock chain

| Gate | Check | Script |
|---|---|---|
| Gate 1 | Startup manifest integrity + tamper alert (skipped via boot sentinel) | `startup-verify.sh` + `tamper-alert.sh` |
| Gate 2 | secp256k1 ECDSA signature + nonce + expiry + PDF hash + algorithm pin (local file, no GitHub fetch) | `pocket-lab-signed-approval.sh --local` |
| Gate 3 | v2.4 PDF sha256 + v2.6 manifest signature + policy fields | `verify_pocket_lab_v2_6.sh` |

### Approval schema (v1, signed)

```json
{
  "schema": "pocket_lab_signed_approval_v1",
  "approved": true,
  "pdf_sha256": "<see pins.json>",
  "nonce_sha256": "<sha256 of one-time nonce>",
  "approved_by": "<actor>",
  "approved_at_utc": "<ISO8601>",
  "expires_at_utc": "<ISO8601, +5 min from open>",
  "repo": "Tsukieomie/pocket-lab-approvals",
  "run_id": "<run id>",
  "approval_pubkey_sha256": "<sha256 of DER-encoded pubkey>",
  "signature_algorithm": "ECDSA-secp256k1-SHA256"
}
```

### Gate 2 signing paths

| Path | When | How |
|---|---|---|
| **Path A** (preferred) | GitHub Actions runners available | Workflow dispatch → signed `approvals/current.json` pushed to `pocket-lab-approvals` |
| **Path B** (fallback) | Runners unavailable or `PERPLEXITY_LOAD.sh` fast-open | Perplexity Computer generates keypair, signs locally, pushes async |

Key rotations are logged in [`pocket-lab-approvals/approvals/.rotation-history`](https://github.com/Tsukieomie/pocket-lab-approvals/blob/main/approvals/.rotation-history).

---

## Configuration — `/root/.bore_env`

All tunnel, SSH, and token config lives in `/root/.bore_env` (not committed to any repo).

```sh
# /root/.bore_env — set these on device
BORE_HOST=<your-vps-ip-or-wireguard-ip>   # or bore.pub (fallback)
BORE_PORT=2222                             # SSH tunnel port
BORE_SECRET=<bore-shared-secret>           # if self-hosted bore
SSH_KEY_PATH=/root/.ssh/pocket_lab_ed25519 # preferred over password
SSH_PASS=<password>                        # legacy fallback only
GH_TOKEN=<github-pat>                      # enables async Contents API publish
MEM0_API_KEY=<mem0-api-key>               # in /root/.mem0_env (separate file)
```

> **No passwords or tokens are committed to this repo.** All secrets live in `/root/.bore_env` and `/root/.mem0_env` on-device only.

### WireGuard tunnel (recommended)

Self-hosted bore over WireGuard VPS — faster, private, survives iOS backgrounding.
Setup script: [`pocket-lab-approvals/setup-secure-tunnel.sh`](https://github.com/Tsukieomie/pocket-lab-approvals/blob/main/setup-secure-tunnel.sh)

```
iPhone WireGuard App ══WG Tunnel══▶ Oracle VPS ──bore──▶ :2222 (SSH to iSH)
Perplexity Computer ──────────────────────────────────▶ VPS_IP:2222
```

---

## Device-side patch (one-time, after pulling)

```sh
# Adds --local mode to pocket-lab-signed-approval.sh
# Required for Gate 2 inline verify in PERPLEXITY_LOAD.sh v2.8
sh /root/perplexity/device-patches/apply-local-mode.sh
```

---

## Artifact hashes (v2.4 bundle — active vault)

| File | SHA-256 |
|---|---|
| `pocket_security_lab_v2_4_integrated.pdf` | `38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134` |
| `pocket_security_lab_v2_4.tar.enc` | `3201076f28cd6a6978586e18ce23c2c9851a73a0c6d357382fc44361758b9493` |

Current approval pubkey fingerprint: see [`schema/pins.json`](schema/pins.json) — `approval_pubkey_sha256`.

---

## mem0 integration

`AUTO_START.sh` reads and writes operational context to mem0 (`agent_id=pocket-lab`).

```sh
# Session context loaded at boot into /tmp/mem0_context.txt
# Categories: bypass / keys / issues / infra / ai

# Manual sync
sh /root/perplexity/pocket_lab.sh mem0 sync   # query + display
sh /root/perplexity/pocket_lab.sh mem0 save   # save current state snapshot
```

Config: `MEM0_API_KEY` in `/root/.mem0_env`.

---

## Debian chroot

```sh
/root/debian.sh         # enter chroot (prompt: debian#)
gcc --version           # Debian 10.2.1
curl --version          # 7.74.0 with SSL
ruby --version          # 3.4.9 [i586-linux-musl] via Alpine musl wrapper
git --version           # 2.32.7 via musl wrapper + getcwd fix
gem list                # 38+ default gems
```

Source: [debian-ish-rootfs](https://github.com/Tsukieomie/debian-ish-rootfs)

### Root cause + fix

iSH kernel 4.20.69 does not implement `FUTEX_WAIT_BITSET` (futex op 137). glibc's `libpthread` calls this at startup — all Debian ruby/git binaries crash with `SIGSYS` (exit 159).

**Fix:** Alpine musl-linked binaries + libs copied to `/mnt/debian/usr/local/musl/`. Shell wrappers at `/mnt/debian/usr/local/bin/{ruby,gem,git}` invoke the musl linker directly. `libgetcwd_fix.so` (LD_PRELOAD) strips the `/mnt/debian` host prefix from `getcwd()`.

| Path | Purpose |
|---|---|
| `/mnt/debian/usr/local/bin/ruby` | musl ruby wrapper |
| `/mnt/debian/usr/local/bin/git` | musl git wrapper (with getcwd fix) |
| `/mnt/debian/usr/local/musl/lib/libgetcwd_fix.so` | getcwd LD_PRELOAD shim |
| `/mnt/debian/usr/local/musl/` | Alpine musl binaries + libs tree |

---

## Homebrew on iSH

`brew --version` works. `brew install hello` in progress.

```sh
sh /root/perplexity/brew_apply_patches.sh   # re-apply after brew update
sh /root/perplexity/brew_test_hello.sh      # test
```

5 patches required — see [`homebrew-patches/`](homebrew-patches/).

| Problem | Fix |
|---|---|
| `RuntimeError: must be run under Ruby 4.0` | Patch `standalone/init.rb` to accept ≥ 3.x |
| `cannot load such file -- sorbet-runtime` | Symlink `ruby/3.4.0 → 4.0.0` |
| `getcwd() failed` in shims | Remove `-p` from shim shebangs |
| `/dev/fd/63: No such file` | Replace `< <(cmd)` with `<<< "$(cmd)"` |
| `curl SIGSYS` | musl curl wrapper via `ld-musl-1.2.6-i386.so.1` |

---

## iSH-AOK — Recommended upgrade

[iSH-AOK](https://github.com/emkey1/ish-AOK) is a maintained iSH fork with direct benefits for this lab.

| Benefit | Detail |
|---|---|
| `/dev/rtc` | Unblocks Debian 11 init / `apt` of glibc packages |
| `clock_nanosleep_time64` | Fixes `sleep` in Debian chroot |
| 10–15% performance | Benefits bore tunnel + SSH throughput |
| amd64 port (planned) | Eliminates all musl wrapper hacks + i386 Homebrew patches |

**Install:** [testflight.apple.com/join/X1flyiqE](https://testflight.apple.com/join/X1flyiqE)
**Guide:** [ISH_AOK_UPGRADE.md](ISH_AOK_UPGRADE.md)

No changes to `AUTO_START.sh` or `PERPLEXITY_LOAD.sh` needed after switching.

---

## Version history

| Version | Key changes |
|---|---|
| **v2.8** | ≤15s open, ControlMaster, async GitHub publish, Gate 2 local, pins.json, mem0.sh, pocket_lab.sh, SSH key auth, EXPIRES_AT fix |
| **v2.7** | AUTO_START pre-sign, single mem0 batch fetch, delta-only saves, parallel keypair+mem0 |
| **v2.6** | Perplexity Computer SSH, secp256k1 signed approvals, three-gate opener, verify_v2_6 |
| **v2.5** | GitHub-gated approvals (unsigned JSON), iSH nonce+fetch+verify flow |
| **v2.4** | Encrypted bundle (tar.enc), PDF+manifest+sig, tamper lockout |
| **v2.3** | Base encrypted vault |

---

## Known issues fixed

| Session | Issue | Fix |
|---|---|---|
| 2026-04-21 | `EXPIRES_AT` = `now` (zero-second TTL) | Fixed to `+5m` open / `+30m` pre-sign |
| 2026-04-21 | `SSH_PASS` hardcoded in repo | Removed; sourced from `/root/.bore_env` |
| 2026-04-21 | Three conflicting pubkey fingerprints | Consolidated in `schema/pins.json` |
| 2026-04-21 | bore.pub hardcoded in scripts | Scripts source `/root/.bore_env`; bore.pub is fallback |
| 2026-04-20 | `startup_failure` on GitHub Actions | Perplexity Computer direct signing (Path B) |
| 2026-04-20 | `BORE_PORT` hardcoded | Dynamic port discovery 40188–40191 |
| 2026-04-20 | `APPROVAL_EXPIRED` on Gate 2 | EXPIRES_AT set 30 min ahead (now fixed to +5m proper) |
