@echo off
rem ============================================================================
rem make_music.bat -- turn the BGM into G:\MUSIC.WAV (48 kHz / 16-bit / stereo)
rem
rem What the board wants, exactly:
rem   * canonical 44-byte WAV header (RIFF/WAVE, PCM, fmt at 20, "data" at 36);
rem     ffmpeg adds a LIST/INFO chunk by default, so the bitexact flags below
rem     are NOT optional -- without them the loader rejects the file
rem   * 48 kHz, 2 channels, 16 bit  (the player reads one 32-bit word per frame)
rem   * the first 30 s only: the board keeps it in 8 MB of SDRAM and loops it
rem   * written CONTIGUOUSLY, because the loader reads linearly (no FAT walk)
rem
rem Usage:  make_music.bat                  (newest .aac from JiJiDown)
rem         make_music.bat "C:\path\x.aac"  (explicit file)
rem ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0..\.."

set "FF=wall\tools\ffmpeg\ffmpeg.exe"
if not exist "%FF%" (
    echo [info] ffmpeg.exe missing, fetching it from the npm mirror...
    powershell -NoProfile -ExecutionPolicy Bypass -File wall\tools\get_ffmpeg.ps1 || goto :err
)

set "SRC=%~1"
if not defined SRC (
    for /f "delims=" %%F in ('dir /b /o-d "D:\Program Files\JiJiDown\Download\*.aac" 2^>nul') do (
        if not defined SRC set "SRC=D:\Program Files\JiJiDown\Download\%%F"
    )
)
if not defined SRC (
    echo [ERROR] no .aac found; pass one:  make_music.bat "C:\path\to\song.aac"
    goto :err
)

echo source : "%SRC%"
echo target : wall\media\MUSIC.WAV   ^(first 30 s, 48 kHz, 16-bit, stereo^)

"%FF%" -hide_banner -y -i "%SRC%" -t 30 -ar 48000 -ac 2 -c:a pcm_s16le ^
       -map_metadata -1 -fflags +bitexact -flags:a +bitexact ^
       "wall\media\MUSIC.WAV"
if errorlevel 1 goto :err

rem ---- find the removable card and rewrite it (music first => contiguous) ----
set "CARD="
for %%D in (G H I J K L M) do (
    if not defined CARD (
        if exist "%%D:\" (
            fsutil fsinfo drivetype %%D: 2>nul | find /i "Removable" >nul && set "CARD=%%D:"
        )
    )
)
if not defined CARD (
    echo [warn] no removable drive found; MUSIC.WAV is in wall\media\, copy it yourself
    goto :done
)

echo card   : %CARD%
del /q "%CARD%\MUSIC.WAV" 2>nul
copy /y "wall\media\MUSIC.WAV" "%CARD%\MUSIC.WAV" >nul
for %%P in (CAM1 CAM2 CAM3 CAM4) do if exist "wall\media\%%P.BMP" copy /y "wall\media\%%P.BMP" "%CARD%\%%P.BMP" >nul
dir /b "%CARD%\*.WAV" "%CARD%\*.BMP" 2>nul | findstr /i "MUSIC CAM" 

:done
echo.
echo done.
pause
exit /b 0

:err
echo.
echo [FAILED] see the message above.
pause
exit /b 1
