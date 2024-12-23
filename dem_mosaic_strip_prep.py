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
gtp_tile_def = ('/mnt/pgc/data/projects/nga/trex/PGC_Package/TREx_GeoTilesPlus_globalIndex.shp')
script_dir = os.path.dirname(os.path.realpath(__file__))


def main():
    """docstring"""

    parser = argparse.ArgumentParser(
        description="Identify and stage source DEM for mosaicking",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
        )

    parser.add_argument("dstdir", help="target directory (where tile subfolders will be created)")
    parser.add_argument("project", default=None, choices=project_choices,
        help="sets the default value of project-specific arguments")
    parser.add_argument("tiles",
        help='list of mosaic tiles; either specified on command line (comma delimited),'
             ' or a text file list (each tile on separate line)')
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

    # Connect to Sandwich strip_dem_master
    conn = pg.connect("service=pgc_sandwich_dgarchive")
    cur = conn.cursor()

    # TODO: allow gtp tiles as input and ID overlapping project tiles

    # For each tile, ID geometry and target EPSG if needed
    df = gpd.read_file(tile_def_tbl)
    tile_bst = []
    for tile in tiles:
        logger.info(f"Processing tile: {tile}")

        tile_dir = os.path.join(os.path.realpath(args.dstdir), 'src', tile)

        os.makedirs(tile_dir, exist_ok=True)
        strips_correct_fp = os.path.join(tile_dir, 'strips_correct.csv')
        strips_to_project_fp = os.path.join(tile_dir, 'strips_to_project.csv')
        strips_correct = []
        strips_to_project = []
        csvs = [(strips_correct, strips_correct_fp),
                (strips_to_project, strips_to_project_fp)]
        # Derive epsg from tile name if needed
        if epsg is None:
            tileparts = tile.split('_')
            if len(tileparts) != 3:
                logger.error("Tile name has not utm zone preface so target projection cannot be derived")
                continue
            utmzone = tileparts[0]
            zone = utmzone[3:5]
            hemi = utmzone[5].lower()
            hemi_val = 100 if hemi=='s' else 0
            epsg = 32600 + int(zone) + hemi_val

        # If the results already exist, read them in
        # if os.path.isfile(strips_correct_fp):
        #     for strip_list, csv_fp in csvs:
        #
        #     with open(strips_correct_fp, 'r') as csvfile:
        #
        # else:
            # Get tile geometry as WKT
        df2 = df[df.name == tile]
        if len(df2) > 1:
            logger.error(f"Tile '{tile}' has more than one record")
            continue

        # ID overlapping strips from strip_dem_master
        wkt = gpd.array.to_wkt(df2.geometry.values)[0]
        logger.info(f"Tile geometry: {wkt}")
        sql_query = (f"select dem_id, stripdemid, epsg, location "
                     f"from dem.strip_dem_master sdm "
                     f"where sdm.dem_res = 2 and sdm.is_lsf is false "
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
        headers = ['dem_id','stripdemid','epsg','location']
        for strip_list, csv_fp in csvs:
            with open(csv_fp, 'w', newline='') as csvfile:
                csvwriter = csv.writer(csvfile, delimiter=',')
                csvwriter.writerow(headers)
                csvwriter.writerows(strip_list)

        logger.info(f"{len(strips_correct)} strips match tile projection")
        logger.info(f"{len(strips_to_project)} strips require reprojection")

        # Link strips to staging dir if correctly projected
        tile_strip_dir = os.path.join(tile_dir, '2m')
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

        # Verify all strips are present and write a semophore?

        # TODO Submit slurm task to project strips (if needed)
        # logger.info(f"Reprojecting strips - TODO")

        # If projection complete, compile DB, write semaphore - build to handle rerun
        if len(strips_to_project) == 0:
            dbase_out = os.path.join(tile_dir, f'{tile}_db.mat')
            if not os.path.isfile(dbase_out):
                logger.info("Compiling matlab strip DB")
                matlab_cmd = (f"matlab -nodisplay -nodesktop -nosplash -r \"addpath('{script_dir}'); "
                              f"compileDatabase4_func('{tile_dir}', '{dbase_out}'); exit();\"")
                logger.info(matlab_cmd)
                subprocess.call(matlab_cmd, shell=True)

            # Add BST cmd to the list
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
                bst_cmd = (f'python {script_dir}/batch_buildSubTiles.py {results_dir} {tile} --project {args.project} --strip-db '
                           f'{dbase_out} --water-tile-dir {water_tile_dir} --chain-mst --rerun --slurm')
                tile_bst.append(bst_cmd)

    if len(tile_bst) > 0:
        logger.info("Submitting BST jobs")
        for bst_cmd in tile_bst:
            logger.info(bst_cmd)
            subprocess.call(bst_cmd, shell=True)




if __name__ == '__main__':
    main()