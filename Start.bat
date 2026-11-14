@echo off
rem ===========================================================================
rem  LHV Scan - double-click this file to start the tool.
rem
rem  It opens the LHV Scan window (LHV-Scan.ps1 in this folder). The window
rem  shows which simulator folders it reads and what it finds. Nothing in your
rem  simulator is changed, and nothing is sent before you press "Send".
rem
rem  What the options mean:
rem    -NoProfile               do not load your personal PowerShell settings
rem    -ExecutionPolicy Bypass  let Windows run this one script, this one time.
rem                             It changes no setting on your PC.
rem    -STA                     needed by Windows to draw the window
rem ===========================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0LHV-Scan.ps1"
if errorlevel 1 (
  echo.
  echo LHV Scan stopped with an error. The message is shown above.
  pause
)
