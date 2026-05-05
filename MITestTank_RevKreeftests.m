%%  _*MIT Wave Paddle Control Code_ ( and Documentation) Rev K*
% _*This Livescript Code runs the MIT Towing Tank - PLEASE DO NOT EDIT OR ALTER in Any Way!*_
% If you would like to reuse the code for your experimental 
% 
% work, please make a copy of it, name it something else and store it in a seperate 
% folder.
% 
% Please check tank rails and gantry are clear, then run code section by section 
% to make sure all hardware is operational before starting a set of experiments.
% 
% D. Barrett 4/4/2024  Rev G  (rev G adds low pass filtering to collected experimental 
% data)
% 
% D. Barrett 4/11/2024 Rev H adds calculation of Coefficient of Drag
% 
% Dave and Anjali 4/17 Rev I created tow large stand alone plots, one for for 
% Coef of Drag one for Force
% 
% J. Keribin 7/18 Rev J adapted the code to the specificities of the MIT Towing 
% Tank
% 
% A. Garcia-Langley and M. Valencia 11/6 Rev K bypassed the filters to record 
% and display wave data in the MIT Towing Tank (Additions for 2.20 lab as well)
%% Part 1: Set up NI-DAQ data collection system
% NI DAQ 6218 pinout shown below:
% 
% 
% 
% 

clear
clc
disp("Setting up experimental code")

% Check if DAQ devices are connected
d = daqlist;
if isempty(d)
    error('No DAQ devices found. Please check your connection.');
end

% Display information about the first device
disp(d(1, :));               % Confi rm the connected DAQ device
disp(d{1, "DeviceInfo"});    % Read properties from the USB DAQ driver
% Create a Data Acquisition Object for the NI USB DAQ device
dq = daq("ni");
disp("NI USB DAQ online and ok!")

% Set the sampling rate for data acquisition
dq.Rate = 100;

% Add input channels for wave height data collection
for i = 0:7
    addinput(dq, "Dev1", sprintf("ai%d", i), "Voltage");
end

% Read one second of data to ensure everything is working
data = read(dq, seconds(1));
disp("NI USB DAQ can read data!")

% Add output channel for signal generation
addoutput(dq, "Dev1", "ao0", "Voltage");

% Import wavemaker transfer function

% Load sounds
trainWhistle = load('train.mat').y;
stopSound = load('splat.mat').y;
endSound = load('gong.mat').y;
%% Part 2: Calibration of the wave probes
% This section manages probe calibration by checking for existing calibration 
% data and prompting the user to update it if necessary. It collects new measurements 
% at specified water heights, performs linear regression to determine new calibration 
% gains, and updates/save both the gains and calibration results. Existing data 
% files are backed up before saving new results.

% Define file for saving gains and backup
gainsFile = 'probe_gains.mat';
backupGainsFile = 'probe_gains_backup.mat';

% Load existing gains if file exists
if exist(gainsFile, 'file')
    load(gainsFile, 'gains');
    fileInfo = dir(gainsFile);
    lastModified = fileInfo.datenum;
    lastGainsExist = true;
else
    gains = ones(1, 8); % Assuming 8 channels (H1 to H8)
    lastGainsExist = false;
end

% Display existing gains and prompt for recalibration
if lastGainsExist
    gainsStr = sprintf('%.4f ', gains);
    lastModifiedStr = datestr(lastModified);
    prompt = sprintf(['Last calibration gains:\n%s\nLast calibration date: %s\n' ...
                      'Do you want to recalibrate the wave probes? (y/n): '], ...
                     gainsStr, lastModifiedStr);
    calibrate = input(prompt, 's');
else
    calibrate = input('No previous calibration found. Do you want to calibrate the wave probes? (y/n): ', 's');
end

