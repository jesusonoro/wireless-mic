#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Build a self-contained macOS .app bundle for the EVERMIC receiver.
#
# Output:  dist/receiver.app   (and a dist/receiver CLI binary)
#
# IMPORTANT — Tk version: the redesigned UI needs Tk 8.6+. macOS's *system*
# Python (/usr/bin/python3) ships the ancient Tk 8.5.9, which renders the window
# blank. Build with a python.org or Homebrew Python that has a modern Tk:
#   brew install python@3.12 python-tk@3.12   # gives Tk 9.x
# then run this script with that interpreter's pip/pyinstaller on PATH.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Warn loudly if the active python has the broken system Tk.
tkver="$(python3 -c 'import tkinter as t; print(t.Tk().tk.call("info","patchlevel"))' 2>/dev/null || echo "none")"
case "$tkver" in
  8.5.*|8.4.*|none)
    echo "⚠️  WARNING: active python has Tk $tkver — the UI will render blank."
    echo "    Use a python.org / Homebrew Python with Tk 8.6+ (brew install python-tk@3.12)."
    echo "    Continuing in 3s (Ctrl-C to abort)…"
    sleep 3
    ;;
  *)
    echo "Tk $tkver — OK."
    ;;
esac

pip install --quiet pyinstaller -r requirements.txt

pyinstaller \
  --onefile \
  --windowed \
  --clean \
  --noconfirm \
  --name receiver \
  --collect-all sounddevice \
  receiver.py

echo ""
echo "Build complete: dist/receiver.app  (and dist/receiver)"
