function addInfoToSubtileMosaic(varargin)
% addInfoToSubtileMosaic loop through subtiles for info and add to
% existing mosaic file

subTileDir = varargin{1};
dx = varargin{2};

outName = varargin{3};

if ~exist(outName,'file')
    fprintf('File %s not found, returning\n',outName)
    return
end

variableInfo = who('-file', outName);
if ismember('stripList', variableInfo)
    fprintf('File %s already contains stripList var, returning\n',outName)
    return
end

if nargin == 4
    quadrant = varargin{4};
end

fprintf('Indexing subtiles\n')

% make a cellstr of resolved subtile filenames
subTileFiles=dir([subTileDir,'/*_',num2str(dx),'m.mat']);
if isempty(subTileFiles)
    error('No files found matching %s',...
        [subTileDir,'/*_',num2str(dx),'m.mat']);
end

subTileFiles=cellfun( @(x) [subTileDir,'/',x],{subTileFiles.name},...
    'uniformoutput',0);

% Get rows and cols of subtile from file names - assumes the subtile
% names is *_{row}_{col}_{res}.mat
[~,subTileName] = cellfun(@fileparts,subTileFiles,'uniformoutput',0);
subTileName=cellfun(@(x) strsplit(x,'_'),subTileName,'uniformoutput',0);
subTileCol = cellfun(@(x) str2num(x{end-1}),subTileName);
subTileRow = cellfun(@(x) str2num(x{end-2}),subTileName);

Ncols = max(subTileCol);
Nrows = max(subTileRow);

% Get tile projection information, esp. from UTM tile name
%[tileProjName,projection] = getProjName(subTileName{1}{1},projection);

% column-wise subtile number
subTileNum = sub2ind([Nrows,Ncols],subTileRow,subTileCol);

% % sort subtilefiles by ascending subtile number order
[subTileNum,n] = sort(subTileNum);
subTileCol = subTileCol(n);
subTileRow= subTileRow(n);
subTileFiles = subTileFiles(n);

if exist('quadrant','var')
    fprintf('selecting subtiles in quadrant %s\n',quadrant)
    % select subtiles by quadrant
    switch quadrant
        case lower('1_1') %lower left quadrant
            n = mod(subTileNum,100) >= 1 & mod(subTileNum,100) <= 51 &...
                subTileNum <= 5100;
        case lower('2_1') %upper left quadrant
            n =  (mod(subTileNum,100) >= 50 | mod(subTileNum,100) == 0) &...
                subTileNum <= 5100;
        case lower('1_2') %lower right quadrant
            n = mod(subTileNum,100) >= 1 & mod(subTileNum,100) <= 51 &...
                subTileNum > 4900;
        case lower('2_2') %upper right quadrant
            n =  (mod(subTileNum,100) >= 50 | mod(subTileNum,100) == 0) &...
                subTileNum > 4900;
        otherwise
            error('quadrant string not recognized')
    end
    
    if ~any(n)
        fprintf('No subtiles within quadrant %s\n',quadrant)
        return
    end
    
    subTileNum = subTileNum(n);
    subTileFiles = subTileFiles(n); 
end

NsubTileFiles = length(subTileFiles);
  
stripList=[];
parfor filen=1:NsubTileFiles

    fprintf('extracting info from subtile %d of %d: %s\n',filen,NsubTileFiles,subTileFiles{filen})
    
    % get list of variables within this subtile mat file
    mvars  = who('-file',subTileFiles{filen});
    
    if ~any(ismember(mvars,'za_med'))
        fprintf('no za_med found, skipping\n')
        continue
    end
    
    % load subtile into structure - iif 2m, need to switch to 10m filename
    % since no filename list in 2m version.
    if any(ismember(mvars,'fileNames'))
        
        zsub=load(strrep(subTileFiles{filen},'_2m.mat','_10m.mat'),'fileNames','dZ');
        zsub.fileNames = zsub.fileNames(~isnan(zsub.dZ));
    
        if isempty(zsub.fileNames)
                fprintf('no filenames returned, skipping\n')
                continue
        end
    
        [~,stripid] =  cellfun(@fileparts,zsub.fileNames,'uniformoutput',0);
        if dx == 2
            stripid= strrep(stripid,'_10m','');
        end
        % stripid =  cellfun(@(x) x(1:47),stripid,'uniformoutput',0);
       
    elseif any(ismember(mvars,'stripIDs'))
        
        zsub=load(subTileFiles{filen},'stripIDs');

        if isempty(zsub.stripIDs)
            fprintf('no stripIDs returned, skipping\n')
            continue
        end
       
        stripid=zsub.stripIDs;
   else
        error('neither stripIDs or fileNames vars in %s',subTileFiles{filen})
    end
       
    stripList = [stripList, stripid];

end

stripList=unique(stripList);
save(outName,'-append','stripList')






