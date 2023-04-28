function writeTileToTifv4(tilef,projstr,varargin)
% Write 2m or 10m dem matfiles to tif
%   compatible with setsm_postprocesing v4 branch

% By default, tiles are cropped to nearest gridline multiple of 50/100km for 2/10m tiles
% before bufferMeters is applied.
% In noCrop mode, skip the crop step.
n = find(strcmpi('noCrop',varargin));
if ~isempty(n)
    noCrop = true;
else
    noCrop = false;
end

% output tile buffer in meters
n = find(strcmpi('bufferMeters',varargin));
if ~isempty(n)
    bufferMeters = varargin{n+1};
else
    bufferMeters = 100;
end

n = find(strcmpi('overwrite',varargin));
if ~isempty(n)
    overwrite = true;
else
    overwrite = false;
end

n = find(strcmpi('outFormat',varargin));
if ~isempty(n)
    outFormat = varargin{n+1};
else
    outFormat = 'LZW';
end
outFormat_choices = {'LZW', 'COG'};
if ~any(strcmpi(outFormat, outFormat_choices))
    error("'outFormat' must be one of the following, but was '%s': {'%s'}", outFormat, strjoin(outFormat_choices, "', '"))
end

n = find(strcmpi('outSet',varargin));
if ~isempty(n)
    outSet = varargin{n+1};
else
    outSet = 'full';
end
outSet_choices = {'full', 'browseOnly', 'demOnly', 'demAndBrowse'};
if ~any(strcmpi(outSet, outSet_choices))
    error("'outSet' must be one of the following, but was '%s': {'%s'}", outSet, strjoin(outSet_choices, "', '"))
end

dem_only = false;
browse_only = false;
dem_and_browse = false;
if strcmpi(outSet, 'demOnly')
    dem_only = true;
elseif strcmpi(outSet, 'browseOnly')
    browse_only = true;
elseif strcmpi(outSet, 'demAndBrowse')
    dem_and_browse = true;
end

if strcmpi(outFormat, 'COG')
    outFormat_is_cog = true;
    tif_format = 'COG';
else
    outFormat_is_cog = false;
    tif_format = 'GTiff';
end

n = find(strcmpi('refDemFile',varargin));
if ~isempty(n)
    refDemFile = varargin{n+1};
end

n = find(strcmpi('waterMaskFile',varargin));
if ~isempty(n)
    waterMaskFile = varargin{n+1};
end

n = find(strcmpi('applySlopeDiffFilt',varargin));
if ~isempty(n)
    applySlopeDiffFilt = true;
else
    applySlopeDiffFilt = false;
end

n = find(strcmpi('applyWaterFill',varargin));
if ~isempty(n)
    applyWaterFill = true;
else
    applyWaterFill = false;
end

n = find(strcmpi('addSeaSurface',varargin));
if ~isempty(n)
    addSeaSurface = true;
else
    addSeaSurface = false;
end

n = find(strcmpi('qcMaskFile',varargin));
if ~isempty(n)
    qcMaskFile = varargin{n+1};
end

if strcmpi(projstr, 'polar stereo north')
    addSeaSurface_epsg = 3413;
elseif strcmpi(projstr, 'polar stereo south')
    addSeaSurface_epsg = 3031;
elseif contains(projstr,'UTM','IgnoreCase',true)
    [addSeaSurface_epsg,~,~] = getProjstrInfo(projstr);
else
    addSeaSurface_epsg = [];
end

if addSeaSurface && isempty(addSeaSurface_epsg)
    error("'addSeaSurface' option conversion to EPSG is not handled for 'projstr': '%s'", projstr)
end


fprintf('Source: %s\n',tilef);

% load m file and get coordinate vectors
m=matfile(tilef);
x=m.x;
y=m.y;

m_varlist = who(m);

