#!/bin/bash
# start-tailscale-ssh.sh
# Source this script from start-proxy.sh after setting:
#   TS_INSTANCE  - unique name for this Apptainer instance (default: tailscale-proxy)
#   TS_HOSTNAME  - tailscale hostname to advertise (default: hpc-ts-proxy)

TS_DIR=$PROXY_DIR/.tailscale/$TS_INSTANCE
TS_AUTH_KEY="$(cat $PROXY_DIR/.tailscale.key)"
mkdir -p $TS_DIR/lib $TS_DIR/run

export APPTAINER_BIND=$TS_DIR/lib:/var/lib/tailscale,$TS_DIR/run:/var/run/tailscale

apptainer instance start \
  $IMAGE_DIR/tailscale.sif \
  tailscale-$TS_INSTANCE

# https://tailscale.com/docs/concepts/userspace-networking
# Run in userspace because HPC nodes don't expose TUN devices
apptainer exec instance://tailscale-$TS_INSTANCE \
  tailscaled \
  --tun=userspace-networking \
  --statedir=/var/lib/tailscale \
  --socket=/var/run/tailscale/tailscaled.sock &

# Wait for tailscaled socket to be ready (up to 30s)
echo "Waiting for tailscaled socket..."
for i in $(seq 1 30); do
  if [ -S "$TS_DIR/run/tailscaled.sock" ]; then
    echo "tailscaled socket ready after ${i}s"
    break
  fi
  sleep 1
done

if [ ! -S "$TS_DIR/run/tailscaled.sock" ]; then
  echo "ERROR: tailscaled socket never appeared at $TS_DIR/run/tailscaled.sock"
  exit 1
fi

# Authenticate with extra stability flags
# --accept-dns=false: Prevents Tailscale from fighting with HPC DNS
# --reset: Clears any stale state from previous crashed runs
apptainer exec instance://tailscale-$TS_INSTANCE \
  tailscale up \
  --hostname=$TS_HOSTNAME \
  --advertise-tags=tag:container \
  --auth-key="$TS_AUTH_KEY" \
  --accept-dns=false \
  --reset

# Forward Tailscale port 22 → 127.0.0.1:2222 where sshd is listening.
# The address is given as an IP literal, not "localhost": inside the Alpine
# image "localhost" resolves to ::1 first, and sshd binds IPv4 loopback.
# TCP connections arriving from the Tailnet on port 22 are proxied directly;
# no Tailscale SSH server is involved, so the HPC PAM stack is never triggered.
apptainer exec instance://tailscale-$TS_INSTANCE \
  tailscale serve \
  --bg \
  --tcp 22 \
  tcp://127.0.0.1:2222

# Verify the serve status
echo "Current Tailscale Serve Status:"
apptainer exec instance://tailscale-$TS_INSTANCE tailscale serve status
