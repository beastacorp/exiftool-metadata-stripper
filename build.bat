@echo off
REM ----------------------------------------------------------------------
REM  build.bat -- build the ExifTool Metadata Stripper .exe
REM
REM  Run this from Explorer (double-click) or from cmd/PowerShell
REM  (".\build.bat").
REM
REM  One-time setup this does NOT do for you (run once, before the first
REM  build):
REM      cpan install PAR::Packer Tk
REM ----------------------------------------------------------------------
setlocal
cd /d "%~dp0"

echo ============================================================
echo  ExifTool Metadata Stripper - build
echo ============================================================
echo.
echo A window for the app itself will pop up partway through this.
echo That's expected: the packager runs the app once to see which
echo pieces of Perl/Tk it actually uses. When it appears, click
echo through it once --
echo   - Add Files...          (pick anything)
echo   - Add Folder...         (pick anything)
echo   - select an item, then Remove Selected From List
echo   - add one disposable test file, click Remove All Metadata,
echo     click Yes on the confirmation, then OK on the summary
echo   - Clear List
echo then just close the window. This script will then finish on
echo its own -- no further input needed after that.
echo.
pause

where pp >nul 2>nul
if errorlevel 1 (
    echo.
    echo ERROR: "pp" was not found on PATH.
    echo Install it first with:  cpan install PAR::Packer Tk
    echo.
    pause
    exit /b 1
)

pp @pp_build_exe.args
if errorlevel 1 (
    echo.
    echo Build failed -- see the errors above.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Done. ExifMetadataStripper.exe is ready in this folder.
echo ============================================================
pause