% ensure output projection setting is correct for PGC projects
if ismember('version', m_varlist)
    project_version = strsplit(m.version, '|');
    project = project_version{1};
    if strcmpi(project, 'arcticdem')
        if ~strcmpi(projstr, 'polar stereo north')
            error("'projstr' for ArcticDEM project should be 'polar stereo north', but was '%s'", projstr)
        end
    elseif strcmpi(project, 'rema')
        if ~strcmpi(projstr, 'polar stereo south')
            error("'projstr' for REMA project should be 'polar stereo south', but was '%s'", projstr)
        end
    elseif strcmpi(project, 'earthdem')
        if ~startsWith(projstr, 'utm', 'IgnoreCase',true)
            error("'projstr' for EarthDEM project should start with 'utm', but was '%s'", projstr)
        end
    end
end

if addSeaSurface && ~ismember('land', m_varlist)
    fprintf("'addSeaSurface' option requires 'land' variable exists in tile matfile: %s\n", tilef)
    warning('sea surface heights will not be applied')
    addSeaSurface = false;
end

% find data/buffer boundaries
% get posting distance
dx = x(2)-x(1);

%find buffer size
if noCrop;
    nx = [];
    ny = [];
else
    if dx == 2 % 2m posting, using quarter tile (50km) boundaries
        nx = find(mod(x,50000) == 0);
        ny = find(mod(y,50000) == 0);
    elseif dx == 10 % 10m posting, using full tile (100km) boundaries
        nx = find(mod(x,100000) == 0);
        ny = find(mod(y,100000) == 0);
        % EarthDEM UTM mosaic 100km tile edges fall on 50km intervals
        if length(nx) == 1
            nx = find(mod(x,50000) == 0);
            if length(nx) == 3
                nx = [nx(1) nx(end)];
            end
            ny = find(mod(y,50000) == 0);
            if length(ny) == 3
                ny = [ny(1) ny(end)];
            end
        end
    else
        error('not compatible with a tile grid size of %dm',dx)
    end
end

% if no index values returned, assume all tile data lies within tile
% boundary - no buffers;
if isempty(nx)
    nx = [1 length(x)+1];
end
if isempty(ny)
    ny = [1 length(y)+1];
end

% if one index value returned, tile does not extend to one boundary.
% Determine which boundary this is by which side its closer to. This may
% fail if the buffer width is larger than the width of data inside tile.
if length(nx) == 1
    % if boundary point is closer to y(1), assume buffer is 1:ny-1 and set
    % data range to the length of the x coordinate , plus one for the crop.
    if nx/length(x) < 0.5
        nx(2) = length(x)+1;
    else
        % if boundary point is closer to y(end), assume buffer is ny-1:end
        % and set minimum range to 1
        nx = [1,nx];
    end
end
if length(ny) == 1
    % if boundary point is closer to y(1), assume buffer is 1:ny-1
    if ny/length(y) < 0.5
        ny(2) = length(y)+1;
    else
        % if boundary point is closer to y(end), assume buffer is ny-1:end
        ny = [1,ny];
    end
end

% crop last row & col off, since tile begins at x0 and y0, so no overlap
% with next tile
nx(end) = nx(end)-1;
ny(end) = ny(end)-1;

% add standard tile buffer
if bufferMeters > 0
    buffer_px = bufferMeters / dx;
    nx(1) = max(nx(1)-buffer_px, 1);
    nx(2) = min(nx(2)+buffer_px, length(x));
    ny(1) = max(ny(1)-buffer_px, 1);
    ny(2) = min(ny(2)+buffer_px, length(y));
end

%% crop coordinate vectors
%x=x(nx(1):nx(2));
%y=y(ny(1):ny(2));
% do cropping AFTER filter/mask application steps

%get name without "_reg"
outNameBase = strrep(tilef,'_reg.mat','.mat');
outNameDem = strrep(outNameBase,'.mat','_dem.tif');
outNameBrowse = strrep(outNameBase,'.mat','_browse.tif');


z = [];
slope_filter_mask = [];
water_fill_mask = [];
sea_surface_mask = [];
qc_mask = [];

