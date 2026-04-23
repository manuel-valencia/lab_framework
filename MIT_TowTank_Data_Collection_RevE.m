%% _*1.70.11MIT Tow Tank Control Code_ (and Documentation) Rev E  1-22-26*
% _*This Livescript Code runs the Parson's Hydrodynamics Towing Tank Data Collection system*_ 
%% _*PLEASE DO NOT EDIT OR ALTER this code in Any Way!*_
% 
% 
% _*To Run code, click on "Live Editor Tab" and then click on Green "Run" arrow*_
% 
% _*Code will ask you to enter experiemental file names and body parameters 
% and*_ 
% 
% _*generate a Coefficient of Drag Plot and a Tow Force Plot*_
% *Data Collection Code and Experimental Hardware documentation contained within each code section*
% 
% 
% Note: If you would like to reuse the code for your experimental work, please 
% make a copy of it, name it something else 
% 
% and store it in a seperate folder.
% 
% To operate, please check tank rails and cross tank gantry are clear, then 
% run code section by section to make sure all 
% 
% hardware is operational before starting a set of experiments.
% 
% Please note: Before running this code for the first time, you must add the 
% National Instruments (NI) drivers to your laptop, 
% 
% to support communication with the NI USB-Daq connected tot the sensors, via 
% the following sequnce of steps:
% 
% 
% 
% Use this Hardware support package:
% 
% 
% 
% Takes a while to do all the downloading, accepting liscenses and lots of clicking 
% to get this fully set up!
% 
% D. Barrett 11/07/2024
% 
% 
%% Part 1: Set up NI-DAQ data collection system
% This code reads the 6 strain guages inside the ATI Gamma IP68 6-axis load 
% cell, subtracts the towed body static loads (bias's) from them and then de-cross-couples 
% the 6 stain guage signals into the three forces and three moments on the test 
% fixture (+x is down tank, +y facing away from bridge, +z staight down, load 
% cell mounted upside down on tow gantry).  
% 
% Details: This code reads 6 analog channels on the NI DAQ USB6218 attached 
% to the 6-axis ATI force sensor mounted on the Sea Grant Tow Tank carriage. 
% 
% NI DAQ 6218 pinout shown below:
% 
% 
% 
% The 6 axis load cell the NI-DAQ is reading is an ATI FT40787 Gamma IP68. Its 
% load ranges are given below. MIT has the US-7.5-25 variant. *PLEASE be careful 
% to not overload it!*
% 
% 
% 
% As it is mounted upside down on the tow carriage, *+FX is left down the tank, 
% +FY is pointing away from bridge and +Fz is pointed staight down into water.*
% 
% Sensor calibration values show in table below:
% 
% 
% 
% _*Warning: ATI Gamma IP68 6-axis load celll is mechanically cross-coupled 
% internally (pulling on X causes readings on many channels) and must be decoupled 
% via a calibration matrix.*_
% 
% _See ATI Document #9620-05-DAQ-25 for calibration details and ATI Document_ 
% #9620-05-DAQ-25 for technical specifiactions of attached F/T Sensor DAQ drive 
% box
% 
% The load cell is currently connected as shown in the table below *(note, USB-DAQ 
% input wires are currently labeled incorectly as FX, FY, FZ, MX, MY MZ*). 
% 
% Actual correct wiring shown below (also note, strain guage signals come on 
% differentialy wired pairs. It is critical to not mix them up!)
% 
% Old labels are shown in (parenthesis) but are not actually FX, FY, etc.
% 
% 
% 
% _*USB A0+ = SG0 (FX)+ Brown                         USBA1+ = SG1(FY)+ Yellow                        
% USBA2+ = SG2(FZ)+  Green*_
% 
% _*USB A0- = SG0(FX)- Brown/White                 USBA1- = SG1(FY)- Yellow/White                
% USBA2- =  SG2(FZ) - Green/White*_
% 
% 
% 
% _*USBA3+ = SG3(MX)+ Blue                            USBA4+ = SG4(MY)+ Purple                        
% USBA5+ = SG5(MZ)+ Grey*_
% 
% _*USBA3- = SG3(MX-) Blue/White                    USBA4- =  SG4(MY)- Purple/White              
% USBA5- = SG5(MZ)- Grey/White*_
% 
% _*USBAIGND=Black*_
% 
% 
% 
% _Note: that  (USBA7+ = Synch Trigger to PMAC Red    A7- = Synch Ground Ground/Black) 
% are used for data collection synchronization and not a force measurement_  
% 
% 
% 
% *The Parsons Tow Sled uses Go Bilda laser distance sensors to measure heave, 
% pitch and roll of floating ship hull:*
% 
% 
% 
% The Laser Distance Sensor helps your robot to *know the approximate distance 
% between itself and an object*. It operates by firing a laser, then measuring 
% the time it takes for the laser light to be reflected off the object and back 
% to the sensor. This allows it to sense the distance at ranges of up to 1 meter—depending 
% on the reflectivity of the object’s surface.
% 
% The Laser Distance Sensor can output an analog or a digital signal, according 
% to the mode you select:
% 
% Analog - Dynamic Range Mode
% 
% When the Sensor is set to Analog Mode by rotating the potentiometer clockwise 
% to its endpoint using a small flat-head screw driver, the output becomes a “dynamic 
% range” voltage that *changes proportionally* according to the distance between 
% the sensor and the object. As the object gets closer, the Analog Mode signal 
% will get lower.
% 
% In this mode, the LED will shine blue, and it will dim as the object becomes 
% closer. Conversely, it will brighten as the object becomes further away. 0 volts 
% close-3.28 volts far away.
% 
% 
% 
% 
% 
% 
% 
% *Experimentally modified original MITT test code to document and debug Dave 
% and Drew 12-13-23 Rev E.* 
% 
% *Edited by Anjali to allow for saving of data 2-2-2024 Rev F.*
% 
% *Edited by Anjali to add Sync Pulse processing 2-26-2024 Rev G.*
% 
% *Forked off by Barrett from main tank control code 3-7-2024 Rev A*
% 
% *Forked off by Barrett to build Parson's 48-015 data collection system Rev 
% A 11-7-24*
% 
% *Modified by Barrett to record analog Pitch Roll and Heave sensors 1-20-26*
%% *PART 2: Experimental set up code that runs once starts here*
% Clear MATLAB workspace and command window before each run

clear
clc
disp("Setting up experimental code")
load train;                  % load train starting sound to alert user tow crrrage will move (options; chirp gong handel laughter splat train)
trainWhistle = y;            % store train whistle sound in a user friendly alphanumeric
load splat;                  % load chirp ending sound
stopSound = y;               % store chirp sound in an alphanumeric
load gong.mat;               % load program ending sound
endSound = y;                % store gong sound in an alphanumeric
%% 
% Create a data aquisition object to interact with the NI USB Daq

d = daqlist;          % poll system to obtain DeviceID for attached DAQs. 1st one is simulated, second one is on tow sled
%d(2, :)              % output print to confirm Tow Tank NI DAQ USB-6218 is connected via USB
d(1, :)               % debugging code real daq is 2 output print to confirm Sea Grant Tank NI DAQ USB-6218 is connected via USB
d{1, "DeviceInfo"}     % read USB DAQ properties from USB DAQ driver. 
% d{1, "DeviceInfo"}     % read USB DAQ properties from USB DAQ driver. 
dq = daq("ni") ;         % create a Data Aquisition Object to connect to the NI USB DAQ device
disp("NI USB DAQ online and ok!")
% dq.Rate = 10;          % set scan rate to 10 scans per second
% dq.Rate = 25;            % set scan rate to 25 scans per second -- changed by Anjali 1/26/2024
dq.Rate = 50;               % changed up to 50 scans per second ---Barrett 1-22-26
%% 
% Create 7 channel objects to contain the 6 experimental DAQ channels and 1 
% Sync Pulse DAQ channel (changed by Anjali 2/26/2024)

% STG0 = addinput(dq,"Towing_Tank_Load_Cell", "ai0","Voltage");         % Gamma STO
STG0 = addinput(dq,d.DeviceID, "ai0","Voltage");         % Gamma STO   replaced "towing Tank load cell" with device ID  Barrett 11-11-24
STG1 = addinput(dq,d.DeviceID, "ai1","Voltage");         % Gamma ST1
STG2 = addinput(dq,d.DeviceID, "ai2","Voltage");         % Gamma ST2
STG3 = addinput(dq,d.DeviceID, "ai3","Voltage");         % Gamma ST3
STG4 = addinput(dq,d.DeviceID, "ai4","Voltage");         % Gamma ST4
STG5 = addinput(dq,d.DeviceID, "ai5","Voltage");         % Gamma St5
SyncPulse = addinput(dq,d.DeviceID, "ai7","Voltage");    % Test Sync Pulse

STG17 = addinput(dq,d.DeviceID, "ai17","Voltage");        % Go Bilda Distance Heave Sensor
STG18 = addinput(dq,d.DeviceID, "ai18","Voltage");        % Go Bilda Distance Pitch Sensor
STG19 = addinput(dq,d.DeviceID, "ai19","Voltage");        % Go Bilda Distance Roll Sensor

%% 
% Read the 10 experimental channels for 1-second to check all wires and data 
% objects are correctly set 

data = read(dq, seconds(1))                 % read one second of data
disp("NI USB DAQ can read data!")
%% Part 3: The following code converts the cross-coupled strain voltages into decoupled Fx,Fy, Fz and Mx, My, Mz 
% (text and diagram descibe the de-cross-coupling process)
% 
% Calculations must be performed to derive the loads sensed at the transducer. 
% The transducer reports the loads as composite values that require convrsion 
% to values corresponding to the six Cartesian axes. The following figure shows 
% the calculation required to convert the 6 strain guage datas into force and 
% torque data.
% 
% 
% 
% 
%% 
% First measure the volatge bias vector (bias0, bias1....bias5) with experimental 
% apparatus mounted to generate true bias

% measure test setup biases with tow body attached

biasData = read(dq, seconds(1)) ;                % read one second of data
disp("Test body load bias measured")
biasN = mean(table2array(biasData));       %calculate the mean test boady loaded bias voltage on each strain guage 
bias=biasN' ;                              % transpose vector to make it vertical to enable subtracting bias from live strain data
%% 
% Next enter the ATI Runtime Matrix (note: this matrix is hardware tied to the 
% specific sensor mounted on the tow gantry)

% Note: can only run one calibration matrix at a time and it must match
% ATI sensor in use.  Dave B 11-11-24

% Calibration Matrix for FT40787  7.5 lb ATI-9105-NET-Gamma-IP68
%RunTimeMatrix = [0.00072 -0.00858 0.01759 -1.92756 -0.01076 1.95589; ...  
%                 0.01917 2.24870 0.00284 -1.11488 0.01154 -1.12246; ...
%                 3.33531 0.04180 3.39848 0.00232 3.44703 -0.02105; ...
%                 0.04318 2.02883 -3.86301 -0.97150 3.90323 -1.05047; ...
%                 4.35979 0.02948 -2.22152 1.75643 -2.23271 -1.73908; ...
%                 -0.02783 -2.44478 0.02702 -2.41975 0.01024 -2.44056];

% Calibration Matrix for Paeson Tank FT40786  15lb ATI-9105-NET-Gamma-IP68
RunTimeMatrix = [-0.00751  -0.01075   0.01007  -1.88444  -0.01816   1.91358; ...  
                  0.01636   2.27292   0.00229  -1.09130   0.01014  -1.09647; ...
                 3.33501   0.04129   3.40147  -0.00003   3.44372  -0.01632; ...
                 0.03934   2.05079  -3.85455  -0.96095   3.90735  -1.02076; ... 
                 4.35119   0.02231  -2.23195   1.72541  -2.25515  -1.70294; ...
                -0.02308  -2.43778   0.01657  -2.37319   0.01761  -2.40509];
%% 
% Calibrate Heave, Pitch and Roll here

% Enter experimentally measured vlaues
cHeave = [2.5 5.0 7.5];
cHeaveVoltage= [0.639 0.586 0.521];

% Perform Linear interpolation
%Heave_interp = interp1(cHeave, cHeaveVoltage, 7.5, 'spline');
plot(cHeave, cHeaveVoltage)
title('Heave Calibration Plot')
xlabel('Heave in mm')
ylabel('Heave Voltage Measured')
legend('Heave diplacment vs measured Volts')

cPitch = [-6.00 -0.15 6.05 ];
cPitchVoltage= [0.56 0.51 0.472 ];

% Perform Linear interpolation
Pitch_interp = interp1(cPitch, cPitchVoltage, 7.5, 'spline');
plot(cPitch, cPitchVoltage)
title('Pitch Calibration Plot')
xlabel('Pitch Displacment drgrees')
ylabel('Pitch Volts Measured')
legend('Pitch didplacement vs Volts')

% Enter experimentally measured vlaues
cRoll = [-16.8 0.15 15.75];
cRollVoltage= [0.39 0.5 0.65];

% Perform Linear interpolation
Roll_interp = interp1(cRoll, cRollVoltage, 7.5, 'spline');
plot(cRoll, cRollVoltage)
title('Roll Calibration Plot')
xlabel('Roll Dispacment degrees')
ylabel('Volts Measured')
legend('Roll vs Volts')




%% Part 4: Experimental code that collects force data starts here
% Define hydrodynamic parameters for tow body

towBodyH=input('Enter Submerged Tow Body Verticle Height. in meters:')          % set tow body height
towBodyW=input('Enter Submerged Tow Body Horizontal Width. in meters:')           % set tow body width
towBodyLength=input('Enter Tow Body Length in meters:')      % set tow body length
bodyA=towBodyH*towBodyW                                      % calculate body projected area normal to the flow m^2
%% 
% 

rho=997;                                                       % Density of water in kg/m^3
nu= 0.95*1e-06;                                                % Kinematic Visocisity of water at 22.2 deg C                                                                 
%% 
% *Repeat Tow Test Loop Start Here*

doRunSwitch='y';                                 % loop cycle switch, loop stops on 'n'
while doRunSwitch == 'y'                         % start of multiple external data collection runs loop, will terminate with 'n' from user
clc
%disp(['Set parameters for Tow Test Run' newline])
%% 
% Define where to save collected data

%filePath = 'C:\Users\Tow Tank\Desktop\SeaGrantTankController MatlabCoupled V0\Anjali\Bretschneider Spectrum - Cases 1 through 6\Experimental Data';   %input('Enter path for folder in which to save the data:','s');
%filePath = 'C:\Users\Tow Tank\Desktop\SeaGrantTankController MatlabCoupled V0\StudentData';    % Dave added for Sea Grant tank on Mar 07 2024
%filePath = 'C:\Users\david\OneDrive\Desktop\Tow Tank'                                 % modify directory for machine running code
filePath = 'C:\Users\FishBots 5\Desktop\TowTank2026';                                 % modify directory for machine running code
testName = input('Enter filename of experiment (aka file name):','s');       % enter experimental file name
%testName = strcat(datestr(now,'yyyymmdd'),'_',testName);                 % concatenate strings horizontally with todays date
testName = strcat(datestr(now,'yyyymmdd'),testName);                     % concatenate strings horizontally with todays date
mkdir(filePath,testName);                                                % make new experimental data folder in the Tow Tank data storage folder
fullFilePath = fullfile(filePath,testName,testName);                     % build full file name from parts
%% 
% Define hydrodynamic parameters for tow body

towSpeed=input('Enter Tow Speed in meters/sec:');               % set tow speed
%% 
% Collect nSecondsOfData

nSecondsOfData=input('Enter experiment test time in seconds:');            % set length of data collection time here
sound(trainWhistle);                                                       % blow tow tank whistle
%disp("recording tow data")
%% 
% Build table data structure to place experimental data in

% adding sync pulse -- 02-26-2024 (Anjali)
% changing to work with current daq rate (set above)
increment = 1/dq.Rate;
nTime=(0:increment:(nSecondsOfData-increment))';          % create sample time vector fixed (1/(daq rate)) sec collection rate
sampleArrraySize=int32(nSecondsOfData*dq.Rate);           % convert floating point array size to an integer
Fx=zeros(sampleArrraySize,1);                             % preallocate memory for Force in x data
Fy=zeros(sampleArrraySize,1);
Fz=zeros(sampleArrraySize,1);
Mx=zeros(sampleArrraySize,1);
My=zeros(sampleArrraySize,1);
Mz=zeros(sampleArrraySize,1);
Sync=zeros(sampleArrraySize,1);
Heave=zeros(sampleArrraySize,1);
Pitch=zeros(sampleArrraySize,1);
Roll=zeros(sampleArrraySize,1);
ForceAndTorqueTable=table(nTime,Fx,Fy,Fz,Mx,My,Mz,Sync);         % prebuild experiemtal force data table
HeavePitchRollTable=table(nTime,Heave,Pitch,Roll);               % prebuild experiemtal data table
%% 
% Collect n seconds of experimental strain data

STGData = read(dq, seconds(nSecondsOfData));     % read n seconds of strain data from USB DAQ, store in table STGData
%% 
% NI DAQ drivers store experimental strain data in a MATLAB table structure. 
% Need to convert table to an array to process it

STGNarray=table2array(STGData);             % convert strain data table to an array to enable bias substraction and matrix multiplication
STG=STGNarray' ;                            % transpose strain array to reformat so each column is a single 6-guage measurment                                                                                                                                                        
%% 
% 
% 
% To process must subtract strain bias vector (bias0,bias1...bias5)' from strain 
% guage voltages (STG0,...STG5) see graph above
% 
% then multiply that outcome by the Runtime Matrix 

StrainGaugeMinusBias=zeros(6,1);            % preallocate array memory for strain subtraction operation
ForceAndTorqueData=zeros(6,1);              % preallocate array memory for force matrix multiplication

% process STG strain gauge experimetal data one column at a time. First subtract bias,
% then matrixmultiply result by RunTimeMatrix
% one data collection run will have nSecondsOfData X 10 STG individual
% strain vectors in it
    for dindex=(1:nSecondsOfData*dq.Rate)                        % dindex is the column of stain data being opearted on -- changed from 10 to 'dq.Rate', Anjali 2-27-2024
        StrainGaugeMinusBias=STG(1:6,dindex)-bias(1:6);          % subtract bias vetor from STG vector (only first 6 because 7 is sync, Anjali 2-27-2024)
        ForceAndTorqueData=RunTimeMatrix * StrainGaugeMinusBias; % multiply result by RuntimeMatrix
        Fxdindex=ForceAndTorqueData(1);                          % parse Force and Torque data matrix into individual channels Fx
        Fydindex=ForceAndTorqueData(2);                          % Fy                                                                                                                                                                                                                                                                                                                                                                          % Fy
        Fzdindex=ForceAndTorqueData(3);                          % Fz
        Mxdindex=ForceAndTorqueData(4);                          % Mx
        Mydindex=ForceAndTorqueData(5);                          % My
        Mzdindex=ForceAndTorqueData(6);                          % Mz
        Syncdindex=STG(7,dindex);                                % Sync Pulse (added 2-27-2024, Anjali)
        Heaveindex=STG(8,dindex);                                % Heave, Pich, Roll added 1-16-2026, Barrett)
        Pitchindex=STG(9,dindex);
        Rollindex=STG(10,dindex);
        %
        % Load force and torque data into pre-prepared experimental
        % ForceAndTorque Table
        ForceAndTorqueTable(dindex,:)={dindex*increment,Fxdindex,Fydindex, Fzdindex, Mxdindex, Mydindex, Mzdindex, Syncdindex};
        HeavePitchRollTable(dindex,:)={dindex*increment,Heaveindex,Pitchindex,Rollindex};                
    end

