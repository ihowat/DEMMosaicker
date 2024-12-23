#!/usr/bin/env python

import argparse
import glob
import math
import os
import socket
import subprocess
import sys
import time
import warnings
from collections import namedtuple
from datetime import datetime

SCRIPT_FILE = os.path.abspath(os.path.realpath(__file__))
SCRIPT_FNAME = os.path.basename(SCRIPT_FILE)
SCRIPT_NAME, SCRIPT_EXT = os.path.splitext(SCRIPT_FNAME)
SCRIPT_DIR = os.path.dirname(SCRIPT_FILE)
HOME_DIR = os.path.expanduser('~/')


## General argument defaults and settings
default_matlab_scriptdir = os.path.join(SCRIPT_DIR, '../setsm_postprocessing4')
default_jobscript = os.path.join(SCRIPT_DIR, 'qsub_mosaicSubTiles.sh')
batch_jobscript = os.path.join(SCRIPT_DIR, 'qsub_batchRunTiles.sh')
default_tempdir = os.path.join(SCRIPT_DIR, 'temp')
default_logdir = '../logs/[DSTDIR_FOLDER_NAME]'  # relative path appended to argument dstdir
swift_program = os.path.abspath('/projects/sciteam/bazu/tools/swift-2/bin/swift')
swift_rundir = '/scratch/sciteam/GS_bazu/user/{}/swiftruns'.format(os.environ['USER'])
swift_config = os.path.join(SCRIPT_DIR, 'swift.conf')
swift_script = os.path.join(SCRIPT_DIR, 'mosaic.swift')
swift_site = 'mst'


## System-specific settings
hostname = socket.gethostname().lower()
if hostname.startswith('h2o'):
    system_name = 'bw'
    sched_presubmit_cmd = 'export NOAPRUNWARN=1'
    sched_addl_envvars = "CRAY_ROOTFS=SHIFTER,UDI='ubuntu:xenial'"
    sched_specify_outerr_paths = True
    sched_addl_vars = "-l nodes=1:ppn=16:xe,gres=shifter,walltime=96:00:00 -m n -j oe"
    sched_default_queue = 'normal'
elif hostname.startswith('nunatak'):
    system_name = 'pgc'
    sched_presubmit_cmd = ''
    sched_addl_envvars = ''
    sched_specify_outerr_paths = False
    sched_addl_vars = "-l walltime=100:00:00,nodes=1:ppn=8,mem=48gb -m n -k oe -j oe"
    sched_default_queue = 'old'
elif hostname.startswith('pgc-comp'):
    system_name = 'pgc'
    sched_presubmit_cmd = ''
    sched_addl_envvars = ''
    sched_specify_outerr_paths = False
    sched_addl_vars = f"--nodes=1 --ntasks=1 --cpus-per-task=12 --mem=60G --time=100:00:00 -o {HOME_DIR}/%x.o%j -e {HOME_DIR}/%x.o%j"
    sched_default_queue = 'batch'
else:
    warnings.warn("Hostname '{}' not recognized. System-specific settings will not be applied.".format(hostname))
    system_name = ''
    sched_presubmit_cmd = ''
    sched_addl_envvars = ''
    sched_specify_outerr_paths = False
    sched_addl_vars = ''
    sched_default_queue = None


## Argument defaults by 'project'

project_choices = [
    'arcticdem',
    'rema',
    'earthdem',
]

epsg_projstr_dict = {
    None: '',
    3413: 'polar stereo north',
    3031: 'polar stereo south',
}
project_epsg_dict = {
    'arcticdem': 3413,
    'earthdem':  None,
    'rema':      3031,
}

