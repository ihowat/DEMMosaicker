function registerTile(m,gcp)
% registerTile register tiles to ground control
%
%   registerTile(m,gcp) registers the DEM tile mosaic z in matlab file
%   handle m (with m.z as elevation) to the gcp points in structure gcp,
%   which has fields gcp.x, gcp.y and gcp.z.
% 
%   subfuncs: polyCropGCPs, pointAreaSubsets, registerDEM2LIDAR, 
%   applyRegistration

%% Check for multiple coregistration clusters

% fastest is to look for a zero dtrans's
coregClusters=sum(sum(m.dtrans==0)==3);

% if no un-co-registered data, return
if coregClusters == 0; 
    fprintf('All data is registered, skipping\n');
    return
end

% load coregistration cluster
C=m.C;

sz = whos(m,'z'); sz = sz.size; % image dimensions info
z = nan(sz,'single'); % initialize output

%create output file
outname=strrep(m.Properties.Source,'dem.mat','reg_dem.mat');

m1 = matfile(outname,'Writable',true);

% cluster coregistraton loop
for i=1:coregClusters
    
    % make a mask of this cluster
    N = C == i+1;
    
    %% load overlapping GCPs full tile boundaries
    
    % make tile polygon footprint vertices from rectangular coordinate range
    x=m.x;
    y=m.y;
    
    minx=min(x);
    maxx=max(x);
    miny=min(y);
    maxy=max(y);
    
    xv=[minx,minx,maxx,maxx,minx];
    yv=[miny,maxy,maxy,miny,miny];
    
    n=polyCropGCPs(gcp,xv,yv,'rectangle');
    
    % skip if too few
    if length(n) < 4;
        fprintf('%d overlapping points, too few,skipping\n',sum(nn));
        return;
    end
    
    % find gcp's over these pixels
    col = round((gcp.x(n) - minx)/(x(2)-x(1)));
    row = round((gcp.y(n) - maxy)/(y(2)-y(1)));
    col(col < 1)=1; row(row < 1) = 1;
    col(col > length(x)) = length(x); row(row > length(y)) = length(y);
    gcpind = sub2ind([length(y),length(x)],row,col);
    nn = N(gcpind);
    
    n = n(nn);
    
    % skip if too few
    if length(n) < 4;
        fprintf('%d overlapping points, too few,skipping\n',sum(nn));
        return;
    end
    
    %subsample GCPs to near maximum # for speed/memory
    maxGcps=100;
    if length(n) > maxGcps
        n=n(1:floor(length(n)/ maxGcps):length(n));
    end
    
    %% Registration with subsetting
    % For fitting to control, we can either load the whole image or load
    % subsets of the image in the neighborhood of each control point with
    % a size large enough to allow for shifting within the expected image
    % registration error. The former is fastest for larger numbers of GCPs
    % and or smaller image sizes. We can select by calculating the total
    % number of pixels to be loaded by each method and use the less.
    
    % subset size expect +/- 20m maximum image displacement
    res=diff(x(1:2));
    dd=20/res;
    
    [xsub,ysub,zsub]=pointAreaSubsets(gcp.x(n),gcp.y(n),x,y,m,dd,N);
    
    % send to registration fx
    [dtrans,dzall] = ...
        registerDEM2LIDAR(xsub,ysub,zsub,gcp.x(n),gcp.y(n),gcp.z(n));
        
    clear xsub ysub zsub gcp n
    
    %% Apply registration
    ztemp = applyRegistration(dtrans,m,N);
    
    clear N
    
    n=isnan(z) & ~isnan(ztemp);
    z(n) = ztemp(n);
    
    clear ztemp n
    
    m1.dtrans{i} = dtrans;
    m1.dzall{i} = dzall;
    
end

% write to matfile
m1.x=x;
m1.y=y;
m1.z=z;

clear z

%% Apply registration to mt grid variable

% cluster coregistraton loop
mt = false(sz); % initialize output
for i=1:coregClusters
    
    % make a mask of this cluster
    N = C == i+1;
 
    % Apply registration
    mttemp = applyRegistration(m.dtrans(:,i),m,N,'mt');
    
    % add in any matches
    mt = mt | mttemp;
    
    clear mttemp
    
end

m1.mt=mt;

clear mt

%% Apply registration to or grid variable

% cluster coregistraton loop
or = single(sz,'int16'); % initialize output
for i=1:coregClusters
    
    % make a mask of this cluster
    N = C == i+1;
 
    % Apply registration
    ortemp = applyRegistration(m.dtrans(:,i),m,N,'or');
    
    clear N
    
    n= or==0 & ortemp ~= 0;
    or(n) = ortemp(n);
    
    clear ortemp n
    
end

m1.or=or;

clear or

%% Apply registration to dy grid variable

% cluster coregistraton loop
dy= single(sz,'int16'); % initialize output
for i=1:coregClusters
    
    % make a mask of this cluster
    N = C == i+1;
 
    % Apply registration
    dytemp = applyRegistration(m.dtrans(:,i),m,N,'dy');
    
    clear N
    
    n= dy==0 & dytemp ~= 0;
    dy(n) = dytemp(n);
    
    clear dytemp n
    
end

m1.dy=dy;

clear dy