%disp("Process Tow Force data");
ForceAndTorqueTable;
 
%plot(ForceAndTorqueTable,"nTime",["Fx","Fy","Fz", "Sync"]);       % plot raw data in script, raw data plot supressed Dave 4-17 
%ylabel("Force(lbs)");
%legend('Fx','Fy','Fz','Sync');
%grid on;
%grid minor;

%f4=figure('Name',"RawHeavePitchRoll","Position",[750 150 800 800]);         %create stand alone figure
%f4=figure('Name',"HeavePitchRoll","Position",[250 150 800 800]);         %create stand alone figure
%set(f4,'Visible','on');

%CalibratedHeave = interp1(cHeave, cHeaveVoltage, HeavePitchRollTable.Heave, 'spline');    % create a calibrated heave data vector
CalibratedHeave = interp1(cHeaveVoltage,cHeave, HeavePitchRollTable.Heave, 'spline');    % create a calibrated heave data vector

%CalibratedPitch = interp1(cPitch, cPitchVoltage, HeavePitchRollTable.Pitch , 'spline');
CalibratedPitch = interp1(cPitchVoltage, cPitch, HeavePitchRollTable.Pitch , 'spline');

%CalibratedRoll = interp1(cRoll, cRollVoltage, HeavePitchRollTable.Roll ,'spline');
CalibratedRoll = interp1(cRollVoltage, cRoll, HeavePitchRollTable.Roll ,'spline');


