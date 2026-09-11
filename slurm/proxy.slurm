#!/bin/bash
#SBATCH --job-name=tailscale-proxy
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16g
#SBATCH --time=08:00:00
#SBATCH --output=logs/proxy_%j.out
#SBATCH --error=logs/proxy_%j.err
#SBATCH --mail-type=BEGIN,END,FAIL

# --account, --mail-user, and --chdir are passed on the sbatch command line by start_job.sh

# Reset loaded modules to defaults
module reset

echo "Job started on $(hostname) at $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo "Working directory: $PWD"

# If this job was started from the slurm/ directory, move up one level so paths work as expected.
if [[ $(basename "$PWD") == "slurm" ]]; then
  cd ..
  echo "Changed working directory to: $PWD"
fi

echo "Number of CPUs: $SLURM_CPUS_PER_TASK"
echo "Memory: $SLURM_MEM_PER_NODE MB"

./scripts/start-proxy.sh

echo "Job completed at $(date)"
