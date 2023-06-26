function mask = circleFeatherMask(diameter, featherStartRadius)

if mod(diameter, 2) == 0
   diameter = diameter - 1;
end
radius = (diameter - 1) / 2;

dim = radius * 2 + 1;

xdim = dim;
ydim = dim;

xc = radius + 1;
yc = radius + 1;

[xx,yy] = meshgrid(1:xdim, 1:ydim);
mask = 1 - min(1, max(0, (hypot(xx - xc, yy - yc) - featherStartRadius) / (radius - featherStartRadius)));
