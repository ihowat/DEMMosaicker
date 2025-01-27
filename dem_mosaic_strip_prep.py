import argparse
import csv
import glob
import os
import subprocess

import geopandas as gpd
import psycopg2 as pg
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(format='%(asctime)s %(message)s', level=logging.DEBUG)

project_choices = [
    'arcticdem',
    'rema',
    'earthdem',
]
project_tile_def_dict = {
    # project: (tile def shp, EPSG)
    'arcticdem': ('/mnt/pgc/data/projects/arcticdem/tiles/PGC_Imagery_Mosaic_Tiles_Arctic/PGC_Imagery_Mosaic_Tiles_Arctic.shp', 3413),
    'rema':      ('/mnt/pgc/data/projects/rema/tiles/REMA_Mosaic_Index_v2_shp/REMA_Mosaic_Index_v2_10m.shp',3013),
    'earthdem':  ('/mnt/pgc/data/projects/earthdem/tiles/EarthDEM_utm_tiles_v2.shp',None),
}

project_water_tile_dir_dict = {
    # In the water tile/mask rasters: 0=land and (1|NoData)=water
    'arcticdem': '/mnt/pgc/data/projects/arcticdem/watermasks/',
    'rema':      '',
    'earthdem':  '/mnt/pgc/data/projects/earthdem/watermasks/esa_worldcover_2021',
}

esa_worldcover_dir = '/mnt/pgc/data/thematic/landcover/esa_worldcover_2021/data/processed'
gtp_tile_def = '/mnt/pgc/data/projects/nga/trex/PGC_Package/TREx_GeoTilesPlus_globalIndex.shp'
script_dir = os.path.dirname(os.path.realpath(__file__))
script_home = os.path.dirname(script_dir)
headers = ['dem_id','stripdemid','epsg','location']


