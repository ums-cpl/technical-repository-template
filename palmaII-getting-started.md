# Getting Started on Palma II

This document is an opinionated guide designed for those not yet familiar with Palma II. It outlines a workflow found to be efficient and practical for running tasks on the [Palma II](https://palma.uni-muenster.de/) HPC cluster at the University of Münster. For comprehensive details and additional possibilities, consult the [official Palma II documentation](https://palma.uni-muenster.de/).

> **Note:** This is a living document and is intended to be improved over time. Any feedback, suggestions, or criticism are very welcome -- please send comments to [Richard](mailto:r.schulze@uni-muenster.de).


## Cluster Architecture Overview

- **Login Node:**  
  After establishing an SSH connection to Palma II, access is provided to a login node. This node serves only for managing files, preparing jobs, compiling software, and light testing. CPU-intensive or long-running computations are strictly prohibited on the login node and may result in process termination.

- **Partitions and Compute Nodes:**  
  Palma II is organized into *partitions*, each consisting of a queue and a set of compute nodes with particular hardware profiles (e.g., CPUs, GPUs, memory size). Partitions have names such as `express`, `normal`, or `long` to indicate different runtime limits, hardware, and priorities. Each partition maintains its own queue, where jobs wait for resources to become available.

  Refer to the official Palma II documentation for a full and current list of available CPU and GPU partitions, including their intended uses, runtime limits, and hardware properties:
  - [Available CPU partitions](https://palma.uni-muenster.de/documentation/hardware/partitions/#general-purpose-public-cpu-partitions)
  - [Available GPU partitions](https://palma.uni-muenster.de/documentation/hardware/partitions/#general-purpose-public-gpu-partitions)

  These references should be consulted to select the appropriate partition type for a given job.

- **Job Submission:**  
  Heavy computations are never executed directly on the login node. Instead, *jobs* are submitted to the appropriate partition’s queue. The cluster software then schedules these jobs to run on one or more compute nodes.  

## Typical Palma II Workflow

A standard workflow on Palma II is summarized below. Each step is elaborated in subsequent sections.

1. **Login:**  
   SSH access is used to reach the login node. Files may be copied to Palma via `scp` or a graphical SFTP client.

2. **Start an Interactive Session (if needed):**  
   For compiling, testing, or debugging interactively, request an interactive allocation with `salloc`. This command reserves a compute node for a specified time.
   
   > All computational and long-running tasks **must** be executed only on compute nodes, not on the login node.

3. **Compile and Test Code:**  
   Within the interactive session, build software or perform small-scale tests to ensure correct operation.

4. **Prepare a Batch Script:**  
   A batch script is written to specify required compute resources and to define execution commands. This script allows computations to proceed unattended.

5. **Submit the Job:**  
   Submission of the batch script to a queue (partition) is accomplished with `sbatch <script>`. The scheduler allocates the job to one or more nodes once resources are available.

6. **Check Job Status:**  
   Commands such as `squeue -u <username>` provide status and position of jobs in the queue.

7. **Review Output Logs:**  
   Upon completion (or failure) of a job, review output and error log files generated during execution. Log file paths are defined in the batch script by `#SBATCH --output` and `#SBATCH --error`.


## Detailed Step-By-Step Instructions

### Gaining Access and Login

1. Register for the **u0clstr** and **o7pvs** user groups via the [IT Portal](https://www.uni-muenster.de/IT-Portal) (activation may require up to 24 hours). Before registering, please check in with Ari or Richard.
2. Create an SSH key pair and upload the public key under *Passwords and PINs → Public SSH keys* in the IT Portal:
   ```bash
   ssh-keygen -t ecdsa -b 384 -f ~/.ssh/id_ecdsa_palma
   ```
3. Palma II is only reachable from inside the University network. To connect conveniently from outside, add a jumphost entry to the SSH configuration (`~/.ssh/config`). Replace `$USERNAME` with the university username:

   ```ssh
   Host palma
    HostName palma-login.uni-muenster.de
    User $USERNAME
    IdentityFile ~/.ssh/id_ecdsa_palma
    ProxyJump jumphost

   Host jumphost
    HostName sshjump.uni-muenster.de
    User $USERNAME
    IdentityFile ~/.ssh/id_ecdsa_palma
   ```

   Connection to Palma II is then possible with:
   ```bash
   ssh palma
   ```
   > **Note:** If you are prompted for a password when connecting, it refers to the passphrase you (optionally) set for your SSH key, *not* your university password.

### Filesystem and Data Transfer

Palma II provides two main directories that are accessible from both the login node and all compute nodes:

- **$HOME**  
  Intended only for storing applications (e.g., installed software, configuration). Limited storage -- not suitable for project data or computation output.

- **$WORK** (`/scratch/tmp/$USERNAME`)  
  Intended as a "working directory" for project files, log files, computation output, input data, and temporary files. In practice, it is advisable to work exclusively on scratch, since it has a much higher storage limit. Current quota usage can be checked with `myquota`.

> **Note:** The login node and all compute nodes share the same filesystem. This means that any files placed in `$WORK` (or `$HOME`) from the login node are instantly available on the compute nodes as well -- no further transfer between nodes is required.

File transfer between a local machine and Palma II can be done via graphical SFTP clients or via the command line, e.g., with `scp`.

Examples (replace `$USERNAME` with your university username):

```bash
# Copy a local directory (e.g., a repository) into scratch
scp -r -i ~/.ssh/id_ecdsa_palma /path/to/mydir palma:/scratch/tmp/$USERNAME/

# Copy a directory from scratch back to your local machine
scp -r -i ~/.ssh/id_ecdsa_palma palma:/scratch/tmp/$USERNAME/mydir /path/to/local/destination/
```

### Interactive Sessions

Interactive sessions are used for compiling, testing, or debugging. Heavy workloads must not be executed on login nodes; use `salloc` to request an interactive session on a compute node.

Palma II provides the `express` partition for short-running jobs. It is preferable for interactive sessions due to its usually short wait time. Example:

```bash
# Allocate a node in the express partition with 36 CPU cores and 90GB main memory
salloc --cpus-per-task=36 --mem=90gb --partition=express
```

Once inside an interactive session, the machine name of the compute node appears in the command prompt. The terminal behaves the same as on a local machine. Programs can be compiled and run as usual. The session ends when exiting the shell (e.g., with `exit` or Ctrl+D).

Available software on Palma II -- including compilers (e.g., `GCC`, `intel`), libraries (e.g., `OpenMPI`, `imkl`, `OpenBLAS`), and frameworks (e.g., `TensorFlow`, `PyTorch`, `CUDA`) -- can be loaded via the *module* system. The main commands are:

```bash
# List currently available modules (software)
module avail

# Search for a module with a specific name
module spider <name>

# Load a module into the environment
module load <name>

# Unload a module from the environment
module unload <name>

# List all currently loaded modules
module list

# Unload all modules from the environment
module purge
```

Modules on Palma II often depend on other modules. When loading a module, its dependencies are typically loaded automatically. To inspect which dependencies a module has, use the `module spider <exact-name-including-version>` command. This displays detailed information about the module, including any other modules that must be loaded first or alongside it.

> **Note:** This template recommends using only the `Apptainer` module and installing all required software inside a container. This approach provides independence from the software available on Palma II and documents the exact setup steps taken.

### GPU Access

Some partitions offer access to GPUs. The basic workflow remains the same, but GPUs must be explicitly requested using the `--gres` flag, for example:

```bash
# Allocate a node in the gpuexpress partition with 1 GPU, 8 CPU cores and 60GB main memory
salloc --partition=gpuexpress --gres=gpu:1 --cpus-per-task=8 --mem=60gb
```

### Unattended Jobs

Interactive sessions are suitable for short tasks, but long-running computations or workloads that exceed a single session benefit from unattended jobs. Unattended jobs allow computations to run without an active connection and to continue after disconnecting from the cluster.

An unattended job consists of a batch script that is submitted to a partition and executed as a job by the scheduler. The script specifies resource requirements (partition, CPUs, memory, walltime) and the commands to run. Write the script to a file (e.g., `job.sh`) and submit it with `sbatch job.sh`:

```bash
#!/bin/bash
#SBATCH --partition=normal,long    # Queue(s) to submit to; jobs may run on either
#SBATCH --cpus-per-task=36         # Number of CPU cores to allocate
#SBATCH --time=24:00:00            # Maximum walltime (HH:MM:SS)
#SBATCH --job-name=my_job          # Name shown in squeue
#SBATCH --output=my_job.out        # File for stdout
#SBATCH --error=my_job.err         # File for stderr

module load Apptainer Python
./my_script.sh
```

Multiple similar jobs can be submitted as a *job array* with a single `sbatch` call. Job arrays reduce administrative overhead, share a single job ID, and allow the scheduler to run array elements in parallel when resources are available. Each array element receives a unique `SLURM_ARRAY_TASK_ID` (e.g., 0, 1, 2, …), which can be used to parameterize the task. Write the script to a file (e.g., `job.sh`) and submit with `sbatch job.sh`:

```bash
#!/bin/bash
#SBATCH --array=0-9                # Create 10 jobs with task IDs 0 through 9
#SBATCH --partition=normal,long
#SBATCH --cpus-per-task=36         # Number of CPU cores per array element
#SBATCH --time=24:00:00            # Maximum walltime per array element
#SBATCH --job-name=my_job
#SBATCH --output=task_%a.out       # stdout file; %a is replaced by array task ID
#SBATCH --error=task_%a.err        # stderr file; %a is replaced by array task ID

# Each array element receives SLURM_ARRAY_TASK_ID (0, 1, ..., 9)
module load Apptainer Python
./my_script.sh $SLURM_ARRAY_TASK_ID
```