if applySlopeDiffFilt
    fprintf('applying slope difference filter\n')
    if isempty(z)
        z = m.z;
    end
    I_ref = readGeotiff(refDemFile,'mapinfoonly');
    zr_dx = I_ref.x(2)-I_ref.x(1);
    if zr_dx ~= dx
        m_x0 = floor(x(1)  /zr_dx) * zr_dx;
        m_x1 = ceil( x(end)/zr_dx) * zr_dx;
        m_y0 = floor(y(end)/zr_dx) * zr_dx;
        m_y1 = ceil( y(1)  /zr_dx) * zr_dx;
        m_x = m_x0:zr_dx:m_x1;
        m_y = m_y1:-zr_dx:m_y0;
        z_at_zr_res = interp2(x,y(:),z,m_x,m_y(:),'*bilinear');
    else
        m_x0 = x(1);
        m_x1 = x(end);
        m_y0 = y(end);
        m_y1 = y(1);
        m_x = x;
        m_y = y;
        z_at_zr_res = z;
    end
    I_ref = getDataFromTileAndNeighbors(refDemFile,m_x0,m_x1,m_y0,m_y1,zr_dx,nan);
    zr = I_ref.z;
    M = slopeDifferenceFilter(m_x,m_y,z_at_zr_res,zr);
    if zr_dx ~= dx
        M_at_z_res = interp2(m_x,m_y(:),M,x,y(:),'*nearest');
    else
        M_at_z_res = M;
    end
    slope_filter_mask = ~M_at_z_res;
    z(slope_filter_mask) = NaN;
end

z_mad = [];
N = [];
if applyWaterFill
    fprintf('applying water fill\n')
    if isempty(z)
        z = m.z;
    end
    z_mad = m.z_mad;
    N = m.N;
    [z,water_fill_mask] = fillWater('',waterMaskFile,refDemFile,z,z_mad,N,x,y,fillWaterInterpMethod);
end

% add ocean surface (egm96 height above ellipsoid) if specified - requires mask array in matfile
if addSeaSurface
    fprintf('applying sea surface height\n')
    if isempty(z)
        z = m.z;
    end
    land = m.land;
    [z,sea_surface_mask] = addSeaSurfaceHeight(x,y,z,land,'epsg',addSeaSurface_epsg,'adaptCoastline');
end

if exist('qcMaskFile','var')
    fprintf('applying qc mask\n')
    qc_mat = load(qcMaskFile);
    if isempty(z)
        z = m.z;
    end
    if isempty(qc_mask)
        qc_mask = zeros(size(z),'logical');
    end

    tilePoly = polyshape([x(1,1);x(1,1);x(end);x(end);x(1)],...
            [y(1);y(end);y(end);y(1);y(1)]);

    n = find(overlaps(tilePoly,qc_mat.polyShapes));

    for j = 1:length(n)
        qc_x = qc_mat.polyShapes(n(j)).Vertices(:,1);
        qc_y = qc_mat.polyShapes(n(j)).Vertices(:,2);
        try
            M = roipoly(x,y,z,qc_x,qc_y);
            M = imdilate(M,ones(3));
            if qc_mat.seaSurface(n(j))
                [z,sea_poly_mask]=addSeaSurfaceHeight(x,y,z,~M,'epsg',addSeaSurface_epsg,'landIsQcMask');
                qc_mask(sea_poly_mask) = 1;
            else
                z(M) = NaN;
                qc_mask(M) = 1;
            end
        catch ME
            qc_x
            qc_y
            rethrow(ME)
        end
    end
end

bad_data_or_filled_mask = [];
masks_array = {
    slope_filter_mask,
    water_fill_mask,
    sea_surface_mask,
    qc_mask
};
if ~all(cellfun(@isempty, masks_array))
    if isempty(z)
        z = m.z;
    end
    bad_data_or_filled_mask = zeros(size(z), 'logical');
    for i = 1:length(masks_array)
        M = masks_array{i};
        if ~isempty(M)
            bad_data_or_filled_mask(M) = 1;
        end
    end