CalibratedHeavePitchRollTable=table(nTime,CalibratedHeave,CalibratedPitch,CalibratedRoll);   % build calibrated experiemtal data table

%plot(Roll, RollVoltage)
%title('Roll Calibration Plot')
%xlabel('Roll')
%ylabel('Volts Measured')
%legend('Roll vs Volts')


%plot(CalibratedHeavePitchRollTable,"nTime",["CalibratedHeave","CalibratedPitch","CalibratedRoll"]);       % plot raw data in script 

%ylabel("Heave, Pitch, Roll ");
%legend('Heave','Pitch','Roll');
%title(strcat('Body Motion Test',testName))
%grid on;
%grid minor;

%d2 = designfilt("lowpassiir",FilterOrder=12, HalfPowerFrequency=0.9,DesignMethod="butter");
d2=designfilt('lowpassiir','FilterOrder',12,'StopbandFrequency',2,'StopbandAttenuation',60,'SampleRate',50,'DesignMethod','cheby2');
%d2=designfilt('lowpassiir','FilterOrder',12,'StopbandFrequency',2,'StopbandAttenuation',60,'SampleRate',25,'DesignMethod','cheby2');
%  fvtool(d1)
%d2=designfilt('lowpassiir','FilterOrder',12,'StopbandFrequency',3,'StopbandAttenuation',60,'SampleRate',25,'DesignMethod','cheby2');
%  fvtool(d1)
postFilterHeave = filtfilt(d2,CalibratedHeavePitchRollTable.CalibratedHeave);             % zerophase filter Heave Data
postFilterPitch = filtfilt(d2,CalibratedHeavePitchRollTable.CalibratedPitch);             % zerophase filter Pitch Data
postFilterRoll = filtfilt(d2,CalibratedHeavePitchRollTable.CalibratedRoll);               % zerophase filter Roll Data
filteredHeavePitchRollTable=table(nTime,postFilterHeave,postFilterPitch,postFilterRoll);  % build into a table

