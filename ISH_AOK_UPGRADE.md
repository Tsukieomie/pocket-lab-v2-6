# iSH-AOK Upgrade Guide — Pocket Lab v2.6

**Source:** [github.com/emkey1/ish-AOK](https://github.com/emkey1/ish-AOK)
**TestFlight:** [testflight.apple.com/join/X1flyiqE](https://testflight.apple.com/join/X1flyiqE)
**Why:** iSH-AOK is an actively maintained fork of iSH with hardware access, syscall fixes,
stability improvements, and a concrete amd64 port plan — all directly relevant to this lab.

---

## What iSH-AOK Fixes That Affects Us

| Current Pain Point | iSH-AOK Fix |
|---|---|
| Debian `sleep` fails during `apt`/`libc6` install | `clock_nanosleep_time64` (syscall 407) implemented |
| `/dev/rtc` missing — Devuan/Debian 11 distros refuse to start properly | `/dev/rtc` with `ioctl() RTC_RD_TIME` implemented |
| `brew install hello` stalled (tunnel dropped mid-install) | 10–15% perf gain from rewritten locking; more stable under load |
| No visibility into battery / device state from inside iSH | `/proc/ish/BAT0`, `/sys/class/power_supply/BAT0`, `/proc/ish/UIDevice` |
| No host hardware info from inside the shell | `/proc/ish/host_info` — OS name, release, hardware model |
| vim/vi hangs on `^Z` or exit | Fixed in build 508 |
| Port hijacking on bore.pub (another user grabbed 40188) | Unrelated to AOK — see TUNNEL_UPGRADE.md for self-hosted bore |
| musl wrapper hacks for Ruby/git in Debian chroot | Long-term: amd64 port removes need for all i386 musl workarounds |

---

## New `/proc/ish` Entries Available in AOK

```sh
# Host hardware and OS info
cat /proc/ish/host_info
# Host OS Name: Darwin
# Host OS Release: 23.x.x
# Host Hardware: iPhone / iPad model

# Battery status
cat /proc/ish/BAT0
# or via standard sysfs path:
cat /sys/class/power_supply/BAT0/capacity
cat /sys/class/power_supply/BAT0/status   # Charging / Discharging / Full

# Device orientation + low power mode
cat /proc/ish/UIDevice

# Real-time clock (required by Debian 11 / Devuan)
# /dev/rtc — present and functional
```

These can be queried by `AUTO_START.sh` and written to mem0 on boot for
richer context. See "AUTO_START Integration" below.

---

## Migration Steps

### Step 1 — Install iSH-AOK via TestFlight

1. Open [testflight.apple.com/join/X1flyiqE](https://testflight.apple.com/join/X1flyiqE) on your iPhone
2. Accept the iSH-AOK beta invitation
3. TestFlight installs iSH-AOK alongside (or replacing) standard iSH

> iSH-AOK uses the same filesystem location as iSH. Back up your rootfs first
> if you want to keep both:
> ```sh
> # In iSH before switching — from iOS Files app, copy the iSH folder
> # Or: tar -czf /tmp/rootfs-backup.tar.gz / --exclude=/proc --exclude=/sys
> ```

### Step 2 — Verify AOK features are active

```sh
# Should return hardware info
cat /proc/ish/host_info

# Should show RTC device
ls -la /dev/rtc

# Should show battery
cat /proc/ish/BAT0
```

### Step 3 — Run start-lab.sh as normal

No changes needed to `start-lab.sh`, `AUTO_START.sh`, or `PERPLEXITY_LOAD.sh`.
iSH-AOK is fully backward compatible with Alpine apk and existing scripts.

### Step 4 — Optionally update AUTO_START.sh mem0 boot message

The boot snapshot written to mem0 can now include richer device data:

```sh
# Add to AUTO_START.sh Step 4 (Lab Status):
HOST_INFO=$(cat /proc/ish/host_info 2>/dev/null | tr '\n' ' ' || echo "N/A")
BAT=$(cat /proc/ish/BAT0 2>/dev/null | head -2 | tr '\n' ' ' || echo "N/A")
```

Then include `HOST_INFO` and `BAT` in the `BOOT_MSG` saved to mem0.

---

## Debian Chroot Improvements with AOK

The two blockers for Debian in our chroot were:

1. **`sleep` command fails** — `libc6` install hangs because `sleep` calls
   `clock_nanosleep_time64` (syscall 407), which stock iSH does not implement.
   iSH-AOK adds this syscall — Debian `sleep` works.

2. **`/dev/rtc` missing** — Debian 11 / Devuan init scripts probe `/dev/rtc`
   on startup and fail without it. iSH-AOK adds a working `/dev/rtc`.

With both fixed, `apt-get install` of glibc-linked packages that previously
failed (including `libc6`) should work inside the Debian chroot.

```sh
# Test after switching to iSH-AOK:
chroot /mnt/debian /bin/sh -c "sleep 1 && echo SLEEP_OK"
ls /dev/rtc && echo RTC_OK
```

---

## amd64 Port — What It Means Long-Term

iSH-AOK has a concrete 12-patch plan (`amd64_port_plan.md` in the repo) to add
full x86_64 emulation. When complete:

- No more i686 Alpine limitation
- No more musl wrapper hacks for Ruby 3.4 / git / curl in Debian chroot
- Real amd64 Debian/Ubuntu userland via `apt`
- Homebrew on iSH becomes dramatically simpler (x86_64 formulae, no i386 patches)

**Current status (2026-04-08):** Patch series defined. Not yet started. Interpreter-first,
no JIT until amd64 userland is stable.

**Milestone we care about most:** Milestone 4 (basic shell) — `/bin/sh`, coreutils,
pipes. That alone removes all the Homebrew compatibility hacks we currently maintain.

---

## Compatibility Notes

| Item | Status |
|---|---|
| Alpine apk packages | Fully compatible |
| Existing rootfs / filesystem | Compatible — same database format |
| `start-lab.sh` / `AUTO_START.sh` | No changes needed |
| bore tunnel | No changes needed |
| Debian chroot at `/mnt/debian` | Works — and gains `sleep` + `/dev/rtc` |
| Homebrew patches | Still needed until amd64 port reaches Milestone 4 |
| mem0 integration | No changes needed — gains richer boot data |

---

## References

- [iSH-AOK GitHub](https://github.com/emkey1/ish-AOK)
- [iSH-AOK TestFlight](https://testflight.apple.com/join/X1flyiqE)
- [iSH-AOK Discord](https://discord.gg/RDEN5gJ4H6)
- [amd64 Port Plan](https://github.com/emkey1/ish-AOK/blob/master/amd64_port_plan.md)
- [CHANGELOG](https://github.com/emkey1/ish-AOK/blob/master/CHANGELOG.md)
