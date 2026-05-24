#!/usr/bin/env bash
# Build a self-contained macOS .app bundle.
# Requires: pip install pyinstaller

set -euo pipefail

pip install --quiet pyinstaller sounddevice numpy

pyinstaller \
  --onefile \
  --windowed \
  --name "WirelessMicReceiver" \
  --add-binary "$(python3 -c 'import sounddevice; import os; print(os.path.dirname(sounddevice.__file__))')/libportaudio.dylib:sounddevice" \
  receiver.py

echo ""
echo "Build complete: dist/WirelessMicReceiver"
