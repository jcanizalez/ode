# The ODE Virtual Microphone

ODE makes denoised audio available to *any* app by routing it through a
CoreAudio **loopback device** — a paired output + input where whatever is
written to the output is readable on the input.

```
 Real mic ─► ode live ─► (writes to) ─► Loopback OUTPUT
                                            │  (internal wire)
                                            ▼
 Zoom/Teams ◄─ (selects as mic) ◄─ Loopback INPUT   ("ODE Microphone")
```

This is exactly how Krisp works: on this machine you can see Krisp's own pair
with `ode devices` — `krisp speaker` (output) and `krisp microphone` (input).

## Quick path — BlackHole via Homebrew (recommended)

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is an MIT-licensed,
signed and notarized loopback driver. No Xcode needed.

```sh
./scripts/install-virtual-mic.sh        # installs "BlackHole 2ch"
ode live --out "BlackHole 2ch"          # route denoised audio in
# then pick "BlackHole 2ch" as the mic in your conferencing app
```

## Branded path — build "ODE Microphone" from source

To make the device show up literally as **"ODE Microphone"**, build BlackHole
from source with a custom driver name. Requires **full Xcode** (not just the
Command Line Tools) and admin rights.

```sh
git clone https://github.com/ExistentialAudio/BlackHole.git
cd BlackHole
xcodebuild -project BlackHole.xcodeproj \
  -configuration Release \
  -target BlackHole \
  CONFIGURATION_BUILD_DIR=build \
  PRODUCT_BUNDLE_IDENTIFIER="com.ode.ODEMicrophone" \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
    kDriver_Name=\"ODE\"
    kPlugIn_BundleID=\"com.ode.ODEMicrophone\"
    kDevice_Name=\"ODE Microphone\"
    kNumber_Of_Channels=2'

sudo cp -R build/BlackHole.driver \
  "/Library/Audio/Plug-Ins/HAL/ODEMicrophone.driver"
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

Then:

```sh
ode live --out "ODE Microphone"
```

The signing/notarization steps required for distribution to other machines are
covered in the Phase 4 installer work (see `plan` / roadmap).

## Verifying

```sh
ode devices     # the loopback device should appear with [in,out]
```
