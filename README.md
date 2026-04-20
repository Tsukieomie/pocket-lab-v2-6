# Pocket Security Lab v2.6

GitHub-gated, signed-approval, Perplexity Computer SSH-integrated security lab bundle.

## What's new in v2.6

- **Perplexity Computer live SSH connection** via bore.pub tunnel
- **Fixed** `verify_pocket_lab_v2_4.sh` — now uses correct `ish_startup_signing_secp256k1.pub` key
- **`OPEN_POCKET_LAB_V2_6.sh`** — three-gate opener: startup verify → signed GitHub approval → v2.6 unified verify → unlock
- **`STATUS_V2_6.sh`** — unified status across all versions (tamper, v2.3, v2.4, v2.6, tunnel, approval)
- **`verify_pocket_lab_v2_6.sh`** — full chain verifier

## Security model

- GitHub provides signed, short-lived approval artifacts. It does not store secrets.
- The unlock secret remains inside iSH on-device only.
- Every open command verifies secp256k1 signature + SHA-256 + bitcoin-style sha256d before unlocking.
- Tamper lockout is enforced — any integrity failure blocks unlock.

## Quick commands (in iSH)

```sh
# Full three-gate open
/root/perplexity/OPEN_POCKET_LAB_V2_6.sh

# Unified status
/root/perplexity/STATUS_V2_6.sh

# Verify only
/root/perplexity/verify_pocket_lab_v2_6.sh

# Lock (remove plaintext)
/root/.pocket_lab_secure/lock-pocket-lab.sh
```

## Approval flow

1. In iSH, generate a nonce:
   ```sh
   . /root/.pocket_lab_secure/signed-approval-config
   /root/.pocket_lab_secure/pocket-lab-signed-approval.sh nonce
   ```
2. Trigger **Actions → Approve Pocket Lab Unlock Signed** and enter the nonce + PDF hash.
3. Run `OPEN_POCKET_LAB_V2_6.sh` — it fetches and verifies the approval automatically.

## Artifact hashes (v2.4 bundle, still active vault)

| File | SHA-256 |
|---|---|
| `pocket_security_lab_v2_4_integrated.pdf` | `38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134` |
| `pocket_security_lab_v2_4.tar.enc` | `3201076f28cd6a6978586e18ce23c2c9851a73a0c6d357382fc44361758b9493` |
