@echo off
rem ---------------------------------------------------------------------------
rem  Restart DeepSeek Harness with two debug channels open.
rem
rem    --force-renderer-accessibility
rem        Chromium publishes its accessibility tree, so Windows UI Automation
rem        can see the approval buttons inside the window (dsh-bridge.ps1).
rem
rem    --remote-debugging-port=9222
rem        Fallback: exposes the DevTools protocol, so a script can read the
rem        page DOM directly if accessibility turns out to be unavailable.
rem
rem  NOTE: this closes DeepSeek Harness, so the current chat session ends.
rem        Session history is saved - just reopen the session afterwards.
rem ---------------------------------------------------------------------------

set "DSH=C:\Users\33159\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe"

if not exist "%DSH%" (
  echo.
  echo   DeepSeek Harness not found at:
  echo     %DSH%
  echo.
  pause
  exit /b 1
)

echo.
echo   Stopping DeepSeek Harness ...
taskkill /IM "DeepSeek Harness.exe" /F >nul 2>&1
timeout /t 3 /nobreak >nul

echo   Starting with accessibility + debug port ...
start "" "%DSH%" --force-renderer-accessibility --remote-debugging-port=9222

timeout /t 2 /nobreak >nul
echo.
echo   Done. If the harness did not come up, start it from the usual icon.
echo.
timeout /t 4 /nobreak >nul