% If recalibration is needed
if strcmpi(calibrate, 'y')
    % Prompt user to select wave probes for calibration
    selectedProbes = input('Enter the wave probes to calibrate (e.g., [1 5] for H1 and H5 or i:j for Hi to Hj): ');

    if ~isnumeric(selectedProbes) || any(selectedProbes < 1 | selectedProbes > 8)
        error('Invalid probe numbers. Please enter valid probe indices (1 to 8).');
    end

    % Initialize variables for calibration
    heights = [];
    meanMeasurements = [];

    % Calibration loop
    try
        while true
            % Prompt user to enter water height or finish calibration
            height = input('Enter the water height in cm for calibration (or type "done" to finish): ', 's');
            if strcmpi(height, 'done')
                break;
            end
            height = str2double(height);
            if isnan(height)
                disp('Invalid height. Please enter a numeric value.');
                continue;
            end

            nSecondsOfCalibration = input('Enter the number of seconds for calibration measurement: ');
            if isempty(nSecondsOfCalibration) || nSecondsOfCalibration <= 0
                disp('Invalid number of seconds. Please enter a positive number.');
                continue;
            end

            prompt = sprintf('Set the water height to %.2f cm and press Enter to start measurements...', height);
            input(prompt, 's'); % Wait for user to press Enter

            % Create dummy output data
            outputData = zeros(dq.Rate * nSecondsOfCalibration, 1);

            % Read data while sending dummy output
            [data, ~] = readwrite(dq, outputData);

            % Compute mean measurement for each probe
            meanMeasurement = mean(data.Variables, 1); % Average over time

            % Store calibration data
            heights = [heights, height];
            meanMeasurements = [meanMeasurements; meanMeasurement(selectedProbes)];
        end
    catch ME
        disp(['An error occurred: ', ME.message]);
    end

    % Perform regression for each selected probe and update gains
    while length(heights) < 2
        disp('Not enough calibration points to perform regression. At least 2 points are required.');
        disp('Please enter more calibration data.');

        % Continue calibration to gather more data
        while true
            height = input('Enter the water height for calibration (or type "done" to finish): ', 's');
            if strcmpi(height, 'done')
                break;
            end
            height = str2double(height);
            if isnan(height)
                disp('Invalid height. Please enter a numeric value.');
                continue;
            end

            nSecondsOfCalibration = input('Enter the number of seconds for calibration measurement: ');
            if isempty(nSecondsOfCalibration) || nSecondsOfCalibration <= 0
                disp('Invalid number of seconds. Please enter a positive number.');
                continue;
            end

            prompt = sprintf('Set the water height to %.2f meters and press Enter to start measurements...', height);
            input(prompt, 's'); % Wait for user to press Enter

            % Create dummy output data
            outputData = zeros(dq.Rate * nSecondsOfCalibration, 1);

            % Read data while sending dummy output
            [data, ~] = readwrite(dq, outputData);

            % Compute mean measurement for each probe
            meanMeasurement = mean(data.Variables, 1); % Average over time

            % Store calibration data
            heights = [heights, height];
            meanMeasurements = [meanMeasurements; meanMeasurement(selectedProbes)];
        end
    end

    % Perform regression for each selected probe and update gains if there are at least 2 measurements
    if length(heights) >= 2
        calib = figure('Visible', 'on'); % Ensure the figure is visible
        hold on;

        for k = 1:numel(selectedProbes)
            probeIndex = selectedProbes(k);
            p = polyfit(meanMeasurements(:, k), heights, 1);
            gains(probeIndex) = p(1); % Slope of the linear fit

            % Plot measurement points and regression line
            scatter(meanMeasurements(:, k), heights, 'DisplayName', sprintf('Probe %d Data', probeIndex));
            plot(meanMeasurements(:, k), polyval(p, meanMeasurements(:, k)), 'DisplayName', sprintf('Probe %d Fit', probeIndex));
        end

        title('Calibration Measurements and Linear Fits');
        xlabel('Mean Measurement (V)');
        ylabel('Water Height (meters)');
        legend;
        grid on;
        hold off;

        % Save the figure
        saveas(calib, 'CalibrationResults.png');

        % Backup existing gains file if it exists
        if exist(gainsFile, 'file')
            movefile(gainsFile, backupGainsFile);
        end
    
        % Display and save the updated gains
        fprintf('Calibration complete. Updated probe gains:\n');
        disp(gains);
        save(gainsFile, 'gains');
    end