earthdem_hemisphere_key = '<hemisphere>'
project_tileDefFile_dict = {
    'arcticdem': '/mnt/pgc/data/projects/earthdem/tiledef_files/PGC_Imagery_Mosaic_Tiles_Arctic.mat',
    'rema':      '/mnt/pgc/data/projects/earthdem/tiledef_files/rema_tile_definitions.mat',
    'earthdem':  '/mnt/pgc/data/projects/earthdem/tiledef_files/PGC_UTM_Mosaic_Tiles_{}.mat'.format(earthdem_hemisphere_key),
}
project_tileParamList_dict = {
    'arcticdem': '/mnt/pgc/data/elev/dem/setsm/ArcticDEM/mosaic/v4.1/tile_params/tileParamList.txt',
    'rema':      '/mnt/pgc/data/elev/dem/setsm/REMA/mosaic/v2/tile_params/tileParamList_v13e.txt',
    'earthdem':  '',
}
project_version_dict = {
    'arcticdem': 'ArcticDEM,4.1',
    'rema': 'REMA,2.1',
    'earthdem': 'EarthDEM,1.1',
}


quads = ['1_1', '1_2', '2_1', '2_2']
Task = namedtuple('Task', 't st')


class RawTextArgumentDefaultsHelpFormatter(argparse.ArgumentDefaultsHelpFormatter, argparse.RawTextHelpFormatter): pass

