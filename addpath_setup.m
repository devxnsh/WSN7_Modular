% =====================================================
% WSN7_MODULAR PATH INITIALIZATION
% =====================================================
% Run this FIRST when starting MATLAB in the WSN7_MODULAR directory
%
% Usage:
%   >> addpath_setup
%   >> WSN_Main()  % or any other entry point
%
% This script adds all tier, utility, GUI, and simulator folders to the MATLAB path
% so that files can be organized hierarchically while remaining accessible.

function addpath_setup()
    % Get the root directory of WSN7_MODULAR
    rootDir = fileparts(mfilename('fullpath'));

    fprintf('\n[SETUP] Initializing WSN7_MODULAR path structure...\n');
    fprintf('[SETUP] Root: %s\n\n', rootDir);

    % =====================================================
    % TIER FOLDERS (Node implementations)
    % =====================================================
    tierDirs = {'SN', 'CH', 'GWN', 'SINK'};
    for i = 1:numel(tierDirs)
        tierPath = fullfile(rootDir, tierDirs{i});
        if isfolder(tierPath)
            addpath(tierPath);
            fprintf('[✓] Added tier folder: %s/\n', tierDirs{i});
        end
    end

    % Add tier subfolders for split functionality (Registry/Enforcement/FeatureExport)
    splitTierDirs = {'SINK', 'CH', 'GWN'};
    subModuleDirs = {'Registry', 'Enforcement', 'FeatureExport'};
    for i = 1:numel(splitTierDirs)
        for j = 1:numel(subModuleDirs)
            subPath = fullfile(rootDir, splitTierDirs{i}, subModuleDirs{j});
            if isfolder(subPath)
                addpath(subPath);
                fprintf('[✓] Added %s subfolder: %s/%s/\n', splitTierDirs{i}, splitTierDirs{i}, subModuleDirs{j});
            end
        end
    end

    % =====================================================
    % UTILITY FOLDER (Common utilities)
    % =====================================================
    utilPath = fullfile(rootDir, 'Utils');
    if isfolder(utilPath)
        addpath(utilPath);
        fprintf('[✓] Added utilities: Utils/\n');
    end

    % =====================================================
    % ATTACKS FOLDER (Attack system - not part of Simulator)
    % =====================================================
    attacksPath = fullfile(rootDir, 'Attacks');
    if isfolder(attacksPath)
        addpath(attacksPath);
        fprintf('[✓] Added attack system: Attacks/\n');
    end

    % =====================================================
    % GUI FOLDER (Visualization components)
    % =====================================================
    guiPath = fullfile(rootDir, 'GUI');
    if isfolder(guiPath)
        addpath(guiPath);
        fprintf('[✓] Added GUI components: GUI/\n');
    end

    % =====================================================
    % SIMULATOR FOLDER (Core simulation)
    % =====================================================
    simPath = fullfile(rootDir, 'Simulator');
    if isfolder(simPath)
        addpath(simPath);
        fprintf('[✓] Added simulator: Simulator/\n');
    end

    % =====================================================
    % ROOT (Documentation & main entry points)
    % =====================================================
    addpath(rootDir);
    fprintf('[✓] Added root directory for documentation\n');

    fprintf('\n[SETUP] Path initialization complete!\n');
    fprintf('[SETUP] Ready to run: WSN_Main()\n\n');

    % =====================================================
    % VALIDATION: Check key files
    % =====================================================
    fprintf('[VALIDATION] Checking key files...\n');

    keyFiles = {
        'WSN_Main.m', 'WSN_Config.m', 'WSN_Sensor.m', 'WSN_ClusterHead.m', ...
        'WSN_Gateway.m', 'WSN_Sink.m', 'WSN_GUI.m'
    };

    allFound = true;
    for i = 1:numel(keyFiles)
        filename = keyFiles{i};
        if exist(filename, 'file') == 2
            fprintf('[✓] Found: %s\n', filename);
        else
            fprintf('[✗] MISSING: %s\n', filename);
            allFound = false;
        end
    end

    fprintf('\n');
    if allFound
        fprintf('[SUCCESS] All key files found. System ready.\n\n');
    else
        fprintf('[WARNING] Some files missing. Check folder organization.\n\n');
    end
end
