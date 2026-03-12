#!/bin/bash
# start-proxy.sh
# Starts a Tailscale TCP proxy + system OpenSSH sshd on the SLURM compute node.
#
# Architecture:
#   Laptop → Tailscale TCP:22 → localhost:2222 → sshd (UsePAM no, runs as HPC user)
#
# The system sshd runs as the job user with UsePAM no (skips Duo 2FA) and
# StrictModes no (bypasses group-writable NFS home check). Modern OpenSSH
# adapts gracefully when launched by a non-root user.
#
# Usage (called by the SLURM job):
#   ./scripts/start-proxy.sh
#
# Optional env overrides:
#   TS_HOSTNAME=my-custom-name   ./scripts/start-proxy.sh
#   TS_INSTANCE=my-instance-name ./scripts/start-proxy.sh

set -e

PROXY_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE_DIR=$PROXY_DIR/images

if [ -f "$PROXY_DIR/.env" ]; then
  source "$PROXY_DIR/.env"
fi

# Auto-pull Tailscale image if not already present
TAILSCALE_SIF=$IMAGE_DIR/tailscale.sif
if [ ! -f "$TAILSCALE_SIF" ]; then
  echo "tailscale.sif not found — pulling from ghcr.io/tailscale/tailscale:latest ..."
  mkdir -p "$IMAGE_DIR"
  APPTAINER_CACHEDIR=/tmp apptainer pull "$TAILSCALE_SIF" docker://ghcr.io/tailscale/tailscale:latest
  echo "Pull complete: $TAILSCALE_SIF"
fi

# Allow TS_INSTANCE and TS_HOSTNAME to be overridden at runtime; fall back to .env or default
export TS_INSTANCE=${TS_INSTANCE:-tailscale-proxy}
export TS_HOSTNAME=${TS_HOSTNAME:-hpc-ts-proxy}

echo "============================================"
echo "  Tailscale SSH Proxy"
echo "============================================"
echo "Hostname : $TS_HOSTNAME"
echo "Node     : $(hostname)"
echo "Job ID   : ${SLURM_JOB_ID:-n/a}"
echo "Started  : $(date)"
echo "============================================"

# Start sshd first so it is ready before Tailscale comes up
source "$PROXY_DIR/scripts/start-sshd.sh"

# Start Tailscale and set up TCP forwarding port 22 → localhost:2222
source "$PROXY_DIR/scripts/start-tailscale-ssh.sh"

echo ""
echo "Tailscale SSH proxy is live."
echo "Connect from your computer:"
echo "  ssh $(id -un)@$TS_HOSTNAME"
echo ""
echo "See README.md for the required ~/.ssh/config snippet."
echo ""
echo "Job will run until the SLURM time limit or manual cancellation."

# Block until SLURM cancels the job or a background process dies
wait
