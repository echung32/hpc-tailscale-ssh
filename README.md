# Tailscale SSH Proxy for HPC

A self-contained SLURM job that tunnels SSH through Tailscale, bypassing HPC login node authentication (PAM/Duo/2FA).

## Overview

Runs the system `sshd` on a compute node, forwarded through Tailscale. Your connection never touches the login node's PAM stack, so no Duo prompt is triggered. Works with VS Code Remote - SSH too.

## Pre-requisites

- A [Tailscale](https://tailscale.com/) account

### Architecture

```
Your computer
    │
    └─→ Tailscale Network (encrypted tunnel, port 22)
            │
            └─→ HPC Compute Node
                    │
                    ├─ tailscaled (userspace networking)
                    │   └─ TCP:22 forwarded → localhost:2222
                    │
                    └─ sshd (UsePAM no, runs as HPC user)
                        └─→ Your shell (no 2FA)
```

- **Normal SSH**: `your-computer → HPC login node (PAM/2FA) → shell`
- **This proxy**: `your-computer → Tailscale TCP:22 → sshd:2222 → shell`

`sshd` is launched directly as your HPC user with `UsePAM no` and `StrictModes no` (needed for group-writable NFS home directories). Modern OpenSSH (≥ 7.5) handles non-root launch gracefully — privilege separation still runs as your UID, skipping chroot and setuid.

## Quick Start

### 1. Create `.env` from the template

```bash
cp .env.example .env
```

Edit `.env` with your details:
```bash
ACCOUNT=your-slurm-account      # e.g., xxxx-delta-gpu
EMAIL=your@email.com            # for job notifications
WORKING_DIR=/path/to/proxy      # absolute path to this directory
TS_HOSTNAME=hpc-ts-proxy        # unique name on Tailnet
TS_INSTANCE=ts-proxy            # Tailscale state directory name (unique per concurrent job)
```

### 2. Create your Tailscale auth key

Generate a **reusable, ephemeral** auth key at https://login.tailscale.com/admin/settings/keys and tag it with `tag:container`.

```bash
echo "tskey-auth-..." > .tailscale.key
chmod 600 .tailscale.key
```

### 3. Tailscale ACL Configuration

Add an SSH rule in the [Tailscale ACL console](https://login.tailscale.com/admin/acls):

```json
{
    "src":    ["autogroup:member"],
    "dst":    ["tag:container"],
    "users":  ["autogroup:nonroot"],
    "action": "check",
}
```

### 4. Set up SSH key authentication

`sshd` authenticates via `~/.ssh/authorized_keys` on the HPC. Add your computer's public key:

**On your computer** (generate a key if needed):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/hpc-proxy-ed25519
```

**On the HPC**:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys   # paste output of cat ~/.ssh/hpc-proxy-ed25519.pub
chmod 600 ~/.ssh/authorized_keys
```

### 5. Submit the job

```bash
./start_job.sh
```

The job will:
- Auto-pull `images/tailscale.sif` if not present, or re-pull it if it is older than `TS_IMAGE_MAX_AGE_DAYS` (default 7)
- Start `sshd` on `localhost:2222` as your HPC user (no PAM, no Duo)
- Start `tailscaled` and forward Tailscale port 22 → `localhost:2222`

Check the logs:
```bash
tail -f logs/proxy_*.out
```

You'll see output like:
```
============================================
  Tailscale SSH Proxy
============================================
Hostname : hpc-ts-proxy
Node     : batch-node-42
Job ID   : 12345678
Started  : Mon Mar 11 15:30:45 UTC 2026
============================================

Tailscale SSH proxy is live.
Connect from your computer:
  ssh hpc-ts-proxy

Job will run until the SLURM time limit or manual cancellation.
```

### 6. Configure your SSH client

On your **computer**, add to `~/.ssh/config`:

```ssh-config
Host hpc-proxy
    HostName hpc-ts-proxy
    User <your-hpc-username>
    IdentityFile ~/.ssh/hpc-proxy-ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Replace `<your-hpc-username>` with your HPC login name, and `hpc-ts-proxy` with your `TS_HOSTNAME` if you changed it.

### 7. Connect

```bash
ssh hpc-proxy
```

Or with VS Code:
1. Install the **Remote - SSH** extension
2. Click the green remote indicator (bottom-left)
3. Select **Connect to Host...** → `hpc-proxy`

## How It Works

### Job Submission Flow

1. `./start_job.sh` reads `.env` and calls `sbatch` with `--account`, `--mail-user`, and `--chdir` set directly — no placeholder substitution needed
2. SLURM starts the job on a CPU node
3. `scripts/start-proxy.sh`:
   - Auto-pulls `tailscale.sif` if missing, and refreshes it when older than `TS_IMAGE_MAX_AGE_DAYS` (default 7 days). A refresh failure is non-fatal — the job warns and keeps using the image already on disk
   - Calls `scripts/start-sshd.sh` to start system `sshd` on `localhost:2222`
   - Calls `scripts/start-tailscale-ssh.sh` to start Tailscale with TCP forwarding
4. `sshd` reads `~/.ssh/authorized_keys` from your HPC home directory
5. `tailscaled` starts in userspace networking mode
6. `tailscale serve tcp:22 tcp://localhost:2222` forwards Tailscale port 22 to `sshd`
7. Job blocks until SLURM cancellation or timeout

### Connection Flow

1. `ssh hpc-proxy` → resolves to `hpc-ts-proxy` via `.ssh/config`
2. Tailscale routes TCP to the compute node
3. `tailscaled` forwards to `localhost:2222`
4. `sshd` authenticates via public key (no PAM, no Duo)
5. Shell spawns as your HPC user on the compute node

## Directory Structure

```
proxy/
├── .env                        # Your configuration
├── .env.example                # Template for initial setup
├── .gitignore                  # Ignores .env, *.key, .sshd/, logs/, images/
├── .tailscale.key              # Auth key
├── README.md                   # This file
├── start_job.sh                # Reads .env and submits the SLURM job
├── scripts/
│   ├── start-proxy.sh          # Main entry point (called by SLURM job)
│   ├── start-sshd.sh           # Starts system sshd on localhost:2222
│   └── start-tailscale-ssh.sh  # Starts Tailscale + TCP forwarding :22→:2222
├── slurm/
│   └── proxy.slurm             # SLURM job definition
├── images/                     # Apptainer image (auto-pulled on first run)
│   └── tailscale.sif           # (pulled from ghcr.io/tailscale/tailscale:latest)
└── logs/                       # SLURM stdout/stderr
    ├── proxy_12345678.out
    └── proxy_12345678.err
```

## Configuration

All options are in `.env`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `ACCOUNT` | (required) | SLURM account to charge |
| `EMAIL` | (required) | Notification email for job events |
| `WORKING_DIR` | (required) | Absolute path to `proxy/` directory |
| `TS_HOSTNAME` | `hpc-ts-proxy` | Tailscale hostname (advertised on Tailnet, must be unique) |
| `TS_INSTANCE` | `tailscale-proxy` | Tailscale state directory name (must be unique per concurrent job) |
| `TS_IMAGE_MAX_AGE_DAYS` | `7` | Days before `images/tailscale.sif` is re-pulled at job start (`0` = every submission) |

## Troubleshooting

### "Connection refused" / "No route to host"

1. Check the job is running: `squeue -u $USER`
2. Check `sshd` started: `grep "sshd listening\|listening on port" logs/proxy_*.out`
3. Verify Tailscale is up: `grep "tailscaled connected" logs/proxy_*.out`
4. Check Tailscale from your computer: `tailscale status`

### "Permission denied (publickey)"

`sshd` reads `~/.ssh/authorized_keys` from your HPC home. Verify:
```bash
ls -la ~/.ssh/authorized_keys    # must exist on the HPC
cat ~/.ssh/authorized_keys       # your computer's public key must be present
```

Your computer's public key: `cat ~/.ssh/hpc-proxy-ed25519.pub` (or whichever `IdentityFile` you configured).

### "sshd did not start on :2222 within 30s"

- Another process may already be using port 2222 on the node
- Check for errors: `grep -i "error\|failed" logs/proxy_*.err`

### "tailscaled socket never appeared"

Tailscale daemon failed to start. Check `logs/proxy_*.err` (common causes: memory constraints, network policy).

### "Host key verification failed"

The `.sshd/host_ed25519` key persists between jobs, so this should only happen once per host-key change. To clear it on your computer:
```bash
ssh-keygen -R hpc-ts-proxy
```

## Advanced Usage

### Override Hostname or Instance at Runtime

```bash
TS_HOSTNAME=my-custom-proxy TS_INSTANCE=my-instance ./start_job.sh
```

Each `TS_INSTANCE` gets its own isolated Tailscale state directory (`.tailscale/<TS_INSTANCE>/`), so multiple jobs can run concurrently without interfering.

### Longer Job Duration

Edit `slurm/proxy.slurm`:
```bash
#SBATCH --time=24:00:00
```

### Running Multiple Proxies Concurrently

Submit with distinct `TS_INSTANCE` and `TS_HOSTNAME` values:

```bash
TS_INSTANCE=cpu-proxy TS_HOSTNAME=hpc-cpu-proxy ./start_job.sh
TS_INSTANCE=gpu-proxy TS_HOSTNAME=hpc-gpu-proxy ./start_job.sh
```

Then in `~/.ssh/config`:
```ssh-config
Host hpc-cpu
    HostName hpc-cpu-proxy
    User your_hpc_username
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host hpc-gpu
    HostName hpc-gpu-proxy
    User your_hpc_username
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

## Limitations

- **Host key changes between jobs**: Use `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` in your SSH config, or delete the cached key with `ssh-keygen -R <hostname>`.
- **Userspace networking only**: Cannot use kernel TUN — relies on Tailscale's userspace stack.
- **One job per `TS_INSTANCE`**: Use distinct `TS_INSTANCE` names for concurrent jobs.

## Adapting to Other HPC Clusters

1. In `slurm/proxy.slurm`, adjust `--partition`, `--mem`, and `--time` to your cluster's limits.
2. Ensure `apptainer` is available (`module load apptainer` or similar).
3. Only `.env` values need to change — the scripts are cluster-agnostic.
