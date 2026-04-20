# Security Policy

## Threat Model

The Pocket Security Lab is a personal-device encrypted bundle whose "open"
workflow is guarded by a three-gate signed-approval chain:

1. **Tamper check** — `tamper-alert.sh` verifies that on-device startup files
   have not been modified since the last signed manifest.
2. **GitHub signed approval** — a short-lived approval JSON, signed with a
   secp256k1 key held in GitHub Actions secrets, must be fetched from a
   separate approval repo before unlock is allowed.
3. **Manifest verify** — `verify_pocket_lab_v2_6.sh` verifies the v2.6
   manifest signature and policy (fail-closed, no self-execution, no
   "proceed anyway").

### What this chain protects against

- An attacker who obtains a copy of `pocket_security_lab_v2_4.tar.enc`
  off-device cannot unlock it; the decryption key never leaves the device.
- An attacker who gains temporary access to the device but cannot access
  GitHub (no network, no approval secret) cannot complete Gate 2.
- An on-device file tamper is detected by Gate 1 before unlock proceeds.
- An expired approval (older than 5 minutes) is rejected by the freshness
  check in `pocket-lab-signed-approval.sh` / `verify_pocket_lab_v2_6.sh`.

### What this chain does NOT protect against

- **Full device compromise.** The decryption key, the manifest-signing key,
  and (if `POCKET_LAB_SELF_SIGN=1` is set) the approval-signing key all
  live on the device. Anyone with root on the device can open the vault.
- **Compromise of the GitHub approval signing secret.** Anyone who can run
  the signing workflow can produce a valid approval.
- **Leaked SSH credentials to the reverse tunnel.** The tunnel (bore.pub by
  default, self-hosted bore recommended — see `TUNNEL_UPGRADE.md`) is the
  access path; its credentials are not part of the unlock chain itself.
- **Side-channel attacks, physical extraction, or supply-chain compromise
  of any of the ~dozen shell tools and binaries the scripts depend on.**

The `POCKET_LAB_SELF_SIGN=1` bypass exists for recovery when GitHub Actions
is unavailable. When enabled, a fresh keypair is generated on-device and
the manifest is re-signed locally. **This reduces Gate 2 to "the device
vouches for itself"** and should only be used for recovery scenarios. It
is off by default.

## Rotating Credentials

### SSH root password

The bore-tunneled SSH password used by `PERPLEXITY_LOAD.sh` is read from
`POCKET_LAB_SSH_PASS` in the environment. To rotate:

1. On the iSH device: `passwd root` (set a new strong password).
2. In your shell (Perplexity Computer or wherever you launch
   `PERPLEXITY_LOAD.sh`): `export POCKET_LAB_SSH_PASS=<new-password>`.
   Consider adding it to your shell init with appropriate file permissions
   (mode 600), or use a password manager to inject it.
3. **Preferred**: switch to key-based SSH auth. Generate a keypair, copy
   the public key to `/root/.ssh/authorized_keys` on the iSH device,
   disable password auth in `sshd_config`, and remove the `sshpass -p`
   path from `PERPLEXITY_LOAD.sh`.

### Perplexity agent-proxy token

`.mcp.json` reads `AUTH_TOKEN` from `${PERPLEXITY_AGENT_TOKEN}`. To rotate:

1. Revoke the old token in the Perplexity agent-proxy dashboard.
2. Issue a new token.
3. Set `export PERPLEXITY_AGENT_TOKEN=<new-token>` in your shell init.
4. Restart Claude Code / the MCP client.

### Manifest / approval signing keys

- `ish_startup_signing_secp256k1.key` (on-device) signs the tamper manifest.
  Regenerate with `openssl ecparam -name secp256k1 -genkey -noout -out ...`,
  re-sign all manifests, and update every `EXPECTED_PUB_SHA` reference.
- `POCKET_LAB_APPROVAL_SIGNING_KEY` (GitHub secret) signs approval JSON.
  Regenerate the keypair, update the GitHub secret with the base64-encoded
  private key, and push the new public key to the approval repo.

## Reporting Security Issues

Please report security issues privately to **security@example.invalid**
(placeholder — replace with your real contact email before publishing this
repo). Do not file public GitHub issues for undisclosed vulnerabilities.

## Known Historical Exposure

The following credentials were committed to this repository in earlier
commits and must be considered compromised. They have been rotated; do
not attempt to reuse them:

- SSH root password previously written as `SunTzu612` in `README.md`,
  `PERPLEXITY_LOAD.sh`, and related docs.
- Perplexity agent-proxy bearer token previously written in `.mcp.json`.

A git-history rewrite (e.g. `git filter-repo` / BFG) to purge these
values from the repo's history is recommended but is intentionally **not**
performed by the automated cleanup PR — it requires force-pushing and
should be done deliberately by a human after confirming the credentials
have been rotated.
