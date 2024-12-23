function compileDatabase4_func(regionDir, dbase_out)
    % Compile a matlab DB of the strips in the regionDir folder and
    % write to the file dbase_out.

    [scriptdir, name, ext] = fileparts(mfilename('fullpath'));
    addpath([scriptdir, '/../setsm_postprocessing4/']);
    if exist('out0','var')
        clear out0
    end

    % TODO: Check regionDir exists and the dir of dbase_out exists

    stripFilePrefix='SETSM_s2s041_';
    bwpy_prefix='';

    %reproject_list = strrep(dbase_out, '.mat', '_reproject_list.txt');
    %if isfile(reproject_list) && ~isfile([reproject_list,'.bak'])
    %    reproject_list_stat = dir(reproject_list);
    %    if reproject_list_stat.bytes > 0
    %        copyfile(reproject_list, [reproject_list,'.bak']);
    %    end
    %end
    %reproject_list_fp = fopen(reproject_list, 'wt');

    %mosaic_zones_shp = '/mnt/pgc/data/projects/earthdem/EarthDEM_mosaic_zones_v3.shp';
    %mosaic_zones_shp = 'EarthDEM_mosaic_zones_v3.shp';
    %mosaic_zones_mapstruct = shaperead(mosaic_zones_shp);
    %mosaic_zones_mapstruct = shaperead(mosaic_zones_shp, 'UseGeoCoords',true);
    %mosaic_zones_polyshape_arr = arrayfun(@(feat) polyshape(feat.X, feat.Y), mosaic_zones_mapstruct);

    proj4_projname_dict = containers.Map;
    proj4_geotiffinfo_dict = containers.Map;
    proj4_epsg_dict = containers.Map;

    %%% CHECK THIS SETTING %%%
    report_number_of_strips_to_append_but_dont_actually_append = false;
    %%% CHECK THIS SETTING %%%
    regionDirs=[
        dir([regionDir,'/2m*']),
    ];
    regionDirs=regionDirs([regionDirs.isdir]);
    regionDirs=cellfun(@(regionDir, regionName) [regionDir,'/',regionName], {regionDirs.folder}, {regionDirs.name},...
        'UniformOutput',false);

    regionDirs = regionDirs((~cellfun('isempty', regexp(regionDirs, '.*/2m$')) | (~cellfun('isempty', regexp(regionDirs, '.*/2m_utm\d{2}[ns]$')))));


    if exist('dbase_in', 'var') && ~isempty(dbase_in)
        if ~isfile(dbase_in)
            error('Input database does not exist: %s\n', dbase_in);
        end
    end
    if ~exist('dbase_out', 'var') || isempty(dbase_out)
        error('Output database variable "dbase_out" must be set');
    elseif isfile(dbase_out)
        error('Output database already exists: %s\n', dbase_out);
    end

    if exist('dbase_in', 'var') && ~isempty(dbase_in)
        fprintf('Loading database to be appended to: %s\n', dbase_in);
        fprintf('Output database will be: %s\n', dbase_out);
        out0=matfile(dbase_in);
        [stripDirs0,~,~] = cellfun(@fileparts, out0.fileName, 'UniformOutput',false);
        stripDirs0_nover = cellfun(@(x) regexprep(x,'(?:_lsf)?_v\d{6}$',''), stripDirs0, 'UniformOutput',false);
    else
        fprintf('Creating new database: %s\n', dbase_out);
    end


    meta=[];

    i=1;
    for i=1:length(regionDirs)

        regionDir=regionDirs{i};

        [~,stripResDirname,~] = fileparts(regionDir);
        if strcmp(stripResDirname, '2m')
            is_reprojected = false;
        else
            is_reprojected = true;
        end

        if exist(regionDir,'dir') == 7

    %        if exist('out0','var')
    %            [~,IA] = intersect(metaFiles, out0.fileName);
    %            metaFiles(IA) = [];
    %            if isempty(metaFiles)
    %                continue
    %            end
    %        end
    %
    %        metaFiles=dir([regionDir,'/*_2m*/*meta.txt']);
    %        metaFiles = strcat({metaFiles.folder}',repmat({'/'},length(metaFiles),1),{metaFiles.name}');
    %
    %        j=1;
    %        for j=1:length(metaFiles)
    %            metaFile=metaFiles{j};
    %            fprintf('adding file %s\n',metaFile)
    %            if isempty(meta)
    %                meta=readStripMeta(metaFile,'noSceneMeta');
    %            else
    %                meta(length(meta)+1)=readStripMeta(metaFile,'noSceneMeta');
    %            end
    %        end

            stripDir_pattern=[regionDir,'/*_2m*'];
            fprintf('Gathering strips with pattern: %s ... ', stripDir_pattern)

            stripDirs=dir(stripDir_pattern);
            if isempty(stripDirs)
                fprintf('None found\n')
                continue
            end
            stripDirs=stripDirs([stripDirs.isdir]);
            stripDirs = strcat({stripDirs.folder}',repmat({'/'},length(stripDirs),1),{stripDirs.name}');
            if length(stripDirs) == 0
                fprintf('None found\n')
                continue
            end


    %        % check for duplicate strips
    %        [~,stripDnames,~] = cellfun(@fileparts, stripDirs, 'UniformOutput', false);
    %        test_dup_stripids=stripDnames;
    %        k=1;
    %        for k=1:length(test_dup_stripids)
    %            stripid = test_dup_stripids{k};
    %            stripid_parts = strsplit(test_dup_stripids{k}, '_');
    %            strip_verkey = stripid_parts(end);
    %            strip_verkey = strip_verkey{1};
    %            if length(strip_verkey) == 7 && strcmp(strip_verkey(1), 'v') && ~isnan(str2double(strip_verkey(2:7)))
    %                stripid = strrep(stripid, ['_',strip_verkey], '');
    %                test_dup_stripids{k} = stripid;
    %            end
    %        end
    %        [~, uniqueIdx] = unique(test_dup_stripids);
    %        test_dup_stripids(uniqueIdx) = [];
    %        if length(test_dup_stripids) > 0
    %            fprintf('\nERROR: Multiple strips exist matching strip ID:\n')
    %            test_dup_stripids
    %            fprintf('Exiting early -- Nothing was written to database\n')
    %            return
    %        end

            % keep only the highest '_vXXYYZZ' setsm version of duplicate strips
            [~,stripDnames,~] = cellfun(@fileparts, stripDirs, 'UniformOutput', false);
            [stripDnames, I] = sort(stripDnames);
            stripDirs = stripDirs(I);
            stripDnames_nover = cellfun(@(x) regexprep(x,'(?:_lsf)?_v\d{6}$',''), stripDnames, 'UniformOutput',false);
            [~,IA] = unique(stripDnames_nover, 'last');
            stripDirs = stripDirs(IA);


            % difference strips with database to be appended to
            if exist('out0','var')
                stripDirs_nover = cellfun(@(x) regexprep(x,'(?:_lsf)?_v\d{6}$',''), stripDirs, 'UniformOutput',false);
                Lia = ismember(stripDirs_nover, stripDirs0_nover);
                stripDirs(Lia) = [];
                if isempty(stripDirs)
                    fprintf('No new strips to add\n')
                    continue
                end
            end


    %        if ~is_reprojected
    %            % check for .fin file and data in strip folders
    %            [~,stripDnames,~] = cellfun(@fileparts, stripDirs, 'UniformOutput', false);
    %
    %            stripDirs_miss_fin_ind = cellfun(@(x, y) ~isfile([x,'/',y,'.fin']), stripDirs, stripDnames);
    %            stripDirs_miss_data_ind = cellfun(@(x, y) ~isfile([x,'/',stripFilePrefix,regexprep(y,'_v\d{6}',''),'_seg1_dem.tif']), stripDirs, stripDnames);
    %
    %            missing_fin_count = nnz(stripDirs_miss_fin_ind);
    %            if missing_fin_count > 0
    %                fprintf("WARNING! Found %d strippair folders with no .fin file:", missing_fin_count)
    %                stripDirs(stripDirs_miss_fin_ind)
    %            end
    %
    %            stripDirs(stripDirs_miss_fin_ind | stripDirs_miss_data_ind) = [];
    %        end


            num_strips_to_add=length(stripDirs);
            fprintf('%d to add\n', num_strips_to_add);

            if report_number_of_strips_to_append_but_dont_actually_append
                continue
            end

            k=1;
            last_print_len=0;
            for k=1:length(stripDirs)
                stripDir=stripDirs{k};

                fprintf(repmat('\b', 1, last_print_len));
                last_print_len=fprintf('Reading strip (%d/%d): %s',k,num_strips_to_add,stripDir);

    %            if ~is_reprojected
    %                finFile=dir([stripDir,'/*.fin']);
    %                if isempty(finFile); continue; end
    %            end

                metaFiles=dir([stripDir,'/*meta.txt']);
                if isempty(metaFiles); continue; end
                metaFiles = strcat({metaFiles.folder}',repmat({'/'},length(metaFiles),1),{metaFiles.name}');

                j=1;
                for j=1:length(metaFiles)
                    metaFile=metaFiles{j};
    %                fprintf('adding file %s\n',metaFile)
                    strip_meta = readStripMeta(metaFile,'noSceneMeta');
                    strip_proj4 = strip_meta.strip_projection_proj4;


    %                % populate strip meta "strip_projection_name" field
    %                if any(strcmp(keys(proj4_projname_dict), strip_proj4))
    %                    strip_projname = proj4_projname_dict(strip_proj4);
    %                else
    %                    strip_projname = '';
    %
    %                    for mosaic_zone_ms_i = 1:length(mosaic_zones_mapstruct)
    %                        mosaic_zone_feat = mosaic_zones_mapstruct(mosaic_zone_ms_i);
    %
    %                        cmd = sprintf('%s python proj_issame.py "%s" "EPSG:%d" ', bwpy_prefix, strip_proj4, mosaic_zone_feat.epsg);
    %                        [status, cmdout] = system(cmd);
    %                        if ~isempty(cmdout)
    %                            fprintf(['\n',cmdout,'\n']);
    %                        end
    %                        if status == 2
    %                            error('\nCaught exit status 2 from proj_issame.py indicating error\n');
    %                        elseif status == 0
    %                            strip_projname = mosaic_zone_feat.name;
    %                            break;
    %                        end
    %                    end
    %
    %                    if isempty(strip_projname)
    %                        fprintf('\nERROR! Could not find matching mosaic zone projection for strip PROJ.4 string: %s\n', strip_proj4);
    %                    end
    %
    %                    proj4_projname_dict(strip_proj4) = strip_projname;
    %                end
    %
    %                strip_meta.strip_projection_name = strip_projname;


                    if ~is_reprojected
                        % check projection onformation is consistent
                        if any(strcmp(keys(proj4_geotiffinfo_dict), strip_proj4))
                            strip_gtinfo = proj4_geotiffinfo_dict(strip_proj4);
                        else
                            demFile = strrep(metaFile, 'meta.txt', 'dem.tif');
                            cmd = sprintf('%s python %s/proj_issame.py "%s" "%s" ', bwpy_prefix, scriptdir, demFile, strip_proj4);
                            [status, cmdout] = system(cmd);
                            if ~isempty(cmdout)
                                fprintf(['\n',cmdout,'\n']);
                            end
                            if status == 2
                                error('\nCaught exit status 2 from proj_issame.py indicating error\n');
                            elseif status == 1
                                fprintf('\nProjection of strip DEM raster and PROJ.4 string in strip meta.txt file are not equal: %s, %s\n', demFile, strip_proj4);
                            end
                            strip_gtinfo = geotiffinfo(demFile);
                            proj4_geotiffinfo_dict(strip_proj4) = strip_gtinfo;
                        end

                        % determine if strip needs to be reprojected
    %                    [strip_lat, strip_lon] = projinv(strip_gtinfo, strip_meta.x, strip_meta.y);
    %                    strip_poly = polyshape(strip_lon, strip_lat);
    %                    mosaic_zones_overlapped = overlaps(strip_poly, mosaic_zones_polyshape_arr);
    %                    mosaic_zones_overlapped_ms = mosaic_zones_mapstruct(mosaic_zones_overlapped);
    %
    %                    for mosaic_zone_ms_i = 1:length(mosaic_zones_overlapped_ms)
    %                        mosaic_zone_ms = mosaic_zones_overlapped_ms(mosaic_zone_ms_i);
    %
    %                        reproject_strip = true;
    %
    %                        if any(strcmp(keys(proj4_epsg_dict), strip_proj4))
    %                            if proj4_epsg_dict(strip_proj4) == mosaic_zone_ms.epsg
    %                                reproject_strip = false;
    %                            end
    %                        else
    %                            cmd = sprintf('%s python proj_issame.py "%s" "EPSG:%d" ', bwpy_prefix, strip_proj4, mosaic_zone_ms.epsg);
    %                            [status, cmdout] = system(cmd);
    %                            if ~isempty(cmdout)
    %                                fprintf(['\n',cmdout,'\n']);
    %                            end
    %                            if status == 2
    %                                error('\nCaught exit status 2 from proj_issame.py indicating error\n');
    %                            elseif status == 0
    %                                proj4_epsg_dict(strip_proj4) = mosaic_zone_ms.epsg;
    %                                reproject_strip = false;
    %                            end
    %                        end
    %
    %                        if reproject_strip
    %                            metaFile_reproj = strrep(metaFile, ['/2m'], ['/2m_',mosaic_zone_ms.name]);
    %                            if ~isfile(metaFile_reproj)
    %                                fprintf(reproject_list_fp, "%s %s %d\n", metaFile, mosaic_zone_ms.name, mosaic_zone_ms.epsg);
    %                            end
    %                        end
    %                    end
                    end


                    try
                        if isempty(meta)
                            meta=strip_meta;
                        else
                            meta(length(meta)+1)=strip_meta;
                        end
                    catch ME
                        meta
                        strip_meta
                        rethrow(ME)
                    end

                end
            end
            fprintf('\n')
        end
    end

    %fclose(reproject_list_fp);

    if isempty(meta)
        fprintf('\nNo records to add to database\n')
        return
    end

    flds = fields(meta);
    i=1;
    for i =1:length(flds)
        fld = flds{i};
        eval(['out.',fld,'= {meta.',fld,'};']);
    end

    [filePath,out.stripName] = cellfun(@fileparts,out.fileName,'uniformoutput',0);
    out.stripName=strrep(out.stripName,'_meta','');

    stripNameChar=char(out.stripName{:});

    out.stripDate=cellfun(@(x) datenum(parsePairnameDatestring(x),'yyyymmdd'), out.stripName, 'uniformoutput',0);
    out.stripDate=cell2mat(out.stripDate);

    out.satID=cellstr(stripNameChar(:,1:4))';

    out.creation_date = [out.creation_date{:}];
    out.strip_creation_date = [out.strip_creation_date{:}];
    out.A = [out.A{:}];

    fprintf('Writing %d new records to database file\n',length(out.fileName));
    if exist('out0','var')
        flds = fields(out);
        i=1;
        for i =1:length(flds)
            fld = flds{i};
            eval(['out.',fld,'= [out0.',fld,',out.',fld,'];']);
        end
    end

    fprintf('Writing %d total records to %s\n',length(out.fileName),dbase_out);
    save(dbase_out,'-struct','out','-v7.3');
