@echo off
cd /d C:\Users\tapop\Documents\src\Lacuna-Automation
if not exist logs mkdir logs
set PATH=C:\Strawberry\c\bin;%PATH%

C:\Strawberry\perl\bin\perl.exe build_queue.pl --body=Noseeum >> "logs\build_queue.log" 2>&1
C:\Strawberry\perl\bin\perl.exe build_queue.pl --body=Overlook >> "logs\build_queue.log" 2>&1
C:\Strawberry\perl\bin\perl.exe build_queue.pl --body=Confidence >> "logs\build_queue.log" 2>&1

for /f "tokens=1-2 delims=:.," %%a in ("%time%") do set HH=%%a&set MM=%%b
set HH=%HH: =%
set /a MMN=1%MM% %% 100
set /a HHN=1%HH% %% 100
if %MMN% LSS 5 (
  C:\Strawberry\perl\bin\perl.exe probe_hunter.pl --zone '2|-2' --zone '3|-1' --body Confidence --body Overlook >> "logs\probe_hunter.log" 2>&1
  echo ======== trashman started %date% %time% >> "logs\trashman.log"
  C:\Strawberry\perl\bin\perl.exe trashman.pl --body=Noseeum --time=55m >> "logs\trashman.log" 2>&1
  C:\Strawberry\perl\bin\perl.exe trashman.pl --body=Overlook --time=55m >> "logs\trashman.log" 2>&1
  C:\Strawberry\perl\bin\perl.exe trashman.pl --body=Confidence --time=55m >> "logs\trashman.log" 2>&1
)

if %MMN% GEQ 30 (
  if %MMN% LSS 35 (
    C:\Strawberry\perl\bin\perl.exe probe_hunter.pl --zone '2|-2' --zone '3|-1' --body Confidence --body Overlook >> "logs\probe_hunter.log" 2>&1
  )
)

REM Run star_scan 10 minutes before the daily RPC count reset (midnight GMT).
REM This machine is PST (UTC-8), so midnight GMT = 16:00 local; 10 min before = 15:50.
REM Adjust HHN if the system timezone changes.
if %HHN% EQU 15 (
  if %MMN% EQU 50 (
    echo ======== star_scan started %date% %time% >> "logs\star_scan.log"
    C:\Strawberry\perl\bin\perl.exe star_scan.pl --db stars.db >> "logs\star_scan.log" 2>&1
  )
)

C:\Strawberry\perl\bin\perl.exe entertainment.pl --daily >> "logs\entertainment.log" 2>&1
