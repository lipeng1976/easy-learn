@echo off
setlocal
cd /d "%~dp0.."

rem =====================================================================
rem  KEEP THIS FILE ASCII-ONLY AND CRLF.  Do not "fix" it.
rem
rem  Why: cmd.exe parses a .cmd file as a raw byte stream using the
rem  console ANSI codepage (936/GBK on Chinese Windows).  Two things
rem  break it, and both were true here on 2026-10-06:
rem    1. LF-only line endings  -> cmd loses its position, lines merge.
rem    2. Non-ASCII text        -> UTF-8 Chinese misread as GBK, the
rem       byte pairs realign and can EAT the following CR/LF, merging
rem       the next line into this one.  Symptom: cmd tries to run
rem       fragments like 'onst{spawnSync}' (the 'c' of 'const' got
rem       swallowed by the previous line's last Chinese character).
rem  Same reason a stray & | < > inside garbled text can execute things.
rem =====================================================================

echo ================================================================
echo  flutter analyze + test   -^>  run this OUTSIDE WorkBuddy
echo  project root: %CD%
echo ================================================================
echo.
echo [1/4] pipe probe -- MUST print OK in this window.
echo       If it prints FAIL, this window is STILL sandboxed.
echo       Close it and use a plain cmd / PowerShell opened from
echo       the Start menu (NOT from WorkBuddy).
echo.
node -e "const{spawnSync}=require('child_process');const r=spawnSync(process.execPath,['-e','1'],{stdio:['pipe','pipe','pipe']});console.log(r.error?('      FAIL '+r.error.code):'      OK')"
echo.
if not exist build mkdir build

echo [2/4] flutter analyze ...
echo.
call flutter analyze
set ANALYZE_RC=%ERRORLEVEL%
echo    analyze exit code = %ANALYZE_RC%
rem   exit code 1 is NORMAL when only "info" lines appear; search the output for "error".
echo.

echo [3/4] flutter test (json reporter), result -^> build\_ftest.json ...
echo.
rem  The default compact reporter collapses when redirected, so use json.
call flutter test --reporter=json > build\_ftest.json 2>&1
set TEST_RC=%ERRORLEVEL%
echo.

echo [4/4] summary ...
echo.
node tools\ftest-summary.mjs build\_ftest.json
set SUMMARY_RC=%ERRORLEVEL%
echo.
echo ================================================================
echo  analyze=%ANALYZE_RC%  test=%TEST_RC%  summary=%SUMMARY_RC%
echo  summary != 0  means: some case is red, or a test file never ran
echo ================================================================
echo.
pause
