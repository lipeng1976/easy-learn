@echo off
setlocal
cd /d "%~dp0.."

echo ================================================================
echo  Build APK OUTSIDE WorkBuddy
echo  project root: %CD%
echo ================================================================
echo.
echo [1/3] pipe probe -- MUST print OK in this window.
echo       If it prints FAIL, this window is STILL sandboxed.
echo       Close it and use a plain cmd / PowerShell opened from
echo       the Start menu (NOT from WorkBuddy).
echo.
node -e "const{spawnSync}=require('child_process');const r=spawnSync(process.execPath,['-e','1'],{stdio:['pipe','pipe','pipe']});console.log(r.error?('      FAIL '+r.error.code):'      OK')"
echo.

echo [2/3] build ...
echo.
node tools\build-cloud-apk.mjs --out apk
set RC=%ERRORLEVEL%
echo.

echo [3/3] artifact
if exist "easy-learn-cloud.apk" (
  for %%F in ("easy-learn-cloud.apk") do echo   size = %%~zF bytes
  for %%F in ("easy-learn-cloud.apk") do echo   time = %%~tF
  certutil -hashfile "easy-learn-cloud.apk" SHA256
) else (
  echo   easy-learn-cloud.apk NOT FOUND
)
echo.
echo build exit code = %RC%
echo.
pause
