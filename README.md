# Android Blob Utility

[![Build and Release](https://github.com/Eliminater74/Android-Blob-Utility/actions/workflows/build-release.yml/badge.svg)](https://github.com/Eliminater74/Android-Blob-Utility/actions/workflows/build-release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A command-line tool that automatically identifies every proprietary library a binary blob depends on — including hidden runtime dependencies the linker never complains about — and formats the results ready to paste into a `vendor-blobs.mk` file.

Maintained by **Eliminater74**. Originally written by JackpotClavin (2014).

---

## Supported Android Versions

| SDK | Android Version | Notes |
| --- | --------------- | ----- |
| 14 | 4.0 Ice Cream Sandwich | |
| 15 | 4.0.3 Ice Cream Sandwich | |
| 16 | 4.1 Jelly Bean | |
| 17 | 4.2 Jelly Bean | |
| 18 | 4.3 Jelly Bean | |
| 19 | 4.4 KitKat | |
| 20 | 4.4W KitKat Wear | |
| 21 | 5.0 Lollipop | |
| 22 | 5.1 Lollipop | |
| 23 | 6.0 Marshmallow | |
| 24 | 7.0 Nougat | |
| 25 | 7.1.1 Nougat | |
| 26 | 8.0 Oreo | Project Treble |
| 27–35 | 8.1 → 15 | Generate with `tools/generate_sdk_files.sh` |

Android TV and Google TV images are merged into each SDK file automatically when you generate them, so TV-specific AOSP libraries are correctly recognized as non-proprietary.

---

## How It Works

When porting a device to AOSP you need to know which binary files are proprietary. Simply copying what the linker complains about misses libraries that are loaded at runtime — the daemon starts but silently misbehaves.

This tool:

1. Memory-maps each blob and scans for every `.so` string inside it
2. Checks each found library name against the AOSP emulator image for your SDK version
3. If a library is **not** in the AOSP image → it's proprietary and printed in `vendor-blobs.mk` format
4. Recursively repeats the scan for every newly discovered proprietary library

The result is the complete closure of all proprietary dependencies in one shot.

> **Note:** A library present in the AOSP emulator image isn't automatically safe to use from there. A proprietary daemon may still require its own build of `libril.so` even though AOSP ships one. Use your judgement.

---

## Building

### Requirements

- GCC or Clang
- POSIX system (Linux, macOS, WSL on Windows)

### Standard build

```bash
make
```

### Optional: readline support (tab completion, history)

```bash
make BUILD_WITH_READLINE=true
```

### Cross-compile for Windows (Linux host, MinGW required)

```bash
make windows
# produces android-blob-utility.exe
```

### Install system-wide

```bash
sudo make install     # installs to /usr/local/bin
sudo make uninstall
```

---

## Usage

### 1. Dump your device's system partition

```bash
adb pull /system /path/to/dump/system
# For post-Treble devices (Android 8.0+), also pull vendor:
adb pull /vendor /path/to/dump/vendor
```

### 2. Run the tool

```bash
./android-blob-utility
```

The tool will prompt you interactively:

```text
System dump root?
> /path/to/dump/system

Target vendor name [google]?
> lge

Target device name [sailfish]?
> vs980

System dump SDK version? [19]
> 28

How many files?
> 2

Files to go: 2
File name?
> /system/bin/mm-qcamera-daemon

Files to go: 1
File name?
> /system/lib/hw/camera.msm8974.so
```

### 3. Redirect output to your vendor makefile

```bash
./android-blob-utility >> vendor/lge/vs980/vs980-vendor-blobs.mk
```

The output is already formatted for direct inclusion:

```makefile
vendor/lge/vs980/proprietary/vendor/lib/libmmcamera2_stats_modules.so:vendor/lib/libmmcamera2_stats_modules.so \
vendor/lge/vs980/proprietary/vendor/lib/libmmcamera_faceproc.so:vendor/lib/libmmcamera_faceproc.so \
...
```

---

## Generating SDK Files for Android 8.1–15 (SDK 27–35)

SDK files for Android 8.1 and newer are not bundled — they're generated from AOSP emulator images using the included script. Run this once on a Linux machine (or let GitHub Actions do it on release).

### Prerequisites

```bash
sudo apt-get install e2fsprogs curl unzip python3
```

### Generate all missing SDKs (phone + Android TV + Google TV merged)

```bash
./tools/generate_sdk_files.sh 27 28 29 30 31 32 33 34 35
```

### Generate a single SDK

```bash
./tools/generate_sdk_files.sh 35
```

### Script options

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `MERGE_TV` | `true` | Merge Android TV / Google TV images into each SDK file |
| `SDK_VARIANT` | `google_apis` | Base image variant (`default`, `google_apis`, `google_apis_playstore`) |
| `SDK_ARCH` | `x86_64` | Base image architecture |
| `ANDROID_SDK_ROOT` | auto-downloaded | Path to an existing Android SDK installation |
| `OUTPUT_DIR` | `emulator_systems/` | Where to write `sdk_NN.txt` files |

### Example: phone images only, no TV

```bash
MERGE_TV=false ./tools/generate_sdk_files.sh 33
```

---

## Releases

Pre-built binaries (Linux, macOS, Windows) and a bundled `emulator_systems.tar.gz` with SDK 27–35 files are published on the [Releases](https://github.com/Eliminater74/Android-Blob-Utility/releases) page.

To create a new release, push a version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions will build all platforms, generate the SDK files (with TV support), and publish the release automatically. You can also trigger a release manually from the **Actions** tab using the **Build and Release** workflow.

---

## Modern Android Support

### Project Treble (Android 8.0+, SDK 26+)

Vendor libraries moved from `/system/vendor/` to a separate `/vendor/` partition. The tool handles both layouts — it checks both paths when scanning the emulator reference and produces the correct partition mapping in the output:

- Pre-Treble: `system/vendor/lib/libfoo.so`
- Post-Treble: `vendor/lib/libfoo.so`

### APEX Modules (Android 10+, SDK 29+)

Core system libraries (libc, libm, ART runtime, media codecs, etc.) moved into APEX packages mounted at `/apex/`. The tool's search directories include the most common APEX paths, and the `generate_sdk_files.sh` script extracts APEX contents into the reference file so these libraries are correctly identified as AOSP-supplied.

### Android TV / Google TV

TV images are automatically downloaded alongside the standard images when you run `generate_sdk_files.sh`. The file lists are merged so TV-specific AOSP libraries don't get falsely flagged as proprietary when you're working on a TV device.

---

## Project Structure

```text
android-blob-utility.c      Main source
android-blob-utility.h      Configuration (buffer sizes, search paths)
Makefile                    Build rules
Android.mk                  AOSP in-tree build support
emulator_systems/           AOSP file reference lists (sdk_14.txt … sdk_NN.txt)
tools/
  generate_sdk_files.sh     Generates sdk_NN.txt from AOSP emulator images
.github/workflows/
  build-release.yml         CI/CD: builds + releases on tag push
```

---

## License

MIT — see [LICENSE](LICENSE).

Original work copyright (c) 2014 JackpotClavin.
Maintained and modernized by Eliminater74 (2026).
