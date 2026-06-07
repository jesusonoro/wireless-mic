@echo off
REM ────────────────────────────────────────────────────────────────────────────
REM Build a self-contained Windows .exe for the EVERMIC receiver.
REM
REM Run this ON a Windows machine (PyInstaller does NOT cross-compile from macOS).
REM
REM Prerequisites:
REM   1. Install Python 3.10+ from https://python.org  (tick "Add python.exe to PATH").
REM      The python.org build ships Tk 8.6, which the redesigned UI needs.
REM   2. From this folder:  pip install -r requirements.txt
REM
REM Output:  dist\receiver.exe   (double-click to run)
REM ────────────────────────────────────────────────────────────────────────────

echo Installing build dependencies...
pip install --quiet pyinstaller -r requirements.txt
if errorlevel 1 (
  echo.
  echo ERROR: dependency install failed. Is Python on PATH? ^(python --version^)
  exit /b 1
)

echo Building receiver.exe ...
pyinstaller ^
  --onefile ^
  --windowed ^
  --clean ^
  --noconfirm ^
  --name receiver ^
  --collect-all sounddevice ^
  receiver.py
if errorlevel 1 (
  echo.
  echo ERROR: PyInstaller build failed.
  exit /b 1
)

echo.
echo ============================================================
echo  Build complete:  dist\receiver.exe
echo.
echo  Run it:          dist\receiver.exe
echo.
echo  On first launch Windows Defender Firewall will prompt to
echo  allow inbound UDP. Click "Allow access" so the phone can
echo  reach it on ports 7355 (audio) and 7356 (discovery).
echo ============================================================
