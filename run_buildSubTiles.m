function run_buildSubTiles(...
    tileName,outDir,...
    projection,tileDefFile,...
    stripDatabaseFile,stripsDirectory,...
    waterTileDir,refDemFile,...
    tileqcDir,tileParamListFile,...
    make2m...
)

try
    [meta,landTile] = initializeMosaic('',tileName,'',...
        'projection',projection,'tileDefFile',tileDefFile,...
        'stripDatabaseFile',stripDatabaseFile,'stripsDirectory',stripsDirectory,...
        'waterTileDir',waterTileDir,'refDemFile',refDemFile,...
        'tileqcDir',tileqcDir,'tileParamListFile',tileParamListFile,...
        'returnMetaOnly',true...
    );
    buildSubTiles(tileName,outDir,tileDefFile,meta,...
        'landTile',landTile,...
        'refDemFile',refDemFile,...
        'make2m',make2m,...
        'projection',projection...
    )
catch e
    disp(getReport(e)); exit(1)
end

exit(0)
