#!/bin/bash

#PBS -l walltime=40:00:00,nodes=1:ppn=2,mem=8gb
#PBS -m n
#PBS -k oe
#PBS -j oe

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
#echo Node list file: $PBS_NODEFILE
#echo Nodes assigned to job: $(cat $PBS_NODEFILE)
#echo Running node index: $PBS_O_NODENUM
echo
echo Running on hostname: $HOSTNAME
echo Parent PID: $PPID
echo Process PID: $$
echo
working_dir="$PBS_O_WORKDIR"

echo Number of physical cores: $(grep "^core id" /proc/cpuinfo | sort -u | wc -l)
echo Number of virtual cores: $(nproc --all)
mem_report_cmd="free -g"
echo "Memory report [GB] ('${mem_report_cmd}'):"
echo -------------------------------------------------------------------------
${mem_report_cmd}
echo -------------------------------------------------------------------------
echo

echo "Changing to working directory: ${working_dir}"
cd "$working_dir" || exit 1
echo

module load gdal/2.1.3
module load matlab/2019a

echo $p1
echo $p2

cmd="try; addpath('~/scratch/repos/setsm_postprocessing4'); batch_applyRegistration('/mnt/pgc/data/elev/dem/setsm/REMA/mosaic/v2/results/output_tiles_symlink_by_region','${p1}','${p2}'); catch e; disp(getReport(e)); exit(1); end; exit(0)"

echo $cmd
time matlab -nojvm -nodisplay -nosplash -r "${cmd}"

