#!/bin/bash

## PGC Nunatak settings
##PBS -l walltime=200:00:00,nodes=1:ppn=16,mem=64gb
##PBS -m n
##PBS -k oe
##PBS -j oe
##PBS -q old

## PGC Rookery settings
##SBATCH --time 200:00:00
##SBATCH --nodes 1
##SBATCH --ntasks 1
##SBATCH --cpus-per-task 24
##SBATCH --mem=120G
##SBATCH -o %x.o%j

## BW settings
##PBS -l nodes=1:ppn=16:xe,gres=shifter
##PBS -l walltime=96:00:00
##PBS -v CRAY_ROOTFS=SHIFTER,UDI="ubuntu:xenial"
##PBS -e $PBS_JOBID.err
##PBS -o $PBS_JOBID.out
##PBS -m n
##PBS -q high


set -uo pipefail

set +u
#echo ________________________________________________________
#echo
#echo PBS Job Log
#echo Start time: $(date)
#echo
#echo Job name: $PBS_JOBNAME
#echo Job ID: $PBS_JOBID
#echo Submitted by user: $USER
#echo User effective group ID: $(id -ng)
#echo
#echo Hostname of submission: $PBS_O_HOST
#echo Submitted to cluster: $PBS_SERVER
#echo Submitted to queue: $PBS_QUEUE
#echo Requested nodes per job: $PBS_NUM_NODES
#echo Requested cores per node: $PBS_NUM_PPN
#echo Requested cores per job: $PBS_NP
##echo Node list file: $PBS_NODEFILE
##echo Nodes assigned to job: $(cat $PBS_NODEFILE)
##echo Running node index: $PBS_O_NODENUM
#echo
#echo Running on hostname: $HOSTNAME
#echo Parent PID: $PPID
#echo Process PID: $$
#echo
#echo Working directory: $PBS_O_WORKDIR
#echo ________________________________________________________
#echo
#JOB_ID=$PBS_JOBID
#CORES_PER_NODE=$PBS_NUM_PPN

echo ________________________________________
echo
echo SLURM Job Log
echo Start time: $(date)
echo
echo Job name: $SLURM_JOB_NAME
echo Job ID: $SLURM_JOBID
echo Submitted by user: $USER
echo User effective group ID: $(id -ng)
echo
echo SLURM account used: $SLURM_ACCOUNT
echo Hostname of submission: $SLURM_SUBMIT_HOST
echo Submitted to cluster: $SLURM_CLUSTER_NAME
echo Submitted to node: $SLURMD_NODENAME
echo Cores on node: $SLURM_CPUS_ON_NODE
echo Requested cores per task: $SLURM_CPUS_PER_TASK
echo Requested cores per job: $SLURM_NTASKS
echo Requested walltime: $SBATCH_TIMELIMIT
#echo Nodes assigned to job: $SLURM_JOB_NODELIST
#echo Running node index: $SLURM_NODEID
echo
echo Running on hostname: $HOSTNAME
echo Parent PID: $PPID
echo Process PID: $$
echo
echo Working directory: $SLURM_SUBMIT_DIR
echo ________________________________________________________
echo
JOB_ID=$SLURM_JOBID
CORES_PER_NODE=$SLURM_CPUS_ON_NODE
set -u

set +u; tileName="$ARG_TILENAME"; set -u
system="$ARG_SYSTEM"
scriptdir="$ARG_SCRIPTDIR"
libdir="$ARG_LIBDIR"
outDir="$ARG_OUTDIR"
resolution="$ARG_RESOLUTION"
projection="$ARG_PROJECTION"
tileDefFile="$ARG_TILEDEFFILE"
stripDatabaseFile="$ARG_STRIPDATABASEFILE"
stripsDirectory="$ARG_STRIPSDIRECTORY"
waterTileDir="$ARG_WATERTILEDIR"
refDemFile="$ARG_REFDEMFILE"
tileqcDir="$ARG_TILEQCDIR"
tileParamListFile="$ARG_TILEPARAMLISTFILE"
dateFiltStart="$ARG_DATEFILTSTART"
dateFiltEnd="$ARG_DATEFILTEND"
make2m="$ARG_MAKE2M"
finfile="$ARG_FINFILE"
logfile="$ARG_LOGFILE"
runscript="$ARG_RUNSCRIPT"
set +u; temp_subtile_dir="$TEMP_SUBTILE_DIR"; set -u
set +u; already_in_aprun="$ALREADY_IN_APRUN"; set -u
if [ -z "$already_in_aprun" ]; then
    already_in_aprun=false