%plot(filteredHeavePitchRollTable,"nTime",["postFilterHeave","postFilterPitch","postFilterRoll"]);       % plot raw data in script 

%ylabel("Heave, Pitch, Roll ");
%legend('Heave','Pitch','Roll');
%title(strcat('Body Motion Test',testName))
%grid on;
%grid minor;

%% 
% Add in zero-phase filtering to remove high frequency mechanical and electical 
% noise from data

%d1 = designfilt("lowpassiir",FilterOrder=12, HalfPowerFrequency=0.9,DesignMethod="butter");
d1=designfilt('lowpassiir','FilterOrder',12,'StopbandFrequency',3,'StopbandAttenuation',60,'SampleRate',25,'DesignMethod','cheby2');
%  fvtool(d1)
postFilterFx = filtfilt(d1,ForceAndTorqueTable.Fx);       % zerophase filter Fx Data
postFilterFy = filtfilt(d1,ForceAndTorqueTable.Fy);       % zerophase filter Fy Data
postFilterFz = filtfilt(d1,ForceAndTorqueTable.Fz);       % zerophase filter Fz Data
postFilterSync=filtfilt(d1,ForceAndTorqueTable.Sync);     % zerophase filter Sync Data
filteredForceAndTorqueTable=table(nTime,postFilterFx,postFilterFy,postFilterFz,postFilterSync);   % build filtered experiemtal data table

