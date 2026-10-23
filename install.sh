#!/bin/bash
# Instala o helper Python e compila o ArLG.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/lg-ac"
mkdir -p "$CFG" "$HOME/Applications" "$HERE/build"
chmod 700 "$CFG"
cp "$HERE/helper/lgac.py" "$CFG/lgac.py"
[ -d "$CFG/venv" ] || python3 -m venv "$CFG/venv"
"$CFG/venv/bin/pip" install -q -r "$HERE/helper/requirements.txt"
if [ ! -f "$CFG/token" ]; then
  echo "Aviso: $CFG/token não existe. Cole seu token LG nele (veja README)."
fi
A="$HOME/Applications/ArLG.app"
mkdir -p "$A/Contents/MacOS"
cp "$HERE/app/Info.plist" "$A/Contents/"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" "$HERE/app/main.swift" -o "$HERE/build/ArLG"
cp "$HERE/build/ArLG" "$A/Contents/MacOS/ArLG"
codesign --force -s - "$A"
pkill -x ArLG 2>/dev/null || true
open "$A"
echo "Pronto: $A"
