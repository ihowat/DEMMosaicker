function compileDatabase4_func(regionDir, dbase_out)
    % Compile a matlab DB of the strips in the regionDir folder and
    % write to the file dbase_out. Designed to work with the dem_mosaic_strip_prep.py
    % script which puts strip DEMs in directories called 2m and 2m_proj.

    [scriptdir, name, ext] = fileparts(mfilename('fullpath'));
    addpath([scriptdir, '/../setsm_postprocessing4/']);
    if exist('out0','var')
        clear out0
    end

    % TODO: Check regionDir exists and the dir of dbase_out exists

    stripFilePrefix='SETSM_s2s041_';
    bwpy_prefix='';
    proj4_geotiffinfo_dict = containers.Map;

    %%% CHECK THIS SETTING %%%
    report_number_of_strips_to_append_but_dont_actually_append = false;
    %%% CHECK THIS SETTING %%%

    regionDirs=[
        dir([regionDir,'/2m*']),
    ];
    regionDirs=regionDirs([regionDirs.isdir]);
    regionDirs=cellfun(@(regionDir, regionName) [regionDir,'/',regionName], {regionDirs.folder}, {regionDirs.name},...
        'UniformOutput',false);

    regionDirs = regionDirs((~cellfun('isempty', regexp(regionDirs, '.*/2m$')) | (~cellfun('isempty', regexp(regionDirs, '.*/2m_proj$')))));

    if isfile(dbase_out)
        error('Output database already exists: %s\n', dbase_out);
    end
    fprintf('Creating new database: %s\n', dbase_out);
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

            % keep only the highest '_vXXYYZZ' setsm version of duplicate strips - should not be needed if
            %  strip_dem_master is the query source
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

                metaFiles=dir([stripDir,'/*meta.txt']);
                if isempty(metaFiles); continue; end
                metaFiles = strcat({metaFiles.folder}',repmat({'/'},length(metaFiles),1),{metaFiles.name}');

                j=1;
                for j=1:length(metaFiles)
                    metaFile=metaFiles{j};
    %                fprintf('adding file %s\n',metaFile)
                    strip_meta = readStripMeta(metaFile,'noSceneMeta');
                    strip_proj4 = strip_meta.strip_projection_proj4;

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
