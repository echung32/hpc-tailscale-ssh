#!/bin/bash
# start-sshd.sh
# Starts the system OpenSSH daemon on localhost:2222 as the current HPC user.
#
# Modern OpenSSH (>= 7.5) adapts when launched by a non-root user: privilege
# separation still runs but as the current UID, skipping chroot and setuid.
# Two config flags make it work cleanly in HPC environments:
#
#   UsePAM no       — disables PAM entirely, skipping Duo 2FA
#   StrictModes no  — bypasses the group-writable home directory check that
#                     commonly fails on NFS-mounted HPC home directories
#
# Requires PROXY_DIR and HOME to be set (done by start-proxy.sh).

SSHD_DIR=$PROXY_DIR/.sshd
mkdir -p "$SSHD_DIR"

# Find the sshd binary (typically /usr/sbin/sshd on RHEL/Rocky nodes)
SSHD_BIN=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
if [ ! -x "$SSHD_BIN" ]; then
  echo "ERROR: sshd binary not found (tried: $SSHD_BIN)"
  echo "       Check that OpenSSH is installed on this node."
  exit 1
fi
echo "Using sshd: $SSHD_BIN ($($SSHD_BIN -V 2>&1 | head -1))"

# Generate a persistent host key so clients don't get key-changed warnings
if [ ! -f "$SSHD_DIR/host_ed25519" ]; then
  echo "Generating SSH host key..."
  ssh-keygen -t ed25519 -f "$SSHD_DIR/host_ed25519" -N ""
  chmod 600 "$SSHD_DIR/host_ed25519"
fi

# Write minimal sshd_config.
# Absolute paths are used throughout so this works regardless of $HOME or CWD.
cat > "$SSHD_DIR/sshd_config" << EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $SSHD_DIR/host_ed25519
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PidFile $SSHD_DIR/sshd.pid

# Skip Duo/PAM 2FA entirely
UsePAM no

# Bypass group-writable home directory check (common on HPC NFS mounts)
StrictModes no

PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

UseDNS no
X11Forwarding no
Subsystem sftp internal-sftp
EOF

echo "Starting sshd on localhost:2222 (user: $(id -un))..."
"$SSHD_BIN" -f "$SSHD_DIR/sshd_config" -D -e &

# Wait for sshd to accept connections
echo "Waiting for sshd..."
for i in $(seq 1 30); do
  if ss -tlnp 2>/dev/null | grep -q ':2222'; then
    echo "sshd listening on :2222 after ${i}s"
    break
  fi
  sleep 1
done

if ! ss -tlnp 2>/dev/null | grep -q ':2222'; then
  echo "ERROR: sshd did not start on :2222 within 30s — check logs"
  exit 1
fi