def main():
    """docstring"""

    parser = argparse.ArgumentParser(
        description="Identify and stage source DEMs for mosaicking",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
        )

    parser.add_argument("dstdir", help="target directory (where tile subfolders will be created)")
    parser.add_argument("project", default=None, choices=project_choices,
        help="sets the default value of project-specific arguments")
    parser.add_argument("tiles",
        help='list of mosaic tiles; either specified on command line (comma delimited),'
             ' or a text file list (each tile on separate line)')
    parser.add_argument("--prep-only", action="store_true", default=False,
                        help="skip  BST+MST job submission step")
    args = parser.parse_args()

    # Verify arguments
    if args.tiles.lower().endswith(('.txt', '.csv')) or os.path.isfile(args.tiles):
        tilelist_file = args.tiles
        if not os.path.isfile(args.tiles):
            parser.error("'tiles' argument tilelist file does not exist: {}".format(tilelist_file))
        with open(tilelist_file, 'r') as tilelist_fp:
            tiles = [line for line in tilelist_fp.read().splitlines() if line != '']
    else:
        tiles = args.tiles.split(',')
    tiles = sorted(list(set(tiles)))

    tile_def_tbl, epsg = project_tile_def_dict[args.project]
    results_dir = os.path.join(os.path.realpath(args.dstdir), 'results')
    src_dir = os.path.join(os.path.realpath(args.dstdir), 'src')
    reproject_list_fp = os.path.join(src_dir, "reprojection_list.txt")

    # Connect to Sandwich strip_dem_master
    conn = pg.connect("service=pgc_sandwich_dgarchive")
    cur = conn.cursor()

    # TODO: allow gtp tiles as input and ID overlapping project tiles

    # For each tile, ID geometry and target EPSG if needed
    df = gpd.read_file(tile_def_tbl)
    tile_bst = {}
    reproject_list = []
    error_msgs = []
    run_bst = False if args.prep_only else True
    i=0
    for tile in tiles:
        i+=1
        logger.info(f"Processing tile {i} of {len(tiles)}: {tile}")

        tile_dir = os.path.join(os.path.realpath(args.dstdir), 'src', tile)
        tile_strip_dir = os.path.join(tile_dir, '2m')
        tile_proj_strip_dir = os.path.join(tile_dir, '2m_proj')
        os.makedirs(tile_dir, exist_ok=True)
        dbase_out = os.path.join(tile_dir, f'{tile}_db.mat')

        # If matlab database already exists, skip the prep part
        if not os.path.isfile(dbase_out):
            strips_correct_fp = os.path.join(tile_dir, 'strips_correct.csv')
            strips_to_project_fp = os.path.join(tile_dir, 'strips_to_project.csv')
            strips_correct = []
            strips_to_project = []
            csvs = [(strips_correct, strips_correct_fp),
                    (strips_to_project, strips_to_project_fp)]
            # Derive epsg from tile name if needed
            if args.project == 'earthdem':
                tileparts = tile.split('_')
                if len(tileparts) != 3:
                    logger.error("Tile name has no utm zone preface so target projection cannot be derived")
                    continue
                utmzone = tileparts[0]
                zone = utmzone[3:5]
                hemi = utmzone[5].lower()
                hemi_val = 100 if hemi=='s' else 0
                epsg = 32600 + int(zone) + hemi_val

            # If the results already exist, read them in
            if os.path.isfile(strips_correct_fp) and os.path.isfile(strips_to_project_fp):
                with open(strips_correct_fp, 'r') as csvfile:
                    csvreader = csv.reader(csvfile, delimiter=',')
                    strips_correct = list(csvreader)[1:]
                with open(strips_to_project_fp, 'r') as csvfile:
                    csvreader = csv.reader(csvfile, delimiter=',')
                    strips_to_project = list(csvreader)[1:]

            # If no csvs exist, query sandwich
            else:
                # Get tile geometry as WKT
                df2 = df[df.name == tile]
                if len(df2) > 1:
                    error_msg = f"Tile '{tile}' has more than one record"
                    logger.error(error_msg)
                    error_msgs.append(error_msg)
                    continue

                # ID overlapping strips from strip_dem_master
                wkt = gpd.array.to_wkt(df2.geometry.values)[0]
                logger.debug(f"Tile geometry: {wkt}")
                sql_query = (f"select dem_id, stripdemid, epsg, location "
                             f"from dem.strip_dem_master sdm "
                             f"where sdm.dem_res = 2 "
                             f"and st_intersects(sdm.wkb_geometry, st_geomfromtext('{wkt}', 4326))")
                cur.execute(sql_query)
                results = cur.fetchall()
                logger.info(f"Identified {len(results)} intersecting 2m strips")

                # Split strips out by projection
                for result in results:
                    if int(result[2]) == epsg:
                        strips_correct.append(result)
                    else:
                        strips_to_project.append(result)

                # Store result in a file in case of restart
                for strip_list, csv_fp in csvs:
                    with open(csv_fp, 'w', newline='') as csvfile:
                        csvwriter = csv.writer(csvfile, delimiter=',')
                        csvwriter.writerow(headers)
                        csvwriter.writerows(strip_list)

            logger.info(f"{len(strips_correct)} strips match tile projection")
            logger.info(f"{len(strips_to_project)} strips require reprojection")

            # Link strips to staging dir if correctly projected
            logger.info(f"Linking strips to {tile_strip_dir}")
            for result in strips_correct:
                srcfile = result[3]
                src_bn = srcfile.replace('_dem.tif', '')
                srcfiles = glob.glob(src_bn + '*')
                srcdir_name = os.path.basename(os.path.dirname(srcfile))
                dstdir = os.path.join(tile_strip_dir, srcdir_name)
                os.makedirs(dstdir, exist_ok=True)
                for sf in srcfiles:
                    dstfile = os.path.join(dstdir, os.path.basename(sf))
                    if not os.path.isfile(dstfile):
                        os.link(sf, dstfile)

            # Prep strips for reprojection (if needed)
            compile_db = True
            if len(strips_to_project) > 0:
                proj_completed = glob.glob(tile_proj_strip_dir + '/*/*_meta.txt')
                if len(proj_completed) >= len(strips_to_project):
                    logger.info(f"Border strips reprojected - located in {tile_proj_strip_dir}")
                if len(proj_completed) < len(strips_to_project):
                    logger.info(f"Adding strips to reprojection list")
                    compile_db = False
                    run_bst = False
                    os.makedirs(tile_proj_strip_dir, exist_ok=True)
                    for result in strips_to_project:
                        srcfile = result[3].replace('_dem.tif','_meta.txt')
                        srcdir_name = os.path.basename(os.path.dirname(srcfile))
                        dstdir = os.path.join(tile_proj_strip_dir, srcdir_name)
                        reproject_list.append([srcfile, dstdir, epsg])

            # Compile DB
            if compile_db:
                # Check are is at least one strip to put into the DB
                if len(strips_correct) > 0 or len(strips_to_project) > 0:
                    if not os.path.isfile(dbase_out):
                        logger.info("Compiling matlab strip DB")
                        matlab_cmd = (f"matlab -nodisplay -nodesktop -nosplash -r \"addpath('{script_dir}'); "
                                      f"compileDatabase4_func('{tile_dir}', '{dbase_out}'); exit();\"")
                        logger.info(matlab_cmd)
                        subprocess.call(matlab_cmd, shell=True)
                        if not os.path.isfile(dbase_out):
                            error_msg = f"Compiling matlab strip DB failed: {dbase_out}"
                            logger.error(error_msg)
                            error_msgs.append(error_msg)

        # Add BST cmd to the list and build water tile
        if os.path.isfile(dbase_out):
            utmzone = tile.split('_')[0]
            water_tile_dir = project_water_tile_dir_dict[args.project]
            water_tile_dir = water_tile_dir if args.project != 'earthdem' else os.path.join(water_tile_dir, utmzone)

            # Build water tile if needed
            water_tile = os.path.join(water_tile_dir, f'{tile}_water.tif')
            if not os.path.isfile(water_tile):
                logger.info("Building water tile")
                os.makedirs(water_tile_dir, exist_ok=True)
                src_water_tile = os.path.join(esa_worldcover_dir, utmzone, f'{tile}_10m_esa_worldcover_2021.tif')
                water_cmd = (f'gdal_calc.py --calc "logical_and(A>=80,A<=80)" '
                             f'-A {src_water_tile} --outfile {water_tile}')
                subprocess.call(water_cmd, shell=True)
            if not os.path.isfile(water_tile):
                error_msg = f"Building water tile failed: {water_tile}"
                logger.error(error_msg)
                error_msgs.append(error_msg)

            else:
                bst_cmd = (f'python {script_dir}/batch_buildSubTiles.py {results_dir} {tile} --project {args.project}'
                           f' --strip-db {dbase_out} --water-tile-dir {water_tile_dir} --chain-mst --slurm '
                           f'--queue low_priority')
                tile_bst[tile] = bst_cmd

    # Run reprojection jobs for border strips for all affected tiles
    if len(reproject_list) > 0:
        logger.info(f"Reprojecting strips")
        with open(reproject_list_fp, 'w', newline='') as csvfile:
            csvwriter = csv.writer(csvfile, delimiter=' ')
            csvwriter.writerows(reproject_list)
        reproj_cmd = (f'python {script_home}/setsm_postprocessing_python/reproject_setsm.py {reproject_list_fp}'
                      f' --scheduler slurm --tasks-per-job 20')
        subprocess.call(reproj_cmd, shell=True)
        logger.info("Reprojection job(s) submitted.  Wait for them to complete and rerun this script.")

    else:
        if args.prep_only:
            logger.info("Work for prep-only complete. Run without --prep-only argument to submit BST+MST jobs")

    # If all tiles have reprojected strips and a matlab db, submit the BST+MST jobs
    # TODO develop check for completed tiles - currently the BST script handles this so no job is submitted (I think)
    if run_bst and len(tile_bst) > 0:
        # Query slurm to see if any tiles are running
        running_tiles = []
        cmd = os.path.expandvars('squeue -u $USER -o "%.18i %.12P %.20j %.8u %.8T %.10M %.9l %.6D %R %c"')
        piper = subprocess.Popen(cmd, stdout = subprocess.PIPE, stderr = subprocess.PIPE, shell = True)
        jobs = iter(piper.stdout.readline, "")
        _ = next(jobs)  # slurp off header line
        for line in jobs:
            pieces = line.decode().strip().split()
            if not len(pieces):
                break
            running_tiles.append(pieces[2].replace('bst_',''))
        if len(running_tiles) > 0:
            logger.info(f"Tiles already submitted: {running_tiles}")

        # Submit the tile if not already submitted
        logger.info("Submitting BST jobs")
        for tile_name, bst_cmd in tile_bst.items():
            if tile_name in running_tiles:
                logger.info(f"Tile {tile_name} already submitted")
            else:
                os.makedirs(results_dir, exist_ok=True)
                logger.info(bst_cmd)
                subprocess.call(bst_cmd, shell=True)
        logger.info("BST+MST jobs submitted.")

    # Print accumulated error messages
    if len(error_msgs) > 0:
        logger.info("Accumulated error messages and warnings:")
        for msg in error_msgs:
            logger.error(msg)


if __name__ == '__main__':
    main()