fi

if (( $# == 1 )); then
    if [ "$1" = '--make-10m-only' ]; then
        make2m=false
    else
        tileName="$1"
    fi
fi
if [ -z "$tileName" ]; then
    echo "argument 'tileName' not supplied, exiting"
    exit 0
fi
if [ -n "$temp_subtile_dir" ]; then
    outDir="$temp_subtile_dir"
fi

utm_tilePrefix=$(echo "$tileName" | grep -Eo '^utm[0-9]{2}[ns]')
if [ -n "$utm_tilePrefix" ]; then

    if [ -z "$projection" ]; then
        projection="$utm_tilePrefix"
    fi

    hemi_abbrev="${utm_tilePrefix: -1}"
    if [ "$hemi_abbrev" = 'n' ]; then
        hemisphere='North'
    elif [ "$hemi_abbrev" = 's' ]; then
        hemisphere='South'
    else
        hemisphere=''
    fi
    if [ -n "$hemisphere" ]; then
        tileDefFile="${tileDefFile/<hemisphere>/${hemisphere}}"
    fi

    refDemFile="${refDemFile/<tilePrefix>/${utm_tilePrefix}}"
fi
if [ -z "$projection" ]; then
    echo "argument 'projection' not supplied, exiting"
    exit 0
fi

outDir="${outDir/<tileName>/${tileName}}"
finfile="${finfile/<tileName>/${tileName}}"
logfile="${logfile/<tileName>/${tileName}}"
runscript="${runscript/<tileName>/${tileName}}"


# System-specific settings
APRUN_PREFIX=""

if [ "$system" = 'pgc' ]; then
    # Matlab settings
    MATLAB_WORKING_DIR="${HOME}/matlab_working_dir"
    MATLAB_TEMP_DIR="${HOME}/matlab_temp_dir"
#    module load matlab/2019a
    MATLAB_PROGRAM="matlab"
    MATLAB_SETTINGS="-nodisplay -nodesktop -nosplash"
    MATLAB_USE_PARPOOL=true

    # Load Python/GDAL environment
    set +u
    source ~/.bashrc ; conda activate pgc
    set -u

elif [ "$system" = 'bw' ]; then
    # Matlab settings
    MATLAB_WORKING_DIR="/scratch/sciteam/GS_bazu/mosaic_data/matlab_working_dir"
    MATLAB_TEMP_DIR="/scratch/sciteam/GS_bazu/mosaic_data/matlab_temp_dir"
    MATLAB_PROGRAM="/projects/sciteam/bazu/matlab/R2020a/bin/matlab"
#    export LD_LIBRARY_PATH="/projects/sciteam/bazu/matlab/lib-GLIBC2.12:${LD_LIBRARY_PATH}"
    export MATLABHOST=$(printf 'nid%05d' "$(head -n1 "$PBS_NODEFILE")")
    export LM_LICENSE_FILE="27000@matlab-pgc.cse.umn.edu"
    MATLAB_SETTINGS="-nodisplay -nodesktop -nosplash"
    MATLAB_USE_PARPOOL=true

#    # Load Python/GDAL env if needed
#    set +u
#    source /projects/sciteam/bazu/tools/miniconda3/bin/activate /projects/sciteam/bazu/tools/miniconda3/envs/gdal2
#    export PATH="${PATH}:/projects/sciteam/bazu/tools/miniconda3/envs/gdal2/bin/"
#    export GDAL_SKIP="JP2OpenJPEG"
#    set -u

    # Site-specific settings
    if grep -q '^SWIFT_WORKER_PID='; then
        echo "BST qsub script is in a Swift job"
    else
        echo "BST qsub script is not in a Swift job"
        if [ "$already_in_aprun" = true ]; then
            echo "BST qsub script is already in aprun"
        else
            echo "BST qsub script is not already in aprun"
            APRUN_PREFIX="aprun -b -N 1 -d ${CORES_PER_NODE} -cc none --"
        fi
    fi
    #export CRAY_ROOTFS=SHIFTER
    #export UDI="ubuntu:xenial"
    #echo
    #echo "CRAY_ROOTFS=$CRAY_ROOTFS"
    #echo "UDI=$UDI"
    #echo
fi


if [ "$MATLAB_USE_PARPOOL" = true ]; then
    job_working_dir="${MATLAB_WORKING_DIR}"
    job_temp_dir="${MATLAB_TEMP_DIR}/${JOB_ID}/${tileName}"
    matlab_parpool_init="\
pc = parcluster('local'); \
pc.JobStorageLocation = '${job_temp_dir}'; \
pc.NumWorkers = ${CORES_PER_NODE}; \
parpool(pc, ${CORES_PER_NODE});"
else
    job_working_dir="$MATLAB_TEMP_DIR"
    job_temp_dir="$MATLAB_TEMP_DIR"
    matlab_parpool_init="\
ps = parallel.Settings; \
ps.Pool.AutoCreate = false;"
fi


matlab_cmd="\
addpath('${scriptdir}'); addpath('${libdir}'); \
${matlab_parpool_init} \
run_buildSubTiles(\
'${tileName}','${outDir}',${resolution},\
'${projection}','${tileDefFile}',\
'${stripDatabaseFile}','${stripsDirectory}',\
'${waterTileDir}','${refDemFile}',\
'${tileqcDir}','${tileParamListFile}',\
'${dateFiltStart}','${dateFiltEnd}',\
${make2m}); \
warning('off'); \
disp('End of matlab command run from qsub_buildSubTiles.sh'); exit();"
# Turning off all warnings at the end of the Matlab command is to avoid this error on Rookery:
#
#Warning: Error occurred while executing the listener callback for event
#ObjectBeingDestroyed defined for class parallel.settings.Profile:
#Invalid or deleted object.
#
#Error in parallel.Cluster/handleProfileDeleted (line 439)
#            obj.ProfileObject = parallel.settings.Profile.empty();
#
#Error in parallel.Cluster>@(~,~)obj.handleProfileDeleted() (line 434)
#                    @(~, ~) obj.handleProfileDeleted() );


task_cmd="${MATLAB_PROGRAM} ${MATLAB_SETTINGS} -r \"${matlab_cmd}\""
if [ "$system" = 'bw' ]; then
    task_cmd="${APRUN_PREFIX} bash -c '\
export LD_LIBRARY_PATH=\"/projects/sciteam/bazu/matlab/lib-GLIBC2.12:\${LD_LIBRARY_PATH}\"; \
$(echo "$task_cmd" | sed "s|'|'\"'\"'|g");'"
fi


# Move to working folder.
# Working folder should be empty to reduce Matlab startup time.
if [ ! -d "$job_working_dir" ]; then
    mkdir -p "$job_working_dir"
fi
if [ ! -d "$job_temp_dir" ]; then
    mkdir -p "$job_temp_dir"
fi
cd "$job_working_dir"
cd_status=$?
if (( cd_status != 0 )); then
    echo "Failed to change to working dir: ${job_working_dir}"
    exit 0
fi

cwd=$(pwd)
echo "CWD: ${cwd}"
echo

echo "logfile: ${logfile}"
echo "finfile: ${finfile}"
echo

echo "Task CMD: ${task_cmd}"
echo
time eval "$task_cmd" 2>&1 | tee "$logfile"
task_return_code=$?

echo
echo "Task return code: ${task_return_code}"
if [ ! -f "$logfile" ]; then
    log_error="ERROR! Logfile does not exist: ${logfile}"
    echo "Cannot check logfile for potential errmsgs from task"
else
    log_error=$(grep -i -m1 'error' "$logfile")
    if [ -n "$log_error" ]; then
        echo "Found errmsg in logfile (${logfile}):"
        echo "$log_error"
    else
        echo "Found no errmsg in logfile (${logfile})"
    fi
fi

# Create finfile if Matlab command exited without error
if (( task_return_code == 0 )) && [ -z "$log_error" ]; then
    echo -e "\nConsidering run successful due to [task return code of zero] AND [no errmsgs found in logfile]"
    echo "Creating finfile: ${finfile}"
    touch "$finfile"
    exit_status=2
else
    echo -e "\nConsidering run unsuccessful due to either [non-zero task return code] OR [logfile DNE] OR [errmsgs found in logfile]"
    echo "Will not create finfile"
    exit_status=1
fi

echo
if [ "$MATLAB_USE_PARPOOL" = true ] && [ -d "$job_temp_dir" ]; then
    echo "Removing Matlab temp dir for parallel tasks: ${job_temp_dir}"
    sleep 10s
    rm -rf "$job_temp_dir"
fi

echo "Done"
exit "$exit_status"