end
%% Part 3: Signal Generation and Processing
% This section sets up and runs a loop for multiple data collection experiments. 
% It initializes figures, gathers user input for experiment parameters, and generates 
% a signal based on the selected type (Bretschneider, Sinusoidal, or Custom Spectrum). 
% It applies a Hann window to smooth the edges of the signal, computes and plots 
% the Fourier transform and Power Spectral Density (PSD) for the specified signal 
% type, and saves the generated data and parameters to a file.

% Load the .mat that contains the wavemaker transfer function
load('wavemaker_model.mat');

% Prompt user to select wave probes for experiment
selectedProbes = input('Enter the wave probes to use for experiment (e.g. 3 for H3, [1 5] for H1 and H5 or i:j for Hi to Hj): ');

if ~isnumeric(selectedProbes) || any(selectedProbes < 1 | selectedProbes > 8)
    error('Invalid probe numbers. Please enter valind probe indices (1 to 8).');
end

doRunSwitch = 'y';  % loop cycle switch, loop stops on 'n'
while doRunSwitch == 'y'  % start of multiple external data collection runs loop
    clc
    % Initialize figure handles
    analog_ouput = figure('Visible', 'off');
    expected_wave_height = figure('Visible', 'off');
    spectrum = figure('Visible', 'off');
    wave_measure = figure('Visible', 'off');

    % Ask for all relevant parameters
    filePath = 'C:\Users\MIT_TOWTANK\Documents\MATLAB\Wave Data';
    testName = input('Enter name of experiment (aka file name):', 's');
    testName = strcat(datestr(now, 'yyyymmdd'), '_', testName);  % Concatenate strings with today's date
    experimentFolder = fullfile(filePath, testName);  % Define folder path
    mkdir(experimentFolder);  % Make new experimental data folder
    fullFilePath = fullfile(experimentFolder, testName);  % Build full file name

    % Time parameters
    nSecondsofData = input('Enter experiment duration in seconds:');  % Total time duration in seconds
    N = floor(nSecondsofData * dq.Rate);  % Number of samples
    dt = nSecondsofData / N;

    % Frequency parameters
    df = 1 / (N * dt);  % Frequency resolution in Hz
    dw = 2 * pi * df;   % Frequency resolution in rad/s

    % Generate time array
    t = linspace(0, nSecondsofData, N);

    % Ask user for signal type
    signalType = input('Enter signal type (1 for Bretschneider, 2 for Sinusoidal, 3 for Custom Spectrum, 4 for pulse Sinusoidal, 5 for Dual pulse): ');

    switch signalType
        case 1
            % Wave parameters
            Hs = input('Enter Significant Wave Height in cm:');  % Significant wave height in meters
            w_m = input('Enter Modal frequency in rad/s:');          % Modal frequency in rad/s

            % Compute the frequency limit for 99% of total signal energy
            w_lim = w_m / realpow(-4/5 * log(0.99), 1/4);
            flim = w_lim / (2 * pi);  % Corresponding frequency limit

            % Define the Power Spectral Density (PSD) function using the Bretschneider spectrum
            psd = @(w) (5 / 16 * w_m^4 * Hs^2 ./ (w.^5 + (w == 0)) .* exp(-5 / 4 * (w_m ./ (w + (w == 0))).^4)) .* (w ~= 0);

            % Define the integrand of the PSD for area calculation
            psd_integrand = @(w) (Hs / 4)^2 .* exp(-5 / 4 * (w_m ./ (w + (w == 0))).^4) .* (w ~= 0);

            % Calculate the PSD area
            psd_area = @(wi, dw) psd_integrand(wi + dw) - psd_integrand(wi);

            % Generate frequency array (only positive frequencies)
            fk = (0:(N/2-1)) / (N * dt);
            wk = 2 * pi * fk;

            % Filter frequency array based on flim
            fk_filtered = fk(fk <= flim);
            wk_filtered = 2 * pi * fk_filtered;

            % Generate random amplitudes based on Rayleigh distribution scaled by PSD
            Ak = raylrnd(sqrt(psd_area(wk_filtered, dw)));

            % Convert to wavemaker input voltage
            [mag, ~, ~] = bode(wavemaker_model, wk_filtered);
            mag = squeeze(mag);

            Ak_converted = Ak./ mag';

            % Generate random phases
            phi = 2 * pi * rand(1, length(fk_filtered));

            % Compute the random process realization
            U = sum(Ak_converted' .* cos(2 * pi * fk_filtered' * t + phi'), 1);
            X = sum(Ak' .* cos(2 * pi * fk_filtered' * t + phi'), 1);

            % Smoothly transition the first and last dq.Rate points using Hann window
            M = dq.Rate;
            hann_window = hann(2 * M)';  % Hann window of length 2M
        
            U(1:M) = U(1:M) .* hann_window(1:M);
            U(end-M+1:end) = U(end-M+1:end) .* hann_window(M+1:end);
        
            X(1:M) = X(1:M) .* hann_window(1:M);
            X(end-M+1:end) = X(end-M+1:end) .* hann_window(M+1:end);

        case 2
            % Sinusoidal parameters
            A = input('Enter amplitude of the sinusoidal signal in cm:');  % Amplitude of the sinusoidal signal
            f = input('Enter frequency of the sinusoidal signal in Hz:');  % Frequency of the sinusoidal signal


            % Convert to wavemaker input voltage
            [mag, ~, ~] = bode(wavemaker_model, 2 * pi * f);
            mag = squeeze(mag);

            A_converted = A / mag;

            % Compute the sinusoidal signal
            U = A_converted * sin(2 * pi * f * t);
            X = A * sin(2 * pi * f * t);

            % Smoothly transition the first and last dq.Rate points using Hann window
            M = dq.Rate;
            hann_window = hann(2 * M)';  % Hann window of length 2M
        
            U(1:M) = U(1:M) .* hann_window(1:M);
            U(end-M+1:end) = U(end-M+1:end) .* hann_window(M+1:end);
        
            X(1:M) = X(1:M) .* hann_window(1:M);
            X(end-M+1:end) = X(end-M+1:end) .* hann_window(M+1:end);

        case 3
            % Custom spectrum parameters
            custom_psd_file = input('Enter the file path for the custom spectrum data (MAT-file):', 's');
            custom_spectrum = load(custom_psd_file);

            % Assuming the custom spectrum data has frequency and amplitude
            fk = custom_spectrum.frequencies;
            Ak = custom_spectrum.amplitudes;

            wk = 2 * pi * fk;

            % Convert to wavemaker input voltage
            [mag, ~, ~] = bode(wavemaker_model, wk);
            mag = squeeze(mag);

            Ak_converted = Ak./ mag';

            % Generate random phases
            phi = 2 * pi * rand(1, length(fk));

            % Compute the random process realization
            U = sum(Ak_converted' .* cos(2 * pi * fk_filtered' * t + phi'), 1);
            X = sum(Ak' .* cos(2 * pi * fk_filtered' * t + phi'), 1);

            % Smoothly transition the first and last dq.Rate points using Hann window
            M = dq.Rate;
            hann_window = hann(2 * M)';  % Hann window of length 2M
        
            U(1:M) = U(1:M) .* hann_window(1:M);
            U(end-M+1:end) = U(end-M+1:end) .* hann_window(M+1:end);
        
            X(1:M) = X(1:M) .* hann_window(1:M);
            X(end-M+1:end) = X(end-M+1:end) .* hann_window(M+1:end);

        case 4
            % % Pulse sinusoidal parameters
            A = input('Enter amplitude of the sinusoidal signal in cm:');  % Amplitude of the sinusoidal signal
            f = input('Enter frequency of the sinusoidal signal in Hz:');  % Frequency of the sinusoidal signal
            numPulses = input('Enter the number of pulses to generate:');  % Number of pulses to generate

            if ~isnumeric(numPulses) || numPulses <= 0 || mod(numPulses, 1) ~= 0
                error('Number of pulses must be a positive integer.');
            end

            numPulses = numPulses + 1; % Account for ramp up
            
            % Calculate pulse duration
            T = 1 / f;  % Period of the sinusoidal wave
            pulseDuration = numPulses / f;  % Total duration of the pulses
            pulseSamples = round(pulseDuration * dq.Rate);  % Number of samples for the pulse
            
            % Generate the pulse wave
            tPulse = linspace(0, pulseDuration, pulseSamples);  % Time vector for the pulses
            sinusoidalPulse = A * sin(2 * pi * f * tPulse);  % Sinusoidal pulse signal

            % Hann tapper for pulse
            M = dq.Rate;
            hann_window = hann(2 * M)';

            sinusoidalPulse(1:M) = sinusoidalPulse(1:M) .* hann_window(1:M);
            sinusoidalPulse(end-M+1:end) = sinusoidalPulse(end-M+1:end) .* hann_window(M+1:end)
            
            % Zero-padding for the remaining signal duration
            zeroPadding = zeros(1, N - pulseSamples);
            X = [sinusoidalPulse, zeroPadding];  % Full signal (sinusoidal pulses + zeros)
            
            % Scale the signal using the wavemaker model
            [mag, ~, ~] = bode(wavemaker_model, 2 * pi * f);
            mag = squeeze(mag);
            A_converted = A / mag;
            
            % Scale the input voltage
            U = [A_converted * sin(2 * pi * f * tPulse), zeroPadding];

        case 5
            % Dual Pulse Sinusoidal Parameters
            % First sinusoidal pulse parameters
            A1 = input('Enter amplitude of the first sinusoidal signal in cm: ');  % Amplitude of the first sinusoidal signal
            f1 = input('Enter frequency of the first sinusoidal signal in Hz: ');  % Frequency of the first sinusoidal signal
            numPulses1 = input('Enter the number of pulses for the first signal: ');  % Number of pulses for the first signal
            
            if ~isnumeric(numPulses1) || numPulses1 <= 0 || mod(numPulses1, 1) ~= 0
                error('Number of pulses must be a positive integer.');
            end

            % Pause duration between pulses
            wavestopduration = input('Enter the time between the two pulses in seconds: ');  % Pause duration between pulses
            
            % Second sinusoidal pulse parameters
            A2 = input('Enter amplitude of the second sinusoidal signal in cm: ');  % Amplitude of the second sinusoidal signal
            f2 = input('Enter frequency of the second sinusoidal signal in Hz: ');  % Frequency of the second sinusoidal signal
            numPulses2 = input('Enter the number of pulses for the second signal: ');  % Number of pulses for the second signal
            
            if ~isnumeric(numPulses2) || numPulses2 <= 0 || mod(numPulses2, 1) ~= 0
                error('Number of pulses must be a positive integer.');
            end

            numPulses1 = numPulses1 + 1;
            numPulses2 = numPulses2 + 1;

            % Time calculations for the first pulse
            T1 = 1 / f1;  % Period of the first sinusoidal wave
            pulseDuration1 = numPulses1 / f1;  % Total duration of the first pulse
            pulseSamples1 = round(pulseDuration1 * dq.Rate);  % Number of samples for the first pulse
            tPulse1 = linspace(0, pulseDuration1, pulseSamples1);  % Time vector for the first pulse
            
            % Generate the first pulse
            sinusoidalPulse1 = A1 * sin(2 * pi * f1 * tPulse1);  % First sinusoidal pulse

            % Hann tapper for first pulse in beginning and end of pulse
            M = dq.Rate;
            hann_window = hann(2 * M)';

            sinusoidalPulse1(1:M) = sinusoidalPulse1(1:M) .* hann_window(1:M);
            sinusoidalPulse1(end-M+1:end) = sinusoidalPulse1(end-M+1:end) .* hann_window(M+1:end)
        
            % Time calculations for the pause
            pauseSamples = round(wavestopduration * dq.Rate);  % Number of samples for the pause
            pauseSignal = zeros(1, pauseSamples);  % Zero signal for the pause
        
            % Time calculations for the second pulse
            T2 = 1 / f2;  % Period of the second sinusoidal wave
            pulseDuration2 = numPulses2 / f2;  % Total duration of the second pulse
            pulseSamples2 = round(pulseDuration2 * dq.Rate);  % Number of samples for the second pulse
            tPulse2 = linspace(0, pulseDuration2, pulseSamples2);  % Time vector for the second pulse
            
            % Generate the second pulse
            sinusoidalPulse2 = A2 * sin(2 * pi * f2 * tPulse2);  % Second sinusoidal pulse

            % Hann tapper for second pulse in beginning and end of pulse
            sinusoidalPulse2(1:M) = sinusoidalPulse2(1:M) .* hann_window(1:M);
            sinusoidalPulse2(end-M+1:end) = sinusoidalPulse2(end-M+1:end) .* hann_window(M+1:end)
        
            % Combine the pulses and the pause
            X = [sinusoidalPulse1, pauseSignal, sinusoidalPulse2];  % Full dual-pulse signal
        
            % Zero-pad the remaining duration of the signal
            totalSamples = length(t);  % Total number of samples for the experiment
            zeroPadding = zeros(1, totalSamples - length(X));  % Zero padding to match the total signal duration
            X = [X, zeroPadding];  % Final signal including zero-padding
        
            % Scale the signal for the wavemaker input using its transfer function
            [mag1, ~, ~] = bode(wavemaker_model, 2 * pi * f1);  % Scaling for the first signal
            mag1 = squeeze(mag1);
            A1_converted = A1 / mag1;
        
            [mag2, ~, ~] = bode(wavemaker_model, 2 * pi * f2);  % Scaling for the second signal
            mag2 = squeeze(mag2);
            A2_converted = A2 / mag2;
        
            % Generate scaled input voltage signal
            U1 = A1_converted * sin(2 * pi * f1 * tPulse1);  % Scaled first pulse
            U2 = A2_converted * sin(2 * pi * f2 * tPulse2);  % Scaled second pulse
            U = [U1, pauseSignal, U2, zeroPadding];  % Final input voltage signal

        otherwise
            error('Invalid signal type selected');
    end

    % Moved hann filter to be handled within case since pulses now make it
    % case dependent

    % Compute the Fourier transform of the random process for Bretschneider and Custom Spectrum
    if signalType == 1 || signalType == 3
        X_ft = fft(X);
        S_X = dt / N / pi * abs(X_ft(1:length(fk_filtered))).^2;  % Take the positive frequencies, one-sided spectrum

        % Plot the random process U(t), X(t) the corresponding expected wave height and the PSDs
        set(analog_ouput, 'Visible', 'on');  % Ensure the figure is visible
        stairs(t, U);
        title('Random Process time series - input voltage');
        xlabel('Time (s)');
        ylabel('U(t) (V)');
        grid on;
        drawnow;

        set(expected_wave_height, 'Visible', 'on');  % Ensure the figure is visible
        plot(t, X);
        title('Random Process time series - expected wave maker excursion');
        xlabel('Time (s)');
        ylabel('X(t) (cm)');
        grid on;
        drawnow;

        set(spectrum, 'Visible', 'on');  % Ensure the figure is visible
        hold on;
        if signalType == 1
            original_psd = psd(wk);
            plot(fk, original_psd, 'r', 'DisplayName', 'Original PSD');
        end
        bar(fk_filtered, S_X, 1, 'k', 'DisplayName', 'Estimated PSD');
        hold off;
        title('Spectral comparison');
        xlabel('Frequency (Hz)');
        ylabel('PSD (cm^2/Hz)');
        xlim([0, 2 * flim]);
        legend;
        grid on;
        drawnow;

        % Save the generated data
        save(strcat(fullFilePath, '_input.mat'), 'U', 'X', 't', 'fk', 'Ak', 'phi');  % Save signal data and parameters
    elseif signalType == 2
        % Plot the sinusoidal process
        set(analog_ouput, 'Visible', 'on');  % Ensure the figure is visible
        stairs(t, U);
        title('Sinusoidal Signal time series - expected wave maker excursion');
        xlabel('Time (s)');
        ylabel('U(t) (V)');
        grid on;
        drawnow;

        set(expected_wave_height, 'Visible', 'on');  % Ensure the figure is visible
        plot(t, X);
        title('Sinusoidal Signal time series - input voltage');
        xlabel('Time (s)');
        ylabel('X(t) (cm)');
        grid on;
        drawnow;
        % Save the generated data
        save(strcat(fullFilePath, '_input.mat'), 'U', 'X', 't', 'f', 'A');  % Save signal data and parameters
    elseif signalType == 4
        % Save the generated data
        save(strcat(fullFilePath, '_pulse_input.mat'), 'U', 'X', 't', 'f', 'A', 'numPulses');
        
        % Plot the generated pulse wave
        figure;
        stairs(t, U);
        title('Pulse Sinusoidal Signal - Input Voltage');
        xlabel('Time (s)');
        ylabel('U(t) (V)');
        grid on;
        
        figure;
        plot(t, X);
        title('Pulse Sinusoidal Signal - Wavemaker Excursion');
        xlabel('Time (s)');
        ylabel('X(t) (cm)');
        grid on;

    elseif signalType == 5
        % Save the generated data
        save(strcat(fullFilePath, '_dual_pulse_input.mat'), 'U', 'X', 't', 'f1', 'f2', 'A1', 'A2', 'numPulses1', 'numPulses2', 'wavestopduration');
    
        % Plot the generated dual pulse signal
        figure;
        stairs(t, U);
        title('Dual Pulse Sinusoidal Signal - Input Voltage');
        xlabel('Time (s)');
        ylabel('U(t) (V)');
        grid on;
    
        figure;
        plot(t, X);
        title('Dual Pulse Sinusoidal Signal - Wavemaker Excursion');
        xlabel('Time (s)');
        ylabel('X(t) (cm)');
        grid on;
    end

%% Part 4: Experimental Data Collection
% This section initializes a time vector based on the sample rate and duration, 
% then creates an empty table for storing wave height data. After starting data 
% acquisition, the collected data is stored in the table under columns for each 
% channel (H1 to H8).

    % Create sample time vector
    increment = 1 / dq.Rate;
    nTime = (0:increment:(nSecondsofData-increment))';  % create sample time vector

    % Prebuild experimental data table
    WaveHeightsTable = table(nTime);

    % Initialize the emergency stop flag
    flag = Flag();
    
    prompt = sprintf('press Enter to start experiment...');
    input(prompt, 's'); % Wait for user to press Enter
    sound(trainWhistle);
    
    % Start data acquisition and analog output
    HData = readandwrite(dq, U, nSecondsofData, flag);  % read wave height data from USB DAQ
    
    % Convert acquired data to wave heights
    waveHeightData = HData.Variables .* gains;

    % Center wave heights at zero
    waveHeightData = waveHeightData - mean(waveHeightData, 1);
    % % update waveHeightData table to have these values
    % waveHeightData = array2table(waveHeightDataCentered, 'VariableNames', HData.Properties.VariableNames);
    
    % Store acquired data in the table
    waveHeightTable = array2table(waveHeightData, 'VariableNames', ...
                                  {'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7', 'H8'});
    
    % Concatenate time vector and wave height data into one table
    WaveHeightsTable = [WaveHeightsTable, waveHeightTable];
%% Part 5: Data Filtering and Analysis
% Designs a lowpass filter, applies it to wave height data, and plots the filtered 
% data.

    % Design a lowpass filter
    d1 = designfilt('lowpassiir', 'FilterOrder', 12, 'StopbandFrequency', 3, 'StopbandAttenuation', 60, 'SampleRate', dq.Rate, 'DesignMethod', 'cheby2');

    % Initialize table for filtered data
    filteredWaveHeightsTable = table(nTime);

    % Apply zero-phase filtering to height data
    filteredWaveHeightsTable.H1 = filtfilt(d1, WaveHeightsTable.H1);
    filteredWaveHeightsTable.H2 = filtfilt(d1, WaveHeightsTable.H2);
    filteredWaveHeightsTable.H3 = filtfilt(d1, WaveHeightsTable.H3);
    filteredWaveHeightsTable.H4 = filtfilt(d1, WaveHeightsTable.H4);
    filteredWaveHeightsTable.H5 = filtfilt(d1, WaveHeightsTable.H5);
    filteredWaveHeightsTable.H6 = filtfilt(d1, WaveHeightsTable.H6);
    filteredWaveHeightsTable.H7 = filtfilt(d1, WaveHeightsTable.H7);
    filteredWaveHeightsTable.H8 = filtfilt(d1, WaveHeightsTable.H8);

    % Plot filtered data
    set(wave_measure, 'Visible', 'on');  % Ensure the figure is visible

    % Convert table to matrix for plotting
    filteredMatrix = table2array(filteredWaveHeightsTable(:, selectedProbes+1)); % Convert table columns to matrix

    if signalType == 4 || signalType == 5  % Check if the signal type is pulse sinusoidal
        % Overlay expected wave excursion on filtered wave heights
        hold on; % Allow multiple plots on the same figure
        
        % Plot the filtered wave heights for selected probes
        plot(filteredWaveHeightsTable.nTime, filteredMatrix, 'DisplayName', 'Filtered Wave Heights');
    
        % Plot the expected wave excursion
        plot(t, X, 'LineWidth', 2, 'DisplayName', 'Expected Wave Excursion'); % Non-Dashed line for clarity
        
        % Set figure properties
        title(['Overlay of Expected Wave Excursion and Filtered Wave Heights - ', testName]);
        xlabel('Time (s)');
        ylabel('Wave Height (cm)');
        legend('show'); % Show legend with dynamically generated labels
        grid on;
        grid minor;
        hold off; % Release the hold
        drawnow;
    else
        plot(filteredWaveHeightsTable.nTime, filteredMatrix);
        ylabel("Wave Height (cm)");
        xlabel("Time (s)");
        % Dynamically generate legend labels
        legendLabels = arrayfun(@(x) sprintf('H%d', x), selectedProbes, 'UniformOutput', false);
        legend(legendLabels);
        
        title(testName);
        grid on;
        grid minor;
        drawnow;
    end
%% Part 6: Data Saving and Logging
% Saves the filtered data and figure, then asks to run another experiment.

    % Save the table
    save(strcat(fullFilePath, '_filteredOutput.mat'), 'filteredWaveHeightsTable');  % Save the filtered data
    save(strcat(fullFilePath, '_rawOutput.mat'), 'WaveHeightsTable');

    % Save the table as a csv file as well for 2.20 class
    % Extract the relevant data: nTime and selected probes
    filteredDataToSave = filteredWaveHeightsTable(:, ['nTime', filteredWaveHeightsTable.Properties.VariableNames(selectedProbes+1)]);
    
%     % Define the file name for the CSV
%     csvFilePath = strcat(fullFilePath, '_filteredOutput.csv');
%     
%     % Write the selected data to the CSV file
%     writetable(filteredDataToSave, csvFilePath);
%     
%     % Confirm the save
%     disp(['Filtered data saved to CSV file: ', csvFilePath]);

    % Save the figure
    saveas(wave_measure, strcat(fullFilePath, '_filteredOutput.fig'));  % Save figure as .fig

    sound(stopSound);
    % Ask if the user wants to run another experiment
    doRunSwitch = input('Do you want to run another experiment? (y/n): ', 's');
    
end  % End of collect multiple experimental data run loop
pause(0.5);
sound(endSound);
%% 
% *Function definitions*

function data = readandwrite(dq, X, nSecondsofData, flag)
    % Create the onCleanup object
    cleanupObj = onCleanup(@() myCleanupFun(dq, flag));
    
    % Preload the analog output
    preload(dq, X');
    start(dq, "repeatoutput");
    % Read wave height data from USB DAQ
    data = read(dq, seconds(nSecondsofData));  % read height data from USB DAQ
    stop(dq);
    
    % Set the flag to true to indicate normal completion
    flag.didFinish = true;
end
%% 
% 

function myCleanupFun(dq, flag)
    % Stop the DAQ session
    stop(dq);  % Use the appropriate method to stop the DAQ session
    
    % Additional cleanup instructions
    if flag.didFinish
        disp('DAQ session stopped.');
    else
        disp('DAQ session stopped abruptly.');
    end
end