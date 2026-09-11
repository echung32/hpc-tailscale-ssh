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

# Tailscale image: pull if missing, refresh if older than TS_IMAGE_MAX_AGE_DAYS.
# The pull goes to a temp file and is swapped in with an atomic mv, so a job that
# is already running keeps its old inode and an interrupted pull never leaves a
# truncated SIF behind.
TAILSCALE_SIF=$IMAGE_DIR/tailscale.sif
TAILSCALE_IMAGE=docker://ghcr.io/tailscale/tailscale:latest
TS_IMAGE_MAX_AGE_DAYS=${TS_IMAGE_MAX_AGE_DAYS:-7}

# Stale if TS_IMAGE_MAX_AGE_DAYS is 0 (always refresh) or the mtime is older
# than that many days. -mmin is used rather than -mtime so "7 days" means 7x24h,
# not -mtime's "more than 8 whole days".
sif_is_stale() {
  [ "$TS_IMAGE_MAX_AGE_DAYS" -le 0 ] && return 0
  [ -n "$(find "$TAILSCALE_SIF" -maxdepth 0 -mmin +$((TS_IMAGE_MAX_AGE_DAYS * 1440)) 2>/dev/null)" ]
}

pull_tailscale_sif() {
  local tmp=$IMAGE_DIR/.tailscale.sif.new
  mkdir -p "$IMAGE_DIR"
  rm -f "$tmp"
  if APPTAINER_CACHEDIR=/tmp apptainer pull "$tmp" "$TAILSCALE_IMAGE"; then
    mv -f "$tmp" "$TAILSCALE_SIF"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

if [ ! -f "$TAILSCALE_SIF" ]; then
  # No image at all — the job cannot run without it, so a failure here is fatal.
  echo "tailscale.sif not found — pulling from $TAILSCALE_IMAGE ..."
  if ! pull_tailscale_sif; then
    echo "ERROR: failed to pull $TAILSCALE_IMAGE" >&2
    exit 1
  fi
  echo "Pull complete: $TAILSCALE_SIF"
elif sif_is_stale; then
  # Image is stale. A refresh failure is non-fatal: a transient registry outage
  # should not kill the job when a working image is already on disk.
  if [ "$TS_IMAGE_MAX_AGE_DAYS" -le 0 ]; then
    echo "TS_IMAGE_MAX_AGE_DAYS=0 — refreshing tailscale.sif from $TAILSCALE_IMAGE ..."
  else
    echo "tailscale.sif is older than $TS_IMAGE_MAX_AGE_DAYS day(s) — refreshing from $TAILSCALE_IMAGE ..."
  fi
  if pull_tailscale_sif; then
    echo "Refresh complete: $TAILSCALE_SIF"
  else
    echo "WARNING: refresh failed — continuing with the existing image." >&2
  fi
fi
echo "Tailscale image: $(apptainer exec "$TAILSCALE_SIF" tailscale --version 2>/dev/null | head -1) ($(date -r "$TAILSCALE_SIF" '+%Y-%m-%d'))"

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
