# Pocket Security Lab v2.7

GitHub-gated, signed-approval, Perplexity Computer SSH-integrated security lab bundle.

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
```

Source: [debian-ish-rootfs](https://github.com/Tsukieomie/debian-ish-rootfs)

## Perplexity SSH Connection

```
Host: bore.pub  Port: 40188  User: root
```

## Artifact hashes (v2.4 bundle, still active vault)

| File | SHA-256 |
|---|---|
| `pocket_security_lab_v2_4_integrated.pdf` | `38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134` |
| `pocket_security_lab_v2_4.tar.enc` | `3201076f28cd6a6978586e18ce23c2c9851a73a0c6d357382fc44361758b9493` |