%% 
% *Calculate Coefficient of Drag*
% 
% 

testDenominator=rho*towSpeed^2*bodyA;
testCoefDrag=(2*filteredForceAndTorqueTable.postFilterFx*4.44822)/testDenominator;    % convert test force in lb to newtons, calculate Cd    
expCoefDragTable=table(nTime,testCoefDrag);                                           % build filtered experiemtal data table
expReynoldsNumber=(towSpeed*towBodyLength)/nu;                                        % calculate Reynolds number

%take out drag figure for SeaGate Tests 1-18-26
%f1=figure('Name',"Drag Coefficient","Position",[100 150 800 800]);                    %create stand alone figure
%set(f1,'Visible','on');
%plot(expCoefDragTable,"nTime","testCoefDrag");                             % plot raw data in script, filtered data in pop up window Dave 4-8-24 
%ylabel("Coef. of Drag"); 
%legend('Coef. of Drag' );
%title(testName)
%title(strcat('Drag Coefficient test',testName))
%subtitle(strcat('Reynolds Number: ', num2str(expReynoldsNumber)));
%grid on;
%grid minor;
%axis([0 nSecondsOfData -3 3])            % can use to fix graph size

%save(strcat(fullFilePath,'_drag.mat'), 'expCoefDragTable')
%save figure
%saveas(gcf,strcat(fullFilePath,'_drag.fig'))

