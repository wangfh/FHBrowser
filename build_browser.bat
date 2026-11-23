@echo off
setlocal
rem =====================================================================
rem  FHBrowser build script (MSBuild)
rem  - Requires Delphi 11: set BDS if installed outside the default path
rem  - Requires CEF4Win7 source: set CEF4WIN7 to its root (has source\)
rem  - Output: bin\FHBrowser.exe ; DCU: dcu\
rem  - The requireAdministrator manifest comes from FHBrowser.dproj settings
rem =====================================================================
if not defined BDS set "BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0"

if not exist "%BDS%\bin\rsvars.bat" (
    echo [ERROR] Delphi not found: "%BDS%\bin\rsvars.bat"
    echo         Set environment variable BDS to the Delphi Studio folder.
    pause
    exit /b 1
)

rem --- CEF4Win7 source locate -------------------------------------------
rem  Source: https://github.com/salvadordf/CEF4Delphi/tree/109.0.5414.120
rem  Priority: valid CEF4WIN7 env var > third_party\CEF4Win7 > %USERPROFILE%
rem            > author-local path (last line, contributors can ignore it).
rem  A found folder is exported to the msbuild child process (dproj uses $(CEF4WIN7)).
if defined CEF4WIN7 if not exist "%CEF4WIN7%\source\uCEFApplication.pas" echo [WARN] CEF4WIN7 is set but "%CEF4WIN7%\source\uCEFApplication.pas" not found - falling back to known locations.
if not defined CEF4WIN7 if exist "%~dp0third_party\CEF4Win7\source\uCEFApplication.pas" set "CEF4WIN7=%~dp0third_party\CEF4Win7"
if not defined CEF4WIN7 if exist "%USERPROFILE%\CEF4Win7\source\uCEFApplication.pas" set "CEF4WIN7=%USERPROFILE%\CEF4Win7"
if not defined CEF4WIN7 if exist "D:\DelphiComponent\CEF4Win7\source\uCEFApplication.pas" set "CEF4WIN7=D:\DelphiComponent\CEF4Win7"

if not defined CEF4WIN7 (
    echo [ERROR] CEF4Win7 source not found.
    echo         Get it from:
    echo             https://github.com/salvadordf/CEF4Delphi/tree/109.0.5414.120
    echo         Then either set CEF4WIN7 to the source root ^(the folder holding source^), e.g.
    echo             set CEF4WIN7=C:\CEF4Delphi\109.0.5414.120
    echo         or put the source at third_party\CEF4Win7 under this project.
    pause
    exit /b 1
)
if not exist "%CEF4WIN7%\source" (
    echo [ERROR] CEF4Win7 source folder not found: "%CEF4WIN7%\source"
    pause
    exit /b 1
)
echo [INFO] CEF4WIN7 = %CEF4WIN7%

call "%BDS%\bin\rsvars.bat"
cd /d "%~dp0src"

echo === Build FHBrowser (MSBuild) ===
msbuild FHBrowser.dproj /t:Build /p:Config=Base /p:Platform=Win32 /v:m
if errorlevel 1 (
    echo.
    echo [ERROR] Build failed
    pause
    exit /b 1
)

echo.
echo BUILD OK: ..\bin\FHBrowser.exe
echo NOTE: these runtime files must exist in ..\bin : libcef.dll, chrome_elf.dll,
echo       icudtl.dat, snapshot_blob.bin, v8_context_snapshot.bin,
echo       *.pak (root and locales\), libEGL.dll, libGLESv2.dll,
echo       vk_swiftshader*.dll, vulkan-1.dll, d3dcompiler_47.dll,
echo       and sqlite3.dll (required by the history database).
echo.
pause
exit /b 0