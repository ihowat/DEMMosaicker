function buildSubTiles(tileName,outDir,tileDefs,meta,varargin)
% Changes from buildSubTiles2:
%  - change tileDefFile,databaseFile,waterTileDir input to be filename OR
%  variable
%  - change tileDefFile input to be either filename, a structure, or just
%  the range vector [x0 x1 y0 y1]
% - disable "iceTile" and "dzdtTile" use
% - handle filename input without extension (w/o _meta.txt)
% - exclude dems < minStripOverlap% tile overlap
% - exlude dems outstide a time range
% - disabled applying strip bitmask
% - added qc fields, will exclude flag == 5 and apply flag == 3 mask if
% supplied
% - uses rmse from refdem when ~isnan(dZ
% - if no refdem, use mean coreg sigma to select if N > 2
% - uses  'offsetdiffmax',50,...
% - buffer size of 0.1*tile size
% - landMask, refDemFile timeRange, minStripOverlap, buffer optional argins
%  - set minStripOverlap = 0.1 as default
% - changed exist statements to flags
% - added nstrt option
% - robust stripid matching for 2m call
% - added qc to 2m
% - added make2m inarg
% - added filter flag imnarg
% -  apply roipoly to mt

% buildSubTiles build mosaics from strips in subtiles of 100x100km tiles
%
% buildSubTiles(tileName,outDir,tileDefFile,databaseFile,waterTileDir,refDemFile)
%
% Input arguments:
%tileName=string tile x,y name (e.g. '47_13')
%tileDefFile = matfile list of tile names and ranges (e.g. '/Users/ihowat/unity-home/earthdem/PGC_Imagery_Mosaic_Tiles_Arctic.mat');
%databaseFile = strip database structure produced by by the database function (e.g. '/Users/ihowat/gdrive/projects/earthdem/earthdem_database_unf.mat');
%outDir = directory to ouput subtile files e.g.(['/Users/ihowat/project/howat.4/earthdem/earthdem_mosaic_testing_1km/',tileName]);
%waterTileDir= directory of water/land mask rasters (e.g. '~/data/pgc_projects/ak_water_rasters_v2');
%refDemFile= geotiff reference DEM for quality control ('~/tandemx_alaska_mosaic_3413_tap90m.tif');

fprintf('tileName = %s\n',tileName)
fprintf('outDir = %s\n',outDir)

%% parameters/defaults
res=10; % ouput mosaic resolution in meters
subtileSize=1000; % subtile dimensions in meters
buffer=subtileSize*.1; % size of tile/subtile boundary buffer (10%)
maxNumberOfStrips=100; % maximum number of strips to load in subtile
refDemFile = ''; % optional refDemFile name palce holder
minStripOverlap = 0.1; % minimum frac strip overlap of subtile
projection = ''; % projection string for tile scheme

% Parse varargins
filterFlag = true; % apply pairwise differece filter
n = find(strcmpi(varargin,'filter'));
if ~isempty(n)
    filterFlag  = varargin{n+1};
end
fprintf('Apply pairwise difference filter = %d\n',filterFlag)

make2mFlag=false; % make 2m version or not
n = find(strcmpi(varargin,'make2m'));
if ~isempty(n)
    make2mFlag = varargin{n+1};
end

n = find(strcmpi(varargin,'landTile'));
if ~isempty(n)
    landTile = varargin{n+1};
    fprintf('Land mask applied\n')
end

refDemFileFlag = false;
n = find(strcmpi(varargin,'refDemFile'));
if ~isempty(n)
    refDemFile = varargin{n+1};
    refDemFileFlag = true;
    fprintf('refDemFile = %s\n',refDemFile)
end

n = find(strcmpi(varargin,'minStripOverlap'));
if ~isempty(n)
    minStripOverlap = varargin{n+1};
end
fprintf('minStripOverlap = %d\n',minStripOverlap)

n = find(strcmpi(varargin,'buffer'));
if ~isempty(n)
    buffer = varargin{n+1};
end
fprintf('buffer = %d\n',buffer)

nstrt = 1;
n = find(strcmpi(varargin,'nstrt'));
if ~isempty(n)
    nstrt = varargin{n+1};
end

n = find(strcmpi(varargin,'projection'));
if ~isempty(n)
    projection = varargin{n+1};
end
fprintf('projection = %s\n',projection)

n = find(strcmpi(varargin,'res'));
if ~isempty(n)
    res = varargin{n+1};
end
fprintf('res = %d\n',res)

%if output directory doesnt already exist, make it
if ~exist(outDir,'dir')
    mkdir(outDir)
end

fprintf('Building subsets for tile %s in %s\n',tileName,outDir);

%% initialize meta stuct

%if meta is filename, load it
if ischar(meta)
    meta=load(meta);
    % remove possible duplicate strip records
    [~, in] = unique(meta.fileName);
    meta = structfun(@(x) x(in), meta,'uniformoutput',0);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% PGC TODO:
%% Restore commented-out field check and remove OTF
%% field population after we move away from old-style
%% strip dbase compilation and start using the new
%% shapefile dbase method with initializeMosaic.m
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%if ~isfield(meta,'scene_alignment_meanrmse')
%    error('missing scene alignment field in meta structure')
%end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

meta.fileName = strrep(meta.fileName, '_meta.txt', '_dem_10m.tif');

if ~isfield(meta,'scene_alignment_meanrmse')
    if isfield(meta,'avg_rmse')
        % this is from an old version of the meta files that used 0 in mean
        error('avg_rmse field in meta structure, needs to be updated')
    elseif isfield(meta,'scene_alignment')
        % need to rm zeros (first scene) and nans (unused redundant scenes),
        % strips w/ 1 scene will be NaN
        meta.scene_alignment_meanrmse = cellfun(@(x)...
            mean(x.rmse(x.rmse~=0 & ~isnan(x.rmse))), meta.scene_alignment);
    else
        error('missing scene alignment field in meta structure')
    end
end

if ~isfield(meta,'A')
    % get strip areas and alignment stats for quality selection
    meta.A = cellfun(@(x,y) polyarea(x,y), meta.x,meta.y);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

qcFlag = false;
if isfield(meta,'qc')
    fprintf('Applying qc data\n')
    qcFlag = true;
end

%% Initialize tile definition

%if tileDefs is filename, load it
if ischar(tileDefs)
    tileDefs=load(tileDefs);

end

if startsWith(tileName,'utm')
    sl = split(tileName,'_');
    tilePrefix = [sl{1},'_'];
    tileName_in_tileDef = strjoin(sl(2:3),'_');
else
    tilePrefix = '';
    tileName_in_tileDef = tileName;
end

% trim strip database to only strips with a projection matching the tile
if isfield(meta,'strip_projection_name')
    if isempty(projection)
        error("'projection' argument must be provided when strip dbase has 'strip_projection_name' field");
    end

    tileProjName = '';
    if startsWith(tileName,'utm')
        tileName_parts = strsplit(tileName,'_');
        tileProjName = tileName_parts{1};
    end

    if strcmpi(projection, 'polar stereo north')
        tileProjName = 'psn';
    elseif strcmpi(projection, 'polar stereo south')
        tileProjName = 'pss';
    elseif startsWith(projection,'utm', 'IgnoreCase',true)
        if ~startsWith(tileProjName, projection, 'IgnoreCase',true)
            error("'projection' argument (%s) and tileName (%s) prefix (%s) do not match", ...
                projection, tileName, tileProjName);
        end
    else
        error("No matching tileProjName for 'projection' argument: '%s'", tileProjName);
    end

    in = strcmpi(meta.strip_projection_name, tileProjName);
    if ~any(in)
        error("no matches between tileProjName='%s' and strip dbase 'strip_projection_name' field", tileProjName);
    end
    meta = structfun(@(x) trimMetaStructFieldByN(x,in), meta,'uniformoutput',0);
end

% tileDefs is a stucture, find this tile and extract range
if isstruct(tileDefs)
    tileInd = find(strcmp(tileDefs.I,tileName_in_tileDef));

    % get tile boundaries
    x0=tileDefs.x0(tileInd);
    y0=tileDefs.y0(tileInd);
    x1=tileDefs.x1(tileInd);
    y1=tileDefs.y1(tileInd);
    
    %otherwise
elseif length(tileDefs) == 4
    x0=tileDefs(1);
    y0=tileDefs(2);
    x1=tileDefs(3);
    y1=tileDefS(4);
end

%% Intialize land/water (true/false) mask
landTileFlag = false;
if exist('landTile','var')
    if ischar(landTile)
        waterTileDir = landTile;
        % land classification tile (1=ice-free land, 0=water)
        landTile = getTileWaterMask(waterTileDir,tileName,x0-buffer,...
            x1+buffer,y0-buffer,y1+buffer,res,'includeIce');
        landTile.z = landTile.z == 1;
    end
    
    landTileFlag = true;
    
    % check if any land exists in this tile, stop if not
    if ~any(landTile.z(:))
        fprintf('ERROR: no land in tile, returning\n')
        return
    end
end

%% make array of subtile boundary coordinates
subx0=(x0:subtileSize:x1-subtileSize) - buffer;
subx1=(x0+subtileSize:subtileSize:x1) + buffer;
suby0=(y0:subtileSize:y1-subtileSize) - buffer;
suby1=(y0+subtileSize:subtileSize:y1) + buffer;

[subx0,suby0] = meshgrid(subx0,suby0);
[subx1,suby1] = meshgrid(subx1,suby1);

subN=numel(subx0);

% determine row and column numbers of subtiles for mosaic indexing
[NsubTileRows, NsubTileCols] = size(subx0);
subTileRows = (1:NsubTileRows)';
subTilesCols = 1:NsubTileCols;
[subTileCols, subTileRows] = meshgrid(subTilesCols, subTileRows);

% The following code is left commented out after new restart logic was placed
% inside the parfor loop for safe restart of parallel subtile building.

% %% check for existing subtiles
% % make a cellstr of resolved subtile filenames
% existingSubTileFiles=dir([outDir,'/*_',num2str(res),'m.mat']);
% if ~isempty(existingSubTileFiles)
%     
%     existingSubTileFiles=cellfun( @(x) [outDir,'/',x],{existingSubTileFiles.name},'uniformoutput',0);
%     
%     % Get column-wise number of subtile from file names - assumes the subtile
%     % names is {subRow}_{subCol}_{xm}.mat....
%     [~,existingSubTileNames] = cellfun(@fileparts,existingSubTileFiles,'uniformoutput',0);
%     existingSubTileNames=cellfun(@(x) strsplit(x,'_'),existingSubTileNames,'uniformoutput',0);
%     existingSubTileRows = cellfun(@(x) str2num(x{end-2}),existingSubTileNames);
%     existingSubTileCols = cellfun(@(x) str2num(x{end-1}),existingSubTileNames);
%     
%     existingSubTileNums = sub2ind([NsubTileRows, NsubTileCols],existingSubTileRows(:),existingSubTileCols(:));
%     
%     % sort subtilefiles by ascending subtile number order
%     [existingSubTileNums,n] = sort(existingSubTileNums); % sort the numbers
%     existingSubTileFiles = existingSubTileFiles(n); % sort the file list
%     
%     nstrt = existingSubTileNums(end)+1; % set first subtile next after last exisitng
%     
%     % check to make sure last file was complete
%     mvars  = who('-file',existingSubTileFiles{end});
%     if ~any(ismember(mvars,'za_med'))
%         % if not, delete and set nstrt to that number
%         delete(existingSubTileFiles{end})
%         nstrt =  nstrt - 1;
%     end
%     
%     if nstrt > subN
%          fprintf('all subtiles already exist, returning \n')
%     end
%     
%     fprintf('subtiles already exist, starting on subtile %d\n',nstrt)
% end

%% subtile loop
parfor n=nstrt:subN
    
    fprintf('subtile %d of %d\n',n,subN)

    outName = [outDir,'/',tileName,'_',num2str(subTileRows(n)),'_',num2str(subTileCols(n)),'_10m.mat'];
    finName = [outDir,'/',tileName,'_',num2str(subTileRows(n)),'_',num2str(subTileCols(n)),'_10m.fin'];

    outName2m = strrep(outName,'_10m.mat','_2m.mat');
    finName2m = strrep(finName,'_10m.fin','_2m.fin');

    if make2mFlag
        check_outName = outName2m;
        check_finName = finName2m;
    else
        check_outName = outName;
        check_finName = finName;
    end

    if exist(check_outName,'file')
        invalid = false;
        % check to make sure subtile file is valid and complete
        try  % try to open the file
            mvars = who('-file',check_outName);
            if ~any(ismember(mvars,'za_med'))  % if it's not complete, delete it
                invalid = true;
            else
                fprintf('subtile file already exists, skipping: %s\n',check_outName)
                continue
            end
        catch % if it's invalid, delete it
            invalid = true;
        end
        if invalid
            fprintf('deleting 10m/2m components of corrupted or incomplete existing subtile file: %s\n',check_outName)
            if exist(outName,'file')
                delete(outName)
            end
            if exist(outName2m,'file')
                delete(outName2m)
            end
        end
    elseif exist(check_finName,'file')
        fprintf('subtile-is-finished indicator file for empty subtile already exists, skipping: %s\n',check_finName)
        continue
    end

    x=subx0(n):res:subx1(n);
    y=suby1(n):-res:suby0(n);
    y=y(:);
    
    % subset tile land/water mask if exists
    if landTileFlag
        land = interp2(landTile.x,landTile.y(:),single(landTile.z),x,y(:),...
            '*nearest');
        land(isnan(land)) = 0;
        land = logical(land);
    else
        land = true(length(y),length(x));
    end
    
    if ~any(land(:))
        fprintf('No land in subtile %d, skipping\n',n)
        fclose(fopen(finName, 'w'));
        if make2mFlag; fclose(fopen(finName2m, 'w')); end
        continue
    end
    
    %% find overlapping strips
    
    % convert to polyshape
    subtilePoly = polyshape([subx0(n);subx0(n);subx1(n);subx1(n)],...
        [suby0(n);suby1(n);suby1(n);suby0(n)]);
    
    % index of strips in this subtile
    ind=stripSearch(meta.x,meta.y,subtilePoly);
    
    % if qc data exists, filter out 5's
    if qcFlag
        ind = ind(meta.qc.flag(ind) ~= 5);
    end
    
    % check for maximum #'s of overlaps
    if length(ind) > maxNumberOfStrips
        
        %first remove strips with single subscenes
        ind(isnan(meta.scene_alignment_meanrmse(ind))) = [];
    end
    
    % check if still more strips than max
    if length(ind) >  maxNumberOfStrips
        
        % sort by weigthed area and coverage
        scene_alignment_meanrmse_scaled= -(meta.scene_alignment_meanrmse(ind)-...
            mean(meta.scene_alignment_meanrmse(ind)))./...
            std(meta.scene_alignment_meanrmse(ind));
        
        % normalize areas for group
        A_scaled = (meta.A(ind)-mean(meta.A(ind)))./std(meta.A(ind));
        
        % normalize scene alignment stats for group
        scene_alignment_meanrmse_scaled = scene_alignment_meanrmse_scaled +...
            abs(min(scene_alignment_meanrmse_scaled));
        
        % take the sum of normalized values
        A_scaled = A_scaled + abs(min(A_scaled));
        
        % sort by scaled sum
        [~,ind_rank] = sort(A_scaled.*scene_alignment_meanrmse_scaled,...
            'descend');
        
        % take top N strips in sort
        ind = ind(ind_rank(1:maxNumberOfStrips));
    end
    
    if isempty(ind)
        fprintf('no overlapping strips, skipping\n')
        fclose(fopen(finName, 'w'));
        if make2mFlag; fclose(fopen(finName2m, 'w')); end
        continue
    end
    
    % convert meta names into dem names
    fileNames  = meta.fileName(ind);
    
    % make date vector
    [~,name] =  cellfun(@fileparts,fileNames,'uniformoutput',0);
    t=cellfun(@(x) datenum(parsePairnameDatestring(x),'yyyymmdd'),name)';
    
    %% extract strip subsets into stack
    fprintf('extracting %d strip subsets ',length(fileNames))
    [x,y,z,missingFlag,mt] =extractSubGrid(fileNames,subx0(n),subx1(n),...
        suby0(n),suby1(n),res,'applyBitmask',false);
    
    % remove layers missing data
    z = z(:,:,~missingFlag);
    mt = mt(:,:,~missingFlag);
    fileNames=fileNames(~missingFlag);
    ind = ind(~missingFlag);
    
    % apply qc masks if provided
    if qcFlag
        nn = find(meta.qc.flag(ind) == 3);
        if isempty(nn)
            fprintf('no qc found to apply\n')
        else
            fprintf('found qc to apply\n')
        end
        for j=nn
            ztmp = z(:,:,j);
            mttmp = mt(:,:,j);
            BW = false(size(ztmp));
            for k=1:length(meta.qc.x{ind(j)})
                BW = BW | roipoly(x,y,ztmp,meta.qc.x{ind(j)}{k},...
                    meta.qc.y{ind(j)}{k});
            end
            ztmp(BW) = NaN;
            z(:,:,j) = ztmp;
            mttmp(BW) = false;
            mt(:,:,j) = mttmp;
        end
    end
    
    % save full filename list with repeat segments for 2m
    fileNames0 = fileNames;
    
    % merge segmentsfrom same strips
    % dont get offsets between segs in same strip:make a vector of z's
    % that belong to the same strip
    [~,stripid] =  cellfun(@fileparts,fileNames,'uniformoutput',0);
    stripid =  cellfun(@(x) x(1:47),stripid,'uniformoutput',0);
    unique_stripid = unique(stripid);
    
    r=[];
    for it=1:length(unique_stripid)
        segs = find(strcmp(stripid,unique_stripid(it)));
        segs=segs(:);
        if length(segs) > 1
            z(:,:,segs(1)) = mynanmedian3(z(:,:,segs));
            mt(:,:,segs(1)) = any(mt(:,:,segs),3);
            r = [r(:);segs(2:end)];
        end
    end
    
    z(:,:,r) = [];
    mt(:,:,r) = [];
    fileNames(r) = [];
    t(r) = [];
    
    if minStripOverlap > 0
        % remove z's with < X% tile overlap
        r = reshape(sum(sum(~isnan(z))),[],1,1)./...
            (length(x)*length(y)) < minStripOverlap;
        
        z(:,:,r) = [];
        mt(:,:,r) = [];
        fileNames(r) = [];
        t(r) = [];
    end
    
    %% calculate DEM pairwise offsets
    fprintf('performing pairwise coregistration, ')
    offsets=coregisterStack(x,y,z,land);
    
    %% adjustment
    
    % set offsets with horizontal shift failure to zero
    offsets.dx(offsets.dxe == 0) = NaN;
    offsets.dy(offsets.dye == 0) = NaN;
    
    offsets.dxe(isnan(offsets.dx)) = NaN;
    offsets.dye(isnan(offsets.dy)) = NaN;
    
    if ~any(~isnan(offsets.dz))
        
        % set adjustment thresholds to inf and shifts to zero
        dZ = zeros(size(z,3),1);
        dX = zeros(size(z,3),1);
        dY = zeros(size(z,3),1);
        
    else
        
        %number of grid points with coverage
        c0 = any(z,3);
        c0 = sum(c0(:));
        
        % iteratively perform adjustment, relaxing thresholds by 10%, up to a
        % maximum of 500%  , until coverage is maximum
        [dZ, dX, dY] = perfadj(offsets, z, c0);
        % If adjustment fails, use either mean offset rmse or reference dem
        if ~any(~isnan(dZ))
            
            % dem sorting vector in ascending order
            nsort = [];
            
            % check for reference DEM file
            if refDemFileFlag
                
                % load subset of reference dem covering subtile
                zr=readGeotiff(refDemFile,...
                    'map_subset',[x(1)-90 x(end)+90 y(end)-90 y(1)+90],...
                    'reportMapSubsetError');
                
                zr.z(zr.z < -200) = NaN;
                
                if ~any(~isnan(zr.z(:)))
                    fprintf('Reference dem has no data\n');
                else
                    
                    % interpolate reference dem to subtile
                    zri = interp2(zr.x,zr.y(:),zr.z,x,y(:),'*linear');
                    
                    % create vertical std dev vector
                    dz_std = nan(size(z,3),1);
                    
                    % loop through dems in subtile stack and calculate vertical
                    % difference between dem and reference dem, saving the
                    % standard deviation over land.
                    for i=1:size(z,3)
                        dz =  zri - z(:,:,i);
                        dz_std(i) = nanstd(dz(land));
                    end
                    
                    if ~any(~isnan(dz_std))
                        fprintf('All reference dem differences stddev values are nans\n');
                    else
                        
                        % sort the dems by lowest std dev from reference and select
                        % the least number of dems needed for 100% cover
                        [~,nsort] = sort(dz_std,'ascend');
                        nsort(isnan(dz_std(nsort))) = [];
                        
                    end
                end
            end
            
            % check if ref dem comparison successful
            if isempty(nsort) && size(z,3) > 2
                % if no ref dem, sort by mean coregistration sigma
                avg_sigma_dz_coreg =  accumarray([offsets.i;offsets.j],...
                    [offsets.sigma_dz_coreg;offsets.sigma_dz_coreg],...
                    [],@nanmean);
                
                [~,nsort] = sort(avg_sigma_dz_coreg,'ascend');
                
            end
            
            if ~isempty(nsort)
                % successively calculate coverage provided by each ith dem
                % in order of increasing std dev from reference, breaking
                % when coverage is 100%
                for i=1:length(nsort)
                    c = any(z(:,:,nsort(1:i)),3);
                    if sum(c(:)) == c0
                        break
                    end
                end
                
                % only retain the top ith dems
                nsort = sort(nsort(1:i));
                
            else
                nsort = 1:size(z,3);
            end
            
            % set adjustment thresholds to inf to shut them off or
            % indicate no adjustment
            offsetdiffmax =50;
            offsetErrMax = inf;
            min_sigma_dz_coregMax= inf;
            min_abs_mean_dz_coregMax= inf;
            min_abs_median_dz_coregMax = inf;
            
            % only perform adjustment if more than 1 dem
            if length(nsort) > 1
                
                % find coregistration offsets for pairs of nsort dems
                in = ismember(offsets.i,nsort) & ismember(offsets.j,nsort);
                
                % if these DEMs dont overlap, or are of the same strip,
                % they wont have offsets: skip
                if any(in)
                    
                    % sample the offset structure for the pairs of nsort
                    offsets_sub = structfun(@(x) x(in), offsets,'uniformoutput',0);
                    
                    % perform adjustment for pairs of nsort
                    [dZ(nsort),dX(nsort),dY(nsort)] = adjustOffsets(offsets_sub,...
                        'offsetdiffmax',offsetdiffmax,...
                        'offsetErrMax',offsetErrMax,...
                        'min_sigma_dz_coregMax',min_sigma_dz_coregMax,...
                        'min_abs_mean_dz_coregMax',min_abs_mean_dz_coregMax,...
                        'min_abs_median_dz_coregMax',min_abs_median_dz_coregMax);
                end
            end
            
            % if adjustment still fails, or just one dem, just set to
            % zero for nsort "best" dems.
            if ~any(~isnan(dZ))
                dZ(nsort) = 0;
                dX(nsort) = 0;
                dY(nsort) = 0;
            end
        end
    end
    
    %% apply adustment
    % layers with missing adjustments
    n_missing = isnan(dZ);
    
    % set nan dX and dY to zeros for vertical shift only
    dX(isnan(dX)) = 0;
    dY(isnan(dY)) = 0;
    
    % make adjusted z array
    za=nan(size(z),'single');
    
    % make adjusted mt arrays
    mta = false(size(mt));
    
    % index of layers with adjustments
    iterVec = 1:size(z,3);
    iterVec(n_missing) = [];
    
    fprintf('applying adjustment\n')
    for k=iterVec
        za(:,:,k) = interp2(x + dX(k),y + dY(k), z(:,:,k) + dZ(k),...
            x,y,'*linear');
        
        mtak = interp2(x + dX(k),y + dY(k), single(mt(:,:,k)),...
            x,y,'*nearest');
        
        mtak(isnan(mtak)) = 0;
        mtak = logical(mtak);
        
        mta(:,:,k) = mtak;
        
    end
    
    %% apply a pixel-by-pixel filter to remove outliers
    if filterFlag
        fa = pairwiseDifferenceFilter(za,'mask',land,'minmad',2);
    else
        fa = true(size(za));
    end
    
    % apply filter and get medians
    za(~fa) = NaN;
    mta(~fa) = false;
    
    za_med = single(mynanmedian3(za));
    za_mad = single(mad(za,1,3));
    N = uint8(sum(~isnan(za),3));
    Nmt = uint8(sum(mta,3));
    
    t=t-datenum('1/1/2000 00:00:00');
    t=reshape(t,1,1,[]);
    t=repmat(t,[length(y) length(x) 1]);
    t(isnan(za))=NaN;
    tmax = uint16(max(t,[],3));
    tmin = uint16(min(t,[],3));
    tmean = uint16(nanmean(t,3));
    
    % get stripIDs of dems used in output
    [~,stripIDs] =  cellfun(@fileparts,fileNames(~isnan(dZ)),...
        'uniformoutput',0);
    stripIDs = cellfun( @(x) strsplit(x,'_seg'), stripIDs,...
        'uniformoutput', 0);
    stripIDs = cellfun( @(x) x{1}, stripIDs,...
        'uniformoutput', 0);
    
    save_mat_file(outName, stripIDs, x,y, land, za_med, za_mad, N, Nmt, tmax, tmin, tmean)
    
    if make2mFlag
        fprintf('making 2m version\n')
        
        % if strip segments were combined, need to expand offset vectors and fa
        % array to match orginal file list
        if length(fileNames0) ~= length(fileNames)

            [~,stripid0] =  cellfun(@fileparts,fileNames0,'uniformoutput',0);
            stripid0 =  cellfun(@(x) x(1:47),stripid0,'uniformoutput',0);

            [~,stripid] =  cellfun(@fileparts,fileNames,'uniformoutput',0);
            stripid =  cellfun(@(x) x(1:47),stripid,'uniformoutput',0);

            dZ0 = nan(size(stripid0));
            dX0 = nan(size(stripid0));
            dY0 = nan(size(stripid0));

            % not compatible < matlab 2019b
            %fa0 = false([size(fa,[1 2]),length(stripid0)]);
            
            % back-compatible version
            fa0 = false([size(fa,1),size(fa,2),length(stripid0)]);
    
            for i=1:length(stripid0)
                ind = find(strcmp(stripid0(i),stripid));
                if isempty(ind)
                    continue
                end
                dZ0(i) = dZ(ind);
                dX0(i) = dX(ind);
                dY0(i) = dY(ind);
                fa0(:,:,i) = fa(:,:,ind);
            end
        else
            dZ0 = dZ;
            dX0 = dX;
            dY0 = dY;
            fa0 = fa;
        end

        qcx = cell(size(dZ0));
        qcy = cell(size(dZ0));

        if qcFlag

            [~,names0] =  cellfun(@fileparts,fileNames0,'uniformoutput',0);
            [~,metaNames] =  cellfun(@fileparts,meta.fileName,'uniformoutput',0);

            [~,ind,ind0] = intersect(metaNames, names0);

            qcx(ind0) = meta.qc.x(ind);
            qcy(ind0) = meta.qc.y(ind);
            
        end
        
        fileNames0 = strrep(fileNames0,'_10m.tif','.tif');

        make2m(fileNames0,x,y,dZ0,dX0,dY0,land,fa0,qcx,qcy,outName2m);
    end
    
end
disp("End of buildSubTiles.m");

function [dZ, dX, dY] = perfadj(offsets,z,c0)
        it=1;
        while it < 5
            
            % pairwise coregistration statistics filter threshold defaults
            offsetdiffmax = 50;
            offsetErrMax = 0.1*it;
            min_sigma_dz_coregMax=4*it;
            min_abs_mean_dz_coregMax=0.1*it;
            min_abs_median_dz_coregMax = 1*it;
            
            % perform adjustment for this iteration
            [dZ,dX,dY] = adjustOffsets(offsets,...
                'offsetdiffmax',offsetdiffmax,...
                'offsetErrMax',offsetErrMax,...
                'min_sigma_dz_coregMax',min_sigma_dz_coregMax,...
                'min_abs_mean_dz_coregMax',min_abs_mean_dz_coregMax,...
                'min_abs_median_dz_coregMax',min_abs_median_dz_coregMax);
            
            %check for spatial coverage of z layers with solutions
            c1 = any(z(:,:,~isnan(dZ)),3);
            c1 = sum(c1(:));
            
            % if coverage is 100%, break
            if c1 == c0
                break
            end
            
            % if coverage is < 100%, increase thresholds by 10% and
            % repeat
            it = it+0.1;
        end

function make2m(fileNames,x,y,dZ,dX,dY,land,fa,qc_x,qc_y,outName)

% make date vector
[~,name] =  cellfun(@fileparts,fileNames,'uniformoutput',0);
t=cellfun(@(x) datenum(parsePairnameDatestring(x),'yyyymmdd'),name)';

% layers with missing adjustments
n_missing = isnan(dZ);

dZ(n_missing) = [];
dX(n_missing) = [];
dY(n_missing) = [];
fileNames(n_missing) = [];
fa(:,:,n_missing) = [];
t(n_missing) = [];
qc_x(n_missing) = [];
qc_y(n_missing) = [];

% set nan dX and dY to zeros for vertical shift only
dX(isnan(dX)) = 0;
dY(isnan(dY)) = 0;

fileNames = strrep(fileNames,'_10m.tif','.tif');

[x,y,z,~,mt] =extractSubGrid(fileNames,min(x),max(x),...
    min(y),max(y),2,'applyBitmask',false);

% apply qc masks if provided
nn = find(~cellfun( @isempty, qc_x));
for j=1:length(nn)
    ztmp = z(:,:,nn(j));
    mttmp = mt(:,:,nn(j));
    BW = false(size(ztmp));
    for k=1:length(qc_x{nn(j)})
        BW = BW | roipoly(x,y,ztmp,qc_x{nn(j)}{k},...
            qc_y{nn(j)}{k});
    end
    ztmp(BW) = NaN;
    z(:,:,nn(j)) = ztmp;
    mttmp(BW) = false;
    mt(:,:,nn(j)) = mttmp;
end

% merge segmentsfrom same strips
% dont get offsets between segs in same strip:make a vector of z's
% that ar belonging to the same strip
[~,stripIDs] =  cellfun(@fileparts,fileNames(~isnan(dZ)),...
    'uniformoutput',0);
stripIDs = cellfun( @(x) strsplit(x,'_seg'), stripIDs,...
    'uniformoutput', 0);
stripIDs = cellfun( @(x) x{1}, stripIDs,...
    'uniformoutput', 0);
unique_stripIDs = unique(stripIDs);

r=[];
it=1;
for it=1:length(unique_stripIDs)
    
    segs = find(strcmp(stripIDs,unique_stripIDs(it)));
    
    if length(segs) > 1
        
        z(:,:,segs(1)) = mynanmedian3(z(:,:,segs));
        
        mt(:,:,segs(1)) = any(mt(:,:,segs),3);
        
        segs=segs(:);
        r = [r(:);segs(2:end)];
    end
end

z(:,:,r) = [];
mt(:,:,r) = [];
stripIDs(r) = [];
t(r) = [];
dZ(r) = [];
dX(r) = [];
dY(r) = [];

% make adjusted z and mt arrays
za=nan(size(z),'single');
mta = false(size(mt));
for k=1:size(z,3)
    zak = interp2(x + dX(k),y + dY(k), z(:,:,k) + dZ(k),...
        x,y,'*linear');
    
    mtak = interp2(x + dX(k),y + dY(k), single(mt(:,:,k)),...
        x,y,'*nearest');
    
    mtak(isnan(mtak)) = 0;
    mtak = logical(mtak);
    
    if any(any(~fa(:,:,k)))
        fak = imresize(fa(:,:,k),size(za(:,:,k)),'nearest');
        zak(~fak)=NaN;
        mtak(~fak) = false;
    end
    
    za(:,:,k) = zak;
    mta(:,:,k) = mtak;
end

za_med = mynanmedian3(za);
za_mad = mad(za,1,3);
N = uint8(sum(~isnan(za),3));
Nmt = uint8(sum(mta,3));

% resize land mask
land = imresize(land,size(za_med),'nearest');

t=t-datenum('1/1/2000 00:00:00');
t=reshape(t,1,1,[]);
t=repmat(t,size(za_med));
t(isnan(za))=NaN;
tmax = max(t,[],3);
tmin = min(t,[],3);
tmean = nanmean(t,3);

tmax = uint16(tmax);
tmin = uint16(tmin);
tmean = uint16(tmean);

fprintf('saving stripIDs, x, y za_med land za_mad N tmax tmin tmean to %s\n',outName)
save(outName,'stripIDs','x','y','za_med','land','za_mad','N','Nmt','tmax','tmin','tmean','-v7.3');

function save_mat_file(outName, stripIDs, x,y, land, za_med, za_mad, N, Nmt, tmax, tmin, tmean)
    save(outName,'stripIDs','x','y','land','za_med','za_mad','N','Nmt',...
        'tmax','tmin','tmean','-v7.3')

function field_out = trimMetaStructFieldByN(field_in, n)
    if isstruct(field_in)
        field_out = structfun(@(x) trimMetaStructFieldByN(x,n), field_in, 'uniformoutput',0);
    else
        field_out = field_in(n);
    end
