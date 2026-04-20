#!/bin/sh
# ============================================================
# setup-secure-tunnel.sh — Pocket Lab Secure Tunnel Setup
#
# Replaces public bore.pub with self-hosted bore + secret auth.
# Run this ON YOUR VPS to set up the server side.
# ============================================================
set -eu

echo "╔══════════════════════════════════════════════════════╗"
echo "║   POCKET LAB — SECURE BORE SERVER SETUP             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Download bore server binary ─────────────────────
echo "[1/5] Downloading bore v0.6.0..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  BORE_ARCH="x86_64-unknown-linux-musl" ;;
  aarch64) BORE_ARCH="aarch64-unknown-linux-musl" ;;
  armv7*)  BORE_ARCH="armv7-unknown-linux-musleabihf" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

cd /tmp
curl -sL "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-${BORE_ARCH}.tar.gz" | tar xz
sudo mv bore /usr/local/bin/bore
sudo chmod +x /usr/local/bin/bore
echo "   Installed: $(bore --version)"

# ── Step 2: Generate shared secret ──────────────────────────
echo "[2/5] Generating shared secret..."
BORE_SECRET=$(openssl rand -hex 32)
echo "   Secret: $BORE_SECRET"
echo ""
echo "   ╔══════════════════════════════════════════════════╗"
echo "   ║  SAVE THIS SECRET — you need it on iSH too!     ║"
echo "   ╚══════════════════════════════════════════════════╝"
echo ""

# ── Step 3: Create systemd service ──────────────────────────
echo "[3/5] Creating systemd service..."
sudo tee /etc/systemd/system/bore-tunnel.service > /dev/null << EOF
[Unit]
Description=Bore Tunnel Server (Pocket Lab)
After=network.target
Documentation=https://github.com/ekzhang/bore

[Service]
Type=simple
ExecStart=/usr/local/bin/bore server --secret ${BORE_SECRET} --min-port 40000 --max-port 40100
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable bore-tunnel
sudo systemctl start bore-tunnel
echo "   Service created and started."

# ── Step 4: Configure firewall ──────────────────────────────
echo "[4/5] Configuring firewall..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 7835/tcp comment "Bore control port"
  sudo ufw allow 40000:40100/tcp comment "Bore tunnel ports"
  echo "   UFW rules added."
elif command -v firewall-cmd >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --add-port=7835/tcp
  sudo firewall-cmd --permanent --add-port=40000-40100/tcp
  sudo firewall-cmd --reload
  echo "   firewalld rules added."
else
  echo "   WARNING: No firewall manager found. Manually open ports 7835 and 40000-40100."
fi

# ── Step 5: Verify ──────────────────────────────────────────
echo "[5/5] Verifying..."
sleep 2
if sudo systemctl is-active bore-tunnel >/dev/null 2>&1; then
  echo "   ✓ bore-tunnel service is RUNNING"
else
  echo "   ✗ bore-tunnel service FAILED — check: sudo journalctl -u bore-tunnel"
fi

VPS_IP=$(curl -sf https://icanhazip.com || echo "UNKNOWN")
echo ""
echo "══════════════════════════════════════════════════════"
echo " SERVER READY"
echo ""
echo " VPS IP:     $VPS_IP"
echo " Control:    $VPS_IP:7835"
echo " Tunnels:    $VPS_IP:40000-40100"
echo " Secret:     $BORE_SECRET"
echo ""
echo " On iSH, run:"
echo "   export BORE_SECRET=\"$BORE_SECRET\""
echo "   bore local 2222 --to $VPS_IP --port 40188 -s \"\$BORE_SECRET\""
echo ""
echo " On Perplexity Computer, update BORE_HOST to:"
echo "   BORE_HOST=\"$VPS_IP\""
echo "══════════════════════════════════════════════════════"
