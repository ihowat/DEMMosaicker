function tileMetav4(f,varargin)
% tileMeta: write meta file for ArcticDEM mosaic tile
%
%   tileMeta(f) where f is either the filename or matfile handle of the
%   tile matfile.

project='Unspecified';
tileVersion='Unspecified';

% Parse varargins
n = find(strcmpi(varargin,'project'));
if ~isempty(n)
    project = varargin{n+1};
    fprintf('project = %s\n',project)
end

n = find(strcmpi(varargin,'tileVersion'));
if ~isempty(n)
    tileVersion = varargin{n+1};
    fprintf('tileVersion = %s\n',tileVersion)
end

%% first test if input arg is either a valid filename or mat file handle
if isstr(f) % it's a string, might be a filename
    if exist(f,'file') % yup its a file
        m = matfile(f); % load it
    else
        error('File does not exist');
    end
elseif isvalid(f) % not a string, is it a valid file handle?
    m = f; % yes, so set m to f and get the filename for f
    f = m.Properties.Source;
else error('input arg must be a filename or valid matfile handle')
end

% make outname
outfile=strrep(f,'.mat','_meta.txt');
varlist = who(m);
fileAtts= dir(m.Properties.Source);

% test if exists, skip if does
if exist(outfile,'file') 
    fprintf('%s exists, skipping\n',outfile);
    return;
end
    
%% Read and format strip info
if ~isempty(whos(m,'stripList'))
    strip.name=unique(m.stripList);
    strip.name=strip.name(:);
else
    fprintf('WARNING stripList variable not found in matfile\n')
end

%% Get tile version
if ~isempty(whos(m,'version'))
    pv=strsplit(m.version,'|');
    if length(pv) == 2
        project=pv{1};
        tileVersion=pv{2};
    elseif length(pv) == 1
        tileVersion=pv{1};
    end
end

fprintf('writing meta\n')

%% Write File
fid=fopen(outfile,'w');
fprintf(fid,'%s Mosaic Tile Metadata \n',project);
fprintf(fid, 'Tile: %s\n', strrep(fileAtts.name,'.mat',''));
fprintf(fid,'Creation Date: %s\n',fileAtts.date);
fprintf(fid,'Version: %s\n',tileVersion);
fprintf(fid,'\n');

if ~isempty(whos(m,'icesat_dz_N'))
    fprintf(fid,'ICESat N points: %d\n',m.icesat_dz_N);
    fprintf(fid,'ICESat median offset: %.2f\n',m.icesat_dz_med);
    fprintf(fid,'ICESat median absolute deviation: %.2f\n',m.icesat_dz_mad);
    fprintf(fid,'\n');
end

fprintf(fid,'Adjacent Tile Blend Status \n');
fprintf(fid,'Right edge merged: %s\n', mat2str(any(strcmp(varlist,'mergedRight'))));
fprintf(fid,'Left edge merged: %s\n', mat2str(any(strcmp(varlist,'mergedLeft'))));
fprintf(fid,'Top edge merged: %s\n', mat2str(any(strcmp(varlist,'mergedTop'))));
fprintf(fid,'Bottom edge merged: %s\n', mat2str(any(strcmp(varlist,'mergedBottom'))));
fprintf(fid,'\n');

fprintf(fid,'List of DEMs used in mosaic:\n');
if ~isempty(whos(m,'stripList'))
    i=1;
    for i=1:length(strip.name)
        fprintf(fid,'%s\n',...
            strip.name{i});
    end
else
    fprintf(fid,'No component data found\n');
end

fclose(fid);
    
