@echo off
REM SPDX-License-Identifier: GPL-3.0-or-later
REM ===========================================================================
REM  vodpatch - put the missing beginning back on a recording.
REM
REM  JUST DOUBLE-CLICK THIS FILE. It opens a menu and explains itself.
REM
REM  Everything is portable: unzip this folder anywhere - a stick, the desktop,
REM  next to your footage - and run it from there. Nothing is installed and
REM  nothing is written outside this folder.
REM
REM  You can also skip the menu and name a step directly:
REM      vodpatch.bat analyze
REM      vodpatch.bat seamtest
REM      vodpatch.bat merge "D:\somewhere\full_stream.mp4"
REM      vodpatch.bat doctor
REM ===========================================================================

setlocal
title vodpatch

REM Labels rather than if(...)else(...) blocks: cmd mis-parses a closing
REM parenthesis inside a block when the folder name contains one, which is
REM exactly what a second download gives you - "vodpatch-main (1)".
if "%~1"=="" goto menu
if "%~2"=="" goto stage
goto stageout

:menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vodpatch.ps1" -Stage menu
exit /b %ERRORLEVEL%

:stage
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vodpatch.ps1" -Stage "%~1"
goto done

:stageout
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vodpatch.ps1" -Stage "%~1" -Out "%~2"
goto done

:done
echo.
echo Finished. The log is in this folder, named after the step.
pause
