#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/Local Text Helper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -target "$(uname -m)-apple-macos26.0" main.swift OCRRegionCapture.swift SelectionSpeech.swift SelectionPanel.swift \
    -o "$app/Contents/MacOS/LocalTextHelper" -framework AppKit -framework ApplicationServices \
    -framework ScreenCaptureKit -framework AVFoundation
cp Info.plist "$app/Contents/"
cp ocr_capture.py ollama_runtime.py process_text.py todo_public.py extract_todo.py natural_dates.py graph_todo.ps1 "$app/Contents/Resources/"
codesign --force --sign - "$app"
printf '%s\n' "$app"