def main():

    parser = argparse.ArgumentParser(
        formatter_class=RawTextArgumentDefaultsHelpFormatter
    )
    parser.add_argument("srcdir", help="source root dir (where tile subfolders exist)")
    parser.add_argument("tiles",
        help=' '.join([
            "list of mosaic tiles; either specified on command line (comma delimited),",
            "or a text file list (each tile on separate line)"
        ])
    )
    parser.add_argument("res", type=int, choices=[2, 10], help="resolution in meters (2 or 10)")

    parser.add_argument("--project", default=None, choices=project_choices,
                        help="sets the default value of project-specific arguments")
    parser.add_argument("--epsg", type=int, default=None, choices=list(epsg_projstr_dict.keys()),
                        help="output mosaic tile projection EPSG code (default is {})".format(
                            ', '.join(["{} if --project={}".format(val, dom) for dom, val in project_epsg_dict.items()])
                        ))
    parser.add_argument("--tile-def", default=None,
                        help="mosaic tile definition mat file (default is {})".format(
                            ', '.join(["{} if --project={}".format(val, dom) for dom, val in project_tileDefFile_dict.items()])
                        ))
    parser.add_argument("--tileparam-list", default=None,
                        help="tile parameters text file (default is {})".format(
                            ', '.join(["{} if --project={}".format(val, dom) for dom, val in project_tileParamList_dict.items()])
                        ))
    parser.add_argument("--version", default=None,
                        help="mosaic version (default is {})".format(
                            ', '.join(["{} if --project={}".format(val, dom) for dom, val in project_version_dict.items()])
                        ))

    parser.add_argument("--libdir", default=default_matlab_scriptdir,
                        help="path to referenced Matlab functions (default={}".format(default_matlab_scriptdir))

    parser.add_argument('--quads', action='store_true', default=False,
            help="build into quad subtiles")
    parser.add_argument('--export-tif', action='store_true', default=False,
        help=' '.join([
            "export all tile result .tif rasters and meta.txt files at end of MST process,",
            "else finish after creating tile result .mat file and browse .tif files only"
        ])
    )

    parser.add_argument('--bypass-quads-error', action='store_true', default=False,
            help="allow non-standard resolution-quads settings")
    parser.add_argument('--bypass-bst-finfile-req', action='store_true', default=False,
            help="do not require BST finfiles exist before mosaicking tiles")
    parser.add_argument('--relax-bst-finfile-req', action='store_true', default=False,
            help="allow mosaicking tiles with no BST finfile if 10,000-th subtile exists")
    # parser.add_argument('--require-mst-finfiles', action='store_true', default=False,
    #         help="let existence of MST finfiles dictate reruns")
    parser.add_argument('--bypass-mst-finfile-req', action='store_true', default=False,
            help="upon rerun, deem tiles complete when MST results exist even though MST finfile does not exist")

    parser.add_argument("--jobscript", default=default_jobscript,
            help="jobscript used in task submission (default={})".format(default_jobscript))
    parser.add_argument("--chain-mst-jobscript", default=None,
            help="filled-out MST jobscript, this arg should only be used by BST --chain-mst option")
    parser.add_argument("--tempdir", default=default_tempdir,
            help="directory where filled-out running copy of jobscript is created (default={})".format(default_tempdir))
    parser.add_argument("--logdir", default=default_logdir,
            help="directory where logfiles for Matlab tile processing are created (default is {} from srcdir)".format(default_logdir))
    parser.add_argument("--make-2m-logdirs", action='store_true', default=False,
            help="create 2m logdir directories if they do not exist")

    parser.add_argument("--queue", default=sched_default_queue,
            help="queue for scheduler submission")
    parser.add_argument("--pbs", action='store_true', default=False,
            help="submit tasks to PBS")
    parser.add_argument("--slurm", action='store_true', default=False,
            help="submit tasks to SLURM")
    parser.add_argument("--swift", action='store_true', default=False,
            help="submit tasks with Swift")
    parser.add_argument("--swift-program", default=swift_program,
            help="path to Swift executable (default={})".format(swift_program))
    parser.add_argument("--swift-logdir", default=None,
            help="directory where output job logs from Swift will go (default is ../logs/ from dstdir)")

    parser.add_argument("--tasks-per-job", type=int, default=1,
            help="Number of tiles to run in a single PBS or Slurm job")
    parser.add_argument("--submit", action='store_true', default=False,
            help="Submit tasks. If this option is not provided, --dryrun is automatically applied.")
    parser.add_argument("--test-submit", action='store_true', default=False,
            help="Print tile-submission commands without executing")
    parser.add_argument("--dryrun", action='store_true', default=False,
            help="Print actions without executing")
    parser.add_argument("--write-jobscript-and-exit", action='store_true', default=False,
            help="Write filled-out running copy of jobscript and then exit")

    args = parser.parse_args()
    if (args.submit or args.test_submit) and (not args.dryrun):
        real_submit = True
    else:
        real_submit = False

    if args.tiles.lower().endswith(('.txt', '.csv')) or os.path.isfile(args.tiles):
        tilelist_file = args.tiles
        if not os.path.isfile(args.tiles):
            parser.error("'tiles' argument tilelist file does not exist: {}".format(tilelist_file))
        with open(tilelist_file, 'r') as tilelist_fp:
            tiles = [line for line in tilelist_fp.read().splitlines() if line != '']
    else:
        tiles = args.tiles.split(',')
    tiles = sorted(list(set(tiles)))

    target_res = '10m' if args.res == 10 else '2m'

    quads_errmsg = None
    if args.res == 2 and not args.quads:
        quads_errmsg = "!!! {} !!! --quads argument should be provided when res is 2m".format(
            'WARNING' if args.bypass_quads_error else 'ERROR'
        )
    elif args.res == 10 and args.quads:
        quads_errmsg = "!!! {} !!! --quads argument should not be provided when res is 10m".format(
            'WARNING' if args.bypass_quads_error else 'ERROR'
        )
    if quads_errmsg is not None:
        print(quads_errmsg)
        if not args.bypass_quads_error:
            print("Provide the --bypass-quads-error argument to use non-standard resolution-quads settings")
            sys.exit(1)

    if args.tasks_per_job > 1:
        if not (args.pbs or args.slurm):
            parser.error("--tasks-per-job > 1 can only be provided in addition to"
                         " --pbs or --slurm scheduler job submission options")
        batch_job_submission = True
    else:
        batch_job_submission = False

    ## Set default arguments by project setting
    if args.project is None and True in [arg is None for arg in [args.epsg, args.tile_def, args.version]]:
        parser.error("--project arg must be provided if one of the following arguments is not provided: {}".format(
            ' '.join(["--epsg", "--tile-def", "--version"])
        ))
    if args.epsg is None:
        args.epsg = project_epsg_dict[args.project]
    projection_string = epsg_projstr_dict[args.epsg]
    if args.tile_def is None:
        args.tile_def = project_tileDefFile_dict[args.project]
    if args.tileparam_list is None:
        args.tileparam_list = project_tileParamList_dict[args.project]
    if args.version is None:
        args.version = project_version_dict[args.project]

    ## Convert argument paths to absolute paths
    args.srcdir = os.path.abspath(args.srcdir)
    if args.tile_def != '':
        args.tile_def = os.path.abspath(args.tile_def if os.path.isfile(args.tile_def) else os.path.join(SCRIPT_DIR, args.tile_def))
    if args.tileparam_list != '':
        args.tileparam_list = os.path.abspath(args.tileparam_list if os.path.isfile(args.tileparam_list) else os.path.join(SCRIPT_DIR, args.tileparam_list))
    args.libdir = os.path.abspath(args.libdir)
    args.tempdir = os.path.abspath(args.tempdir)
    args.logdir = os.path.abspath(os.path.join(args.srcdir, args.logdir) if args.logdir.startswith('../') else args.logdir)
    if '[DSTDIR_FOLDER_NAME]' in args.logdir:
        args.logdir = args.logdir.replace('[DSTDIR_FOLDER_NAME]', os.path.basename(args.srcdir))

    ## Verify path arguments
    if not os.path.isdir(args.srcdir):
        parser.error("srcdir does not exist: {}".format(args.srcdir))
    if args.project != 'earthdem':
        if not os.path.isfile(args.tile_def):
            parser.error("--tile-def file does not exist: {}".format(args.tile_def))
    if args.tileparam_list != '' and not os.path.isfile(args.tileparam_list):
        parser.error("--tileparam-list file does not exist: {}".format(args.tileparam_list))
    if not os.path.isdir(args.libdir):
        parser.error("--libdir does not exist: {}".format(args.libdir))
    if not os.path.isfile(args.jobscript):
        parser.error("--jobscript does not exist: {}".format(args.jobscript))
    if args.chain_mst_jobscript is not None and not os.path.isfile(args.chain_mst_jobscript):
        parser.error("--chain-mst-jobscript does not exist: {}".format(args.chain_mst_jobscript))

    ## Verify other arguments
    if [args.pbs, args.slurm, args.swift].count(True) > 1:
        parser.error("--pbs --slurm --swift are mutually exclusive")
    if args.bypass_bst_finfile_req and args.relax_bst_finfile_req:
        parser.error("--bypass-bst-finfile-req and --relax-bst-finfile-req arguments are mutually exclusive")

    res_list = [target_res]
    if args.make_2m_logdirs and target_res != '2m':
        res_list.insert(0, '2m')
    log_time = datetime.now().strftime("%Y%m%d%H%M%S")
    for res in res_list:
        template_mst_logdir = os.path.join(args.logdir, 'matlab', 'mst', res)
        mst_logdir = os.path.join(args.logdir, 'matlab', 'mst', res)
        pbs_logdir = os.path.join(args.logdir, 'pbs', 'mst', res)
        if batch_job_submission and res == target_res:
            pbs_logdir = '{}_batch_{}_{}-tiles'.format(pbs_logdir, log_time, len(tiles))
        swift_logrootdir = os.path.join(args.logdir, 'swift')
        swift_logdir = os.path.join(swift_logrootdir, 'mst', res)
        swift_tasklist_dir = os.path.join(swift_logrootdir, 'tasklist')
        swift_tasklist_fname = 'mst_{}_tasklist_{}.txt'.format(res, datetime.now().strftime("%Y%m%d%H%M%S"))
        swift_tasklist_file = os.path.join(swift_tasklist_dir, swift_tasklist_fname)

        ## Create output directories
        outdir_list = [args.tempdir, mst_logdir]
        if args.pbs:
            outdir_list.append(pbs_logdir)
        if args.swift:
            outdir_list.extend([swift_rundir, swift_logdir, swift_tasklist_dir])
        if not args.dryrun:
            for outdir in outdir_list:
                if not os.path.isdir(outdir):
                    print("Creating output directory: {}".format(outdir))
                    os.makedirs(outdir)
            if batch_job_submission and res == target_res:
                pbs_batch_tilelist = os.path.join(pbs_logdir, 'tilelist.txt')
                with open(pbs_batch_tilelist, 'w') as tilelist_fp:
                    for tile in tiles:
                        tilelist_fp.write(tile+'\n')

    if args.chain_mst_jobscript is not None:
        jobscript_temp = args.chain_mst_jobscript
    else:
        ## Create temp jobscript with mosaicking args filled in
        supertilename_key = '<superTileName>'
        outtilename_key = '<outTileName>'
        resolution_key = '<resolution>'
        template_subtiledir = os.path.join(args.srcdir, supertilename_key, 'subtiles')
        template_outmatfile = os.path.join(args.srcdir, supertilename_key, "{}_{}.mat".format(outtilename_key, resolution_key))
        template_finfile = os.path.join(args.srcdir, supertilename_key, "{}_{}.fin".format(outtilename_key, resolution_key))
        template_logfile = os.path.join(os.path.join(args.logdir, 'matlab', 'mst', resolution_key), outtilename_key+'.log')
        jobscript_static_args_dict = {
            'system': system_name,
            'scriptdir': SCRIPT_DIR,
            'libdir': args.libdir,
            'tileDefFile': args.tile_def,
            'tileParamListFile': args.tileparam_list,
            'subTileDir': template_subtiledir,
            'resolution': args.res,
            'outMatFile': template_outmatfile,
            'projection': projection_string,
            'version': args.version,
            'exportTif': 'true' if args.export_tif else 'false',
            'finfile': template_finfile,
            'logfile': template_logfile,
        }
        jobscript_fname = os.path.basename(args.jobscript)
        jobscript_temp_fname = jobscript_fname.replace(
            '.sh',
            '{}_{}.sh'.format(
                '_{}'.format(args.project) if args.project is not None else '',
                datetime.now().strftime("%Y%m%d%H%M%S")
            )
        )

        jobscript_temp = os.path.join(args.tempdir, jobscript_temp_fname)
        with open(args.jobscript, 'r') as jobscript_fp:
            jobscript_text = jobscript_fp.read()

        jobscript_temp_text = jobscript_text
        for argname, argval in jobscript_static_args_dict.items():
            jobscript_argname = '"$ARG_{}"'.format(argname).upper()
            jobscript_argval = '"{}"'.format(argval)
            jobscript_temp_text = jobscript_temp_text.replace(jobscript_argname, jobscript_argval)

        print("Writing temporary jobscript file: {}".format(jobscript_temp))
        with open(jobscript_temp, 'w') as jobscript_fp:
            jobscript_fp.write(jobscript_temp_text)
        if args.write_jobscript_and_exit:
            sys.exit(0)

    tilerun_jobscript = jobscript_temp


    tiles_to_run = []

    tasks = []
    if len(tiles) > 0:
        for tile in tiles:
            if args.quads:
                for quad in quads:
                    tasks.append(Task(tile, quad))
            else:
                tasks.append(Task(tile, 'null'))

    print("{} {}tiles to check".format(len(tasks), 'quad-' if args.quads else ''))

    error_messages = []
    supertile_num_nodata_dict = dict()

    if len(tasks) > 0:
        for task in tasks:
            tile = task.t
            if task.st != 'null':
                outtile = "{}_{}".format(task.t, task.st)
            else:
                outtile = tile

            tile_projstr = projection_string
            tile_def = args.tile_def

            if tile.startswith('utm'):
                if args.project != 'earthdem':
                    parser.error("project should be 'earthdem' when 'utm*' prefix tilenames are provided")
            else:
                if args.project == 'earthdem':
                    parser.error("domain should NOT be 'earthdem' when tilenames do not have 'utm*' prefix")

            if tile_projstr == '' or earthdem_hemisphere_key in tile_def:
                assert args.project == 'earthdem'

                utm_tilename_parts = tile.split('_')
                utm_tilename_prefix = utm_tilename_parts[0]
                if not utm_tilename_prefix.startswith('utm'):
                    parser.error("Expected only UTM tile names (e.g. 'utm10n_01_01'), but got '{}'".format(tile))

                if tile_projstr == '':
                    tile_projstr = utm_tilename_prefix

                if earthdem_hemisphere_key in tile_def:
                    if utm_tilename_prefix.endswith('n'):
                        hemisphere = 'North'
                    elif utm_tilename_prefix.endswith('s'):
                        hemisphere = 'South'
                    else:
                        parser.error("UTM tile name prefix does not end with 'n' or 's' (e.g. 'utm10n'): {}".format(tile))

                    tile_def = tile_def.replace(earthdem_hemisphere_key, hemisphere)
                    if not os.path.isfile(tile_def):
                        parser.error("Tile definition file does not exist: {}".format(tile_def))

            if task.st == 'null':
                dstfn = "{}_{}m.mat".format(task.t, args.res)
            else:
                dstfn = "{}_{}_{}m.mat".format(task.t, task.st, args.res)
            dstfp = os.path.join(args.srcdir, task.t, dstfn)
            finfile = os.path.join(args.srcdir, task.t, dstfn.replace('.mat', '.fin'))
            subtile_dir = os.path.join(args.srcdir, task.t, 'subtiles')

            run_tile = True
            removing_existing_output = False

            mst_finfile = finfile
            bst_final_subtile_fp = os.path.join(subtile_dir, '{}_10000_{}m.mat'.format(task.t, args.res))
            bst_finfile_10m = "{}_10m.fin".format(subtile_dir)
            bst_finfile_2m = "{}_2m.fin".format(subtile_dir)
            if args.res == 10:
                bst_finfile = bst_finfile_10m
            elif args.res == 2:
                bst_finfile = bst_finfile_2m

            if (not args.bypass_bst_finfile_req) and (not any([os.path.isfile(f) for f in [bst_finfile, bst_finfile_2m]])):
                if args.relax_bst_finfile_req and os.path.isfile(bst_final_subtile_fp):
                    message = "WARNING! BST finfile ({}) does not exist for tile {}, but 10,000-th subtile exists so may run".format(bst_finfile, dstfn)
                    print(message)
                else:
                    message = "ERROR! BST finfile ({}) does not exist, skipping {}".format(bst_finfile, dstfn)
                    print(message)
                    error_messages.append(message)
                    if os.path.isfile(bst_final_subtile_fp):
                        message = "  (but 10,000-th subtile exists; can provide --relax-bst-finfile-req argument to run this tile anyways)"
                        print(message)
                        error_messages.append(message)
                    run_tile = False
            else:
                for bst_finfile_temp in list({bst_finfile, bst_finfile_2m, bst_final_subtile_fp}):
                    if os.path.isfile(bst_finfile_temp):
                        message = None
                        if os.path.isfile(mst_finfile) and (os.path.getmtime(bst_finfile_temp) > os.path.getmtime(mst_finfile)):
                            message = "BST finfile ({}) is newer than MST finfile ({}), so existing results will be removed".format(bst_finfile_temp, mst_finfile)
                            removing_existing_output = True
                        elif os.path.isfile(dstfp) and (os.path.getmtime(bst_finfile_temp) > os.path.getmtime(dstfp)):
                            message = "BST finfile ({}) is newer than MST output ({}), so existing results will be removed".format(bst_finfile_temp, dstfp)
                            removing_existing_output = True
                        if message is not None:
                            print(message)
                            error_messages.append(message)

            # if os.path.isfile(dstfp) and args.require_mst_finfiles:
            if os.path.isfile(dstfp) and not args.bypass_mst_finfile_req:
                if not os.path.isfile(finfile):
                    message = "WARNING! MST finfile ({}) does not exist, so existing results will be removed".format(finfile)
                    print(message)
                    error_messages.append(message)
                    removing_existing_output = True

            if removing_existing_output:
                if not os.path.isdir(subtile_dir):
                    message = "ERROR! Subtile directory ({}) does not exist, skipping {}".format(subtile_dir, dstfn)
                    print(message)
                    error_messages.append(message)
                    continue

                dstfps_old_pattern = dstfp.replace('.mat', '*')
                dstfps_old = glob.glob(dstfps_old_pattern)
                if dstfps_old:
                    print("{}Removing old MST results matching {}".format('(dryrun) ' if not real_submit else '', dstfps_old_pattern))
                    if real_submit:
                        for dstfp_old in dstfps_old:
                            os.remove(dstfp_old)
                run_tile = True

            else:
                # if os.path.isfile(dstfp) and not args.require_mst_finfiles:
                if os.path.isfile(dstfp) and args.bypass_mst_finfile_req:
                    print("Output exists, skipping {}".format(dstfn))
                    run_tile = False
                elif os.path.isfile(finfile):
                    print("finfile exists, skipping {}".format(dstfn))
                    run_tile = False
                    if not os.path.isfile(dstfp):
                        message = "WARNING! MST finfile exists ({}) but expected output does not exist ({}) for tile {}".format(
                            finfile, dstfp, dstfn
                        )
                        # print(message)
                        if task.t not in supertile_num_nodata_dict:
                            supertile_num_nodata_dict[task.t] = 0
                        supertile_num_nodata_dict[task.t] += 1

            if run_tile:
                if not os.path.isdir(subtile_dir):
                    message = "ERROR! Subtile directory ({}) does not exist, skipping {}".format(subtile_dir, dstfn)
                    print(message)
                    error_messages.append(message)
                    continue
                tiles_to_run.append(outtile)

    task_success_rc = 3 if len(tiles_to_run) > 0 else -1
    matlab_cmd_success = None

    ran_tiles = False
    if len(tiles_to_run) > 0 and (args.submit or args.test_submit):
        ran_tiles = True

        print("Running {} {}tiles".format(len(tiles_to_run), 'quad-' if args.quads else ''))

        if not args.test_submit:
            sleep_seconds = 10
            print("Sleeping {} seconds before job submission".format(sleep_seconds))
            time.sleep(sleep_seconds)

        if args.swift:
            with open(swift_tasklist_file, 'w') as swift_tasklist_fp:
                for tile in tiles_to_run:
                    swift_tasklist_fp.write(tile+'\n')
            swift_cmd = r""" "{}" -config "{}" -sites {},local "{}" -tasklist_file="{}" -jobscript="{}" -task_description="{}" -logdir="{}" """.format(
                swift_program,
                swift_config,
                swift_site,
                swift_script,
                swift_tasklist_file,
                jobscript_temp,
                "tiles to run",
                swift_logdir,
            )
            print("Running Swift command: {}".format(swift_cmd))
            if not args.dryrun:
                subprocess.call(swift_cmd, shell=True, cwd=swift_rundir)
            print("Ran {} tiles".format(len(tiles_to_run)))

        else:

            jobnum_total = int(math.ceil(len(tiles_to_run) / float(args.tasks_per_job)))
            jobnum_fmt = '{:0>'+str(min(3, len(str(jobnum_total))))+'}'

            for jobnum, task_start_idx in enumerate(range(0, len(tiles_to_run), args.tasks_per_job), 1):

                tile_bundle = tiles_to_run[task_start_idx:task_start_idx+args.tasks_per_job]
                if batch_job_submission:
                    tile = None
                    task_name = jobnum_fmt.format(jobnum)
                else:
                    tile = tiles_to_run[task_start_idx]
                    task_name = tile
                job_name = 'mst_{}'.format(task_name)
                job_outfile = os.path.join(pbs_logdir, task_name+'.out')
                job_errfile = os.path.join(pbs_logdir, task_name+'.err')

                if args.pbs:
                    cmd = r""" {}qsub -N {} --export {}{}ARG_TILENAME={}{} {} {} {} "{}" """.format(
                        sched_presubmit_cmd+' ; ' if sched_presubmit_cmd != '' else '',
                        job_name,
                        'TILERUN_JOBSCRIPT="{}",'.format(tilerun_jobscript) if batch_job_submission else '',
                        'IN_PARALLEL=false,' if batch_job_submission else '',
                        '@'.join(tile_bundle) if batch_job_submission else tile,
                        ','+sched_addl_envvars if sched_addl_envvars else '',
                        '-q {}'.format(args.queue) if args.queue else '',
                        '-o "{}" -e "{}"'.format(job_outfile, job_errfile) if sched_specify_outerr_paths else '',
                        sched_addl_vars,
                        batch_jobscript if batch_job_submission else tilerun_jobscript,
                    )

                elif args.slurm:
                    job_outfile = job_outfile.replace('pbs', 'slurm')
                    job_errfile = job_errfile.replace('pbs', 'slurm')
                    cmd = r""" {}sbatch -J {} --export {}{}ARG_TILENAME={}{} {} {} {} "{}" """.format(
                        sched_presubmit_cmd+' ; ' if sched_presubmit_cmd != '' else '',
                        job_name,
                        'TILERUN_JOBSCRIPT="{}",'.format(tilerun_jobscript) if batch_job_submission else '',
                        'IN_PARALLEL=false,' if batch_job_submission else '',
                        '@'.join(tile_bundle) if batch_job_submission else tile,
                        ','+sched_addl_envvars if sched_addl_envvars else '',
                        '--partition {}'.format(args.queue) if args.queue else '',
                        '-o "{}" -e "{}"'.format(job_outfile, job_errfile) if sched_specify_outerr_paths else '',
                        sched_addl_vars,
                        batch_jobscript if batch_job_submission else tilerun_jobscript,
                    )

                else:
                    cmd = r""" bash "{}" {} """.format(
                        jobscript_temp,
                        tile,
                    )

                print("{}, {}".format(jobnum, cmd))
                if not args.dryrun:
                    matlab_cmd_rc = subprocess.call(cmd, shell=True, cwd=(pbs_logdir if args.pbs else None))
                    if matlab_cmd_rc == 2 and matlab_cmd_success is not False:
                        matlab_cmd_success = True
                    else:
                        matlab_cmd_success = False

            if args.pbs or args.slurm:
                print("Submitted {} {}tiles to scheduler".format(len(tiles_to_run), 'quad-' if args.quads else ''))
            else:
                print("Ran {} {}tiles".format(len(tiles_to_run), 'quad-' if args.quads else ''))


    if error_messages:
        print('----')
        print("The following error messages were received")
        print('----')
        for errmsg in error_messages:
            print(errmsg)
        print('----')

    inspect_tiles = []
    for tile, num_nodata in supertile_num_nodata_dict.items():
        if (args.quads and num_nodata == 4) or (not args.quads and num_nodata > 0):
            inspect_tiles.append(tile)

    if inspect_tiles:
        print('-----')
        print("{} tiles have all MST finfiles but no output mosaic results!".format(len(inspect_tiles)))
        print("Please investigate why these tiles produce no results!!")
        print(','.join(inspect_tiles))
        print('-----')
        print("Checking those {} super-tiles for existence of subtile results...".format(len(inspect_tiles)))
        for tile in inspect_tiles:
            subtile_dir = os.path.join(args.srcdir, tile, 'subtiles')
            if not glob.glob(os.path.join(subtile_dir, '{}_*_{}m.*'.format(tile, args.res))):
                print("ERROR! No {}m results exist in subtile directory for tile {}: {}".format(args.res, tile, subtile_dir))
        print('-----')


    print("{} {}tiles are incomplete and {} (re)submitted".format(
        len(tiles_to_run),
        'quad-' if args.quads else '',
        'were' if ran_tiles else 'need to be'
    ))

    if len(tiles_to_run) > 0 and not args.submit:
        print("Provide the --submit option to run tiles")

    if matlab_cmd_success is True:
        task_success_rc = 2
    elif matlab_cmd_success is False:
        task_success_rc = 1

    sys.exit(task_success_rc)



if __name__ == '__main__':
    main()