end


% crop coordinate vectors
x=x(nx(1):nx(2));
y=y(ny(1):ny(2));

fprintf('Writing DEM\n')
if exist(outNameDem,'file') && ~overwrite
    wrote_dem = false;
    fprintf('%s exists, skipping\n',outNameDem);
else
    wrote_dem = true;
    % ensure browse is consistent with dem
    if exist(outNameBrowse,'file')
        delete(outNameBrowse);
    end

    if isempty(z)
        z = m.z;
    end
    z=z(ny(1):ny(end),nx(1):nx(end));
    
    % Round DEM values to 1/128 meters to greatly improve compression effectiveness
    z=round(z*128.0)/128.0;
    z(isnan(z)) = -9999;
    if outFormat_is_cog
        co_predictor = 'FLOATING_POINT';
    else
        co_predictor = '3';
    end
    writeGeotiff(outNameDem,x,y,z,4,-9999,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','BILINEAR')
    clear z
end

if dem_only
    return;
end


flds=fields(m);

if ~(browse_only || dem_and_browse)
    if contains('z_mad',flds)
        fprintf('Writing mad\n')
        outNameTif = strrep(outNameBase,'.mat','_mad.tif');
        if exist(outNameTif,'file') && ~overwrite
            fprintf('%s exists, skipping\n',outNameTif);
        else
            if isempty(z_mad)
                z_mad = m.z_mad;
            end
            if ~isempty(bad_data_or_filled_mask)
                z_mad(bad_data_or_filled_mask) = NaN;
            end
            z_mad=z_mad(ny(1):ny(end),nx(1):nx(end));
            % Round MAD values to 1/128 meters to greatly improve compression effectiveness
            z_mad=round(z_mad*128.0)/128.0;
            z_mad(isnan(z_mad)) = -9999;
            if outFormat_is_cog
                co_predictor = 'FLOATING_POINT';
            else
                co_predictor = '3';
            end
            writeGeotiff(outNameTif,x,y,z_mad,4,-9999,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','BILINEAR')
            clear z_mad
        end
    end

    % data count
    if contains('N',flds)
        fprintf('Writing N\n')
        outNameTif = strrep(outNameBase,'.mat','_count.tif');
        if exist(outNameTif,'file') && ~overwrite
            fprintf('%s exists, skipping\n',outNameTif);
        else
            if isempty(N)
                N = m.N;
            end
            if ~isempty(bad_data_or_filled_mask)
                N(bad_data_or_filled_mask) = 0;
            end
            N=N(ny(1):ny(end),nx(1):nx(end));
            if outFormat_is_cog
                co_predictor = 'NO';
%                co_predictor = 'STANDARD';
            else
                co_predictor = '1';
%                co_predictor = '2';
            end
            writeGeotiff(outNameTif,x,y,N,1,0,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','NEAREST')
            clear N
        end
    end

    % matchtag count
    if contains('Nmt',flds)
        fprintf('Writing Nmt\n')
        outNameTif = strrep(outNameBase,'.mat','_countmt.tif');
        if exist(outNameTif,'file') && ~overwrite
            fprintf('%s exists, skipping\n',outNameTif);
        else
            Nmt=m.Nmt;
            if ~isempty(bad_data_or_filled_mask)
                Nmt(bad_data_or_filled_mask) = 0;
            end
            Nmt=Nmt(ny(1):ny(end),nx(1):nx(end));
            if outFormat_is_cog
                co_predictor = 'NO';
%                co_predictor = 'STANDARD';
            else
                co_predictor = '1';
%                co_predictor = '2';
            end
            writeGeotiff(outNameTif,x,y,Nmt,1,0,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','NEAREST')
            clear Nmt
        end
    end

    % Maximum date
    if contains('tmax',flds)
        fprintf('Writing tmax\n')
        outNameTif = strrep(outNameBase,'.mat','_maxdate.tif');
        if exist(outNameTif,'file') && ~overwrite
            fprintf('%s exists, skipping\n',outNameTif);
        else
            tmax=m.tmax;
            if ~isempty(bad_data_or_filled_mask)
                tmax(bad_data_or_filled_mask) = 0;
            end
            tmax=tmax(ny(1):ny(end),nx(1):nx(end));
            if outFormat_is_cog
                co_predictor = 'NO';
%                co_predictor = 'STANDARD';
            else
                co_predictor = '1';
%                co_predictor = '2';
            end
            writeGeotiff(outNameTif,x,y,tmax,2,0,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','NEAREST')
            clear tmax
        end
    end

    % Minimum date
    if contains('tmin',flds)
        fprintf('Writing tmin\n')
        outNameTif = strrep(outNameBase,'.mat','_mindate.tif');
        if exist(outNameTif,'file') && ~overwrite
            fprintf('%s exists, skipping\n',outNameTif);
        else
            tmin=m.tmin;
            if ~isempty(bad_data_or_filled_mask)
                tmin(bad_data_or_filled_mask) = 0;
            end
            tmin=tmin(ny(1):ny(end),nx(1):nx(end));
            if outFormat_is_cog
                co_predictor = 'NO';
%                co_predictor = 'STANDARD';
            else
                co_predictor = '1';
%                co_predictor = '2';
            end
            writeGeotiff(outNameTif,x,y,tmin,2,0,projstr,'out_format',tif_format,'co_predictor',co_predictor,'cog_overview_resampling','NEAREST')
            clear tmin
        end
    end
end


%% 10m browse hillshade
fprintf('Writing browse\n')

% if 2m posting, first downsample to 10m
if exist(outNameBrowse,'file') && ~overwrite
    fprintf('%s exists, skipping\n',outNameBrowse);
else
    [epsg,~,~] = getProjstrInfo(projstr);

    if dx == 2
        outNameTemp = strrep(tilef,'.mat','_temp.tif');
        gdal_cmd = [...
            'gdal_translate',...
            ' -of GTiff',...
            ' -a_srs ', sprintf('EPSG:%d', epsg),...
            ' -tr 10 10 -r bilinear',...
            ' -co TILED=YES -co BIGTIFF=YES',...
            ' -co COMPRESS=LZW -co PREDICTOR=3',...
            ' -a_nodata -9999',...
            ' ', outNameDem, ' ', outNameTemp];
        fprintf('%s\n', gdal_cmd);
        [status, cmdout] = system(gdal_cmd);
        if ~isempty(cmdout)
            disp(cmdout)
        end
        if status ~= 0
            error('Non-zero exit status (%d) from gdal_translate',status)
        end
    elseif dx == 10
        outNameTemp = outNameDem;
    end

    if outFormat_is_cog
        co_predictor = 'STANDARD';
        co_tiled_arg = '';
        co_overviews_args = '-co OVERVIEWS=IGNORE_EXISTING -co RESAMPLING=CUBIC';
    else
        co_predictor = '2';
        co_tiled_arg = '-co TILED=YES';
        co_overviews_args = '';
    end

    % convert to hillshade
    gdal_cmd = [...
        'gdaldem hillshade',...
        ' -of ', tif_format,...
        ' -z 3 -compute_edges',...
        ' ', co_tiled_arg, ' -co BIGTIFF=IF_SAFER',...
        ' -co COMPRESS=LZW -co PREDICTOR=', co_predictor,...
        ' ', co_overviews_args,...
        ' ', outNameTemp, ' ', outNameBrowse];
    fprintf('%s\n', gdal_cmd);
    [status, cmdout] = system(gdal_cmd);
    if ~isempty(cmdout)
        disp(cmdout)
    end
    if status ~= 0
        error('Non-zero exit status (%d) from gdaldem hillshade',status)
    end

    if ~strcmp(outNameTemp, outNameDem) || (browse_only && wrote_dem)
        fprintf('Removing temporary DEM output:\n%s\n', outNameTemp)
        delete(outNameTemp);
    end
end
