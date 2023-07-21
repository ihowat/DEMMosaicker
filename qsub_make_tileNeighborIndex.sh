#!/bin/bash

#PBS -l walltime=40:00:00,nodes=1:ppn=2,mem=8gb
#PBS -m n
#PBS -k oe
#PBS -j oe
#PBS -q old

echo ________________________________________________________
echo
echo PBS Job Log
echo Start time: $(date)
echo
echo Job name: $PBS_JOBNAME
echo Job ID: $PBS_JOBID
echo Submitted by user: $USER
echo User effective group ID: $(id -ng)
echo
echo Hostname of submission: $PBS_O_HOST
echo Submitted to cluster: $PBS_SERVER
echo Submitted to queue: $PBS_QUEUE
echo Requested nodes per job: $PBS_NUM_NODES
echo Requested cores per node: $PBS_NUM_PPN
echo Requested cores per job: $PBS_NP
echo Node list file: $PBS_NODEFILE
echo Nodes assigned to job: $(cat $PBS_NODEFILE)
echo Running node index: $PBS_O_NODENUM
echo
echo Running on hostname: $HOSTNAME
echo Parent PID: $PPID
echo Process PID: $$
echo
echo Working directory: $PBS_O_WORKDIR
echo ________________________________________________________
echo

cd "$PBS_O_WORKDIR"

#module load gdal/2.1.3
module load matlab/2019a

## Arguments/Options
#org='osu'
org='pgc';
tiledir="$ARG_TILE_ROOTDIR"
resolution="$ARG_RESOLUTION"

set -uo pipefail

if [ -n "$tiledir" ]; then
    # Make sure this is an absolute path
    tiledir=$(readlink -f "$tiledir")
else
    tiledir="/mnt/pgc/data/elev/dem/setsm/REMA/mosaic/v2/results/output_tiles/"
#    tiledir="/mnt/pgc/data/elev/dem/setsm/REMA/mosaic/v2/results/output_tiles_testing/"
fi
if [ -z "$resolution" ]; then
    resolution='10m';
    resolution='2m';
fi

if [ ! -d "$tiledir" ]; then
    echo "Root tiledir does not exist: ${tiledir}"
    exit 1
fi

tile_index_dir="${tiledir}/../tile_index_files/$(basename "$tiledir")"
tile_index_file="${tile_index_dir}/tileNeighborIndex_${resolution}.mat"

mkdir -p "$tile_index_dir"

matlab_cmd="try; addpath('/mnt/pgc/data/common/repos/setsm_postprocessing4'); tileNeighborIndex('${tiledir}', 'org','${org}', 'resolution','${resolution}', 'outfile','${tile_index_file}'); catch e; disp(getReport(e)); exit(1); end; exit(0)"
#matlab_cmd="try; addpath('/mnt/pgc/data/scratch/erik/repos/setsm_postprocessing4'); tileNeighborIndex('${tiledir}', 'org','${org}', 'resolution','${resolution}', 'outfile','${tile_index_file}'); catch e; disp(getReport(e)); exit(1); end; exit(0)"

echo "Argument tile directory: ${tiledir}"
echo "Matlab command: \"${matlab_cmd}\""

time matlab -nojvm -nodisplay -nosplash -r "$matlab_cmd"
