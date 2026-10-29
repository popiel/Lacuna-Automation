@echo off
cd /d C:\Users\tapop\Documents\src\Lacuna-Automation
if not exist logs mkdir logs
set PATH=C:\Strawberry\c\bin;%PATH%

C:\Strawberry\perl\bin\perl.exe build_queue.pl --body=Noseeum >> "logs\build_queue.log" 2>&1

for /f "tokens=1-2 delims=:.," %%a in ("%time%") do set MM=%%b
set /a MMN=1%MM% %% 100
if %MMN% LSS 5 (
  echo ======== trashman started %date% %time% >> "logs\trashman.log"
  C:\Strawberry\perl\bin\perl.exe trashman.pl --body=Noseeum --time=55m >> "logs\trashman.log" 2>&1
)

C:\Strawberry\perl\bin\perl.exe entertainment.pl --daily >> "logs\entertainment.log" 2>&1
