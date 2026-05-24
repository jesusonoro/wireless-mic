@echo off
REM Build a self-contained Windows .exe
REM Requires: pip install pyinstaller

pip install --quiet pyinstaller sounddevice numpy

pyinstaller ^
  --onefile ^
  --windowed ^
  --name WirelessMicReceiver ^
  receiver.py

echo.
echo Build complete: dist\WirelessMicReceiver.exe