%% 
% Plot tow test results

% set(gcf,'Visible','on');    % enables creating a floating figure out of Live Editor
% figure('Name',"Load cell data","Position",[100 100 500 400]);         %create stand alone figure
f2=figure('Name',"Load cell data","Position",[750 150 800 800]);         %create stand alone figure
set(f2,'Visible','on');
%plot(ForceAndTorqueTable,"nTime",["Fx","Fy","Fz","Mx","My", "Mz"]);
% plot(ForceAndTorqueTable,"nTime",["Fx","Fy","Fz"]);  %commented out 1-20-26
%plot(filteredForceAndTorqueTable,"nTime",["postFilterFx","postFilterFy","postFilterFz","postFilterSync"]);
plot(filteredForceAndTorqueTable,"nTime",["postFilterFx"]);    %added 1-20-26

DragInX=mean(filteredForceAndTorqueTable.postFilterFx(750:1250));         %2-17-26 added mean drag calculation
xtext = 1.0; ytext = 0.0;
text(xtext, ytext, num2str(DragInX), 'VerticalAlignment', 'bottom', 'HorizontalAlignment', 'left')

%ylabel("Force(lbs) Moment(lb-in");
ylabel("Force(lbs)");
%legend('Fx','Fy','Fz','Mx','My','Mz'); 
%legend('Fx','Fy','Fz', 'Sync');
%legend('Fx','Fy','Fz');
legend('Fx');
%title(testName);
title(strcat('Tow Forces test ',testName)); 

subtitle(strcat('Tow Speed (m/s): ', num2str(towSpeed)));

grid on;
grid minor;
% axis([0 nSecondsOfData -7 7])            % can use to fix graph size
%% 
% 
%% 
% *Save ForceAndTorqueTable (.mat) and figure (.fig)*

%save table
save(strcat(fullFilePath,'.mat'), 'ForceAndTorqueTable')      % add saving the unfilterd data here.
%1save(strcat(fullFilePath,'.mat'), 'HeavePitchRollTable')      % add saving the unfilterd data here.
%save(strcat(fullFilePath,'.mat'), 'filteredForceAndTorqueTable')      % add saving the filterd data here.
%save figure
saveas(gcf,strcat(fullFilePath,'.fig'))
%disp("Experimental data saved")    
%disp('Data Processing done');
sound(stopSound);
doRunSwitch = input('Do another experimental run? Please choose n before exiting program or you will freeze DAQ! Type y or n? ', 's');
%% 
% End Program

end  % end of collect multiple experimental data run loop
clear d;
clear dq;    % close USB link to NI Daq
pause(0.5);
sound(endSound);


%% 
%