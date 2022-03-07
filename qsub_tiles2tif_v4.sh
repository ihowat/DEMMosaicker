#!/bin/bash

#PBS -l walltime=40:00:00,nodes=1:ppn=4,mem=24gb
#PBS -m n
#PBS -k oe
#PBS -j oe
#PBS -q batch

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

cd $PBS_O_WORKDIR

#module load gdal/2.1.3
source ~/.bashrc; conda activate pgc
module load matlab/2019a

echo $p1
echo $p2
echo $p3
echo $p4
echo $p5

if [ "${p5}" == "false" ]; then
    echo "Building tifs and meta files"
    cmd="addpath('${p1}'); addpath('${p4}'); writeTileToTifv4('${p2}','${p3}','outRasterType','COG'); tileMetav4('${p2}'); exit"

else
    echo "Building meta files only"
    cmd="addpath('${p1}'); addpath('${p4}'); tileMetav4('${p2}'); exit"

fi

echo $cmd
time matlab -nojvm -nodisplay -nosplash -r "${cmd}"
