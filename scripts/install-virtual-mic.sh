#!/bin/sh
# ODE — install the virtual microphone device.
#
# ODE needs a CoreAudio "loopback" device: a paired output+input where audio
# written to the output appears on the input. The ODE engine writes denoised
# audio to that device's output; conferencing apps select its input as their
# microphone.
#
# Quick path (this script): install BlackHole 2ch — a signed, notarized,
# MIT-licensed loopback driver — via Homebrew. No Xcode required.
#
# Branded path ("ODE Microphone" name): build BlackHole from source with a
# custom driver name. See docs/VIRTUAL_MIC.md.

set -e

DEVICE_NAME="BlackHole 2ch"

echo "ODE virtual-microphone setup"
echo "----------------------------"

if [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
    echo "✓ BlackHole already installed."
else
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew not found. Install from https://brew.sh, then re-run." >&2
        exit 1
    fi
    echo "Installing BlackHole 2ch via Homebrew (you may be prompted for your password)…"
    brew install blackhole-2ch
fi

echo
echo "Next steps:"
echo "  1. Run the denoiser, routing clean audio into the device:"
echo "       ode live --out \"$DEVICE_NAME\""
echo "  2. In Zoom/Teams/Discord/your browser, choose \"$DEVICE_NAME\""
echo "     as the MICROPHONE."
echo
echo "Tip: 'ode devices' lists everything CoreAudio sees."
