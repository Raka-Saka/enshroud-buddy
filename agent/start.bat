@echo off
:: Enshroud Buddy PC agent, runs quietly in the tray.
:: To leave the game's memory alone (no live position), add --no-live after agent.py on the line below.
cd /d "%~dp0"
where pyw >nul 2>&1 && (start "" pyw -3 agent.py %*) || (start "" pythonw agent.py %*)
