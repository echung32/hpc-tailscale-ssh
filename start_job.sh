#!/bin/bash

# start_job.sh: Submit the Tailscale SSH proxy SLURM job.
# Reads configuration from .env and passes values directly to sbatch
#
# Usage: ./start_job.sh [slurm_file]
#        Defaults to slurm/proxy.slurm

set -e

if [ ! -f ".env" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill it in."
    exit 1
fi

source .env

for var in ACCOUNT EMAIL WORKING_DIR; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

if [ $# -eq 0 ]; then
    SLURM_FILE="slurm/proxy.slurm"
elif [ $# -eq 1 ]; then
    SLURM_FILE="$1"
else
    echo "Usage: $0 [slurm_file]"
    exit 1
fi

if [ ! -f "$SLURM_FILE" ]; then
    echo "Error: SLURM file '$SLURM_FILE' not found."
    exit 1
fi

mkdir -p "$WORKING_DIR/logs"

sbatch \
    --account="$ACCOUNT" \
    --mail-user="$EMAIL" \
    --chdir="$WORKING_DIR" \
    "$SLURM_FILE"

echo "Job submitted. Watching queue (ctrl+c to stop watching):"
watch squeue -u "$USER"
