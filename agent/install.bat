@echo off
:: Enshroud Buddy PC agent: one-time setup.
:: Needs Python 3.10 or newer from python.org, with "Add python.exe to PATH" ticked during its install.
cd /d "%~dp0"

set PY=
py -3 --version >nul 2>&1 && set PY=py -3
if not defined PY python --version >nul 2>&1 && set PY=python
if not defined PY (
  echo Python wasn't found. Install Python 3.10 or newer from https://www.python.org/downloads/
  echo and tick "Add python.exe to PATH", then run this again.
  pause
  exit /b 1
)

echo Installing the agent's packages...
%PY% -m pip install --user --disable-pip-version-check -r requirements.txt
if errorlevel 1 (
  echo The packages didn't install; see the messages above.
  pause
  exit /b 1
)

echo.
choice /m "Start the agent automatically when Windows starts"
if errorlevel 2 goto done
%PY% agent.py --install-autostart

:done
echo.
echo Done. Run start.bat: a small icon appears in the tray (bottom right).
echo Right-click it to see the "Phone address" to type into the app's Setup.
pause
