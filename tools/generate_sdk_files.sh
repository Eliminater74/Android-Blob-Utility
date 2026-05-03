#!/usr/bin/env bash
# generate_sdk_files.sh — generate emulator_systems/sdk_NN.txt file listings
# from AOSP emulator system images via the Android SDK Manager.
#
# Requirements (Linux):
#   - curl or wget
#   - unzip
#   - Android SDK command-line tools  OR  $ANDROID_SDK_ROOT already set up
#   - e2fsprogs  (for debugfs / simg2img on ext4 images)
#   - sudo       (to loop-mount images; skipped if debugfs is used instead)
#   - Python 3   (for APEX extraction on SDK 29+)
#
# Usage:
#   ./tools/generate_sdk_files.sh [SDK_VERSION ...]
#
# Examples:
#   ./tools/generate_sdk_files.sh 27 28 29 30 31 32 33 34 35
#   SDK_VARIANT=google_apis_playstore ./tools/generate_sdk_files.sh 33
#
# Environment variables:
#   ANDROID_SDK_ROOT   Path to an existing Android SDK installation.
#                      If unset the script downloads command-line tools
#                      to /tmp/abd-android-sdk.
#   SDK_VARIANT        System image variant (default: google_apis).
#                      Other options: default, google_apis_playstore
#   SDK_ARCH           Image architecture (default: x86_64).
#   OUTPUT_DIR         Where to write sdk_NN.txt files
#                      (default: emulator_systems/ next to this script).
#   WORK_DIR           Scratch space (default: /tmp/abd-sdk-gen).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/emulator_systems}"
WORK_DIR="${WORK_DIR:-/tmp/abd-sdk-gen}"
SDK_VARIANT="${SDK_VARIANT:-google_apis}"
SDK_ARCH="${SDK_ARCH:-x86_64}"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$WORK_DIR/android-sdk}"
SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

DEFAULT_VERSIONS=(27 28 29 30 31 32 33 34 35)
VERSIONS=("${@:-${DEFAULT_VERSIONS[@]}}")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[generate_sdk_files] $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Install it and retry."
}

# ---------------------------------------------------------------------------
# Setup Android SDK / sdkmanager
# ---------------------------------------------------------------------------

setup_sdk_manager() {
    if [[ -x "$SDKMANAGER" ]]; then
        info "Using existing sdkmanager at $SDKMANAGER"
        return
    fi

    info "Downloading Android command-line tools..."
    mkdir -p "$WORK_DIR"
    local zip="$WORK_DIR/cmdline-tools.zip"
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$CMDLINE_TOOLS_URL" -o "$zip"
    else
        wget -q "$CMDLINE_TOOLS_URL" -O "$zip"
    fi

    local tmp="$WORK_DIR/cmdline-tools-extract"
    rm -rf "$tmp"
    unzip -q "$zip" -d "$tmp"

    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    mv "$tmp/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    rm -f "$zip"
    info "SDK Manager installed at $SDKMANAGER"
}

# ---------------------------------------------------------------------------
# Install a system image for the given SDK version
# ---------------------------------------------------------------------------

install_image() {
    local sdk_ver="$1"
    local package="system-images;android-${sdk_ver};${SDK_VARIANT};${SDK_ARCH}"
    info "Installing: $package"
    # Accept licenses non-interactively
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "$package" 2>&1 \
        | grep -v "^[[:space:]]*$" || true
}

# ---------------------------------------------------------------------------
# Find system.img for the given SDK version
# ---------------------------------------------------------------------------

find_system_img() {
    local sdk_ver="$1"
    local img_dir="$ANDROID_SDK_ROOT/system-images/android-${sdk_ver}/${SDK_VARIANT}/${SDK_ARCH}"
    if [[ -f "$img_dir/system.img" ]]; then
        echo "$img_dir/system.img"
    else
        die "system.img not found at $img_dir/system.img"
    fi
}

# ---------------------------------------------------------------------------
# Extract file list from a system.img using debugfs (no root needed)
# ---------------------------------------------------------------------------

list_files_debugfs() {
    local img="$1"
    local raw_img="${img%.img}_raw.img"

    # Convert sparse Android img to raw ext4 if needed
    if command -v simg2img >/dev/null 2>&1; then
        info "  Converting sparse image..."
        simg2img "$img" "$raw_img" 2>/dev/null || cp "$img" "$raw_img"
    else
        cp "$img" "$raw_img"
    fi

    info "  Listing files with debugfs..."
    # debugfs -R 'ls -p -r /' lists all files recursively
    debugfs -R 'ls -p -r /' "$raw_img" 2>/dev/null \
        | awk -F/ '$6 != "" && $6 != "." && $6 != ".." { print "/system/" $6 }' \
        | sort -u

    rm -f "$raw_img"
}

# ---------------------------------------------------------------------------
# Alternative: mount the image (requires sudo)
# ---------------------------------------------------------------------------

list_files_mount() {
    local img="$1"
    local mnt="$WORK_DIR/mnt_system"

    local raw_img="${img%.img}_raw.img"
    if command -v simg2img >/dev/null 2>&1; then
        simg2img "$img" "$raw_img" 2>/dev/null || cp "$img" "$raw_img"
    else
        cp "$img" "$raw_img"
    fi

    mkdir -p "$mnt"
    sudo mount -o loop,ro "$raw_img" "$mnt"

    find "$mnt" \( -type f -o -type l \) | sed "s|$mnt|/system|" | sort

    sudo umount "$mnt"
    rm -f "$raw_img"
}

# ---------------------------------------------------------------------------
# Extract file listing from APEX packages inside the system image.
# Each *.apex file is a zip that contains apex_payload.img (an ext4 image).
# Requires Python 3 + zipfile (stdlib).
# ---------------------------------------------------------------------------

list_apex_files() {
    local apex_dir="$1"  # directory containing *.apex files (extracted from system img mount)
    python3 - "$apex_dir" <<'PYEOF'
import sys, os, zipfile, subprocess, tempfile, shutil

apex_dir = sys.argv[1]
if not os.path.isdir(apex_dir):
    sys.exit(0)

for apex_name in sorted(os.listdir(apex_dir)):
    if not apex_name.endswith(".apex") and not apex_name.endswith(".capex"):
        continue
    apex_path = os.path.join(apex_dir, apex_name)
    module = apex_name.replace(".apex", "").replace(".capex", "")
    prefix = f"/apex/{module}"

    tmp = tempfile.mkdtemp()
    try:
        with zipfile.ZipFile(apex_path, 'r') as z:
            # Newer APEXes use apex_payload.img; older use apex.img
            payload = None
            for candidate in ("apex_payload.img", "apex.img"):
                if candidate in z.namelist():
                    payload = candidate
                    break
            if not payload:
                continue
            z.extract(payload, tmp)

        img_path = os.path.join(tmp, payload)

        # Convert sparse if needed
        raw = img_path + ".raw"
        ret = subprocess.run(["simg2img", img_path, raw],
                             capture_output=True)
        if ret.returncode != 0:
            shutil.copy(img_path, raw)

        # List with debugfs
        result = subprocess.run(
            ["debugfs", "-R", "ls -p -r /", raw],
            capture_output=True, text=True)
        for line in result.stdout.splitlines():
            parts = line.split("/")
            if len(parts) >= 6 and parts[5] not in ("", ".", ".."):
                print(f"{prefix}/{parts[5]}")
    except Exception as e:
        print(f"# Warning: could not process {apex_name}: {e}", file=sys.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

# ---------------------------------------------------------------------------
# Also capture vendor.img if present (post-Treble, SDK 26+)
# ---------------------------------------------------------------------------

list_vendor_files() {
    local vendor_img="$1"
    [[ -f "$vendor_img" ]] || return 0

    local raw_img="${vendor_img%.img}_raw.img"
    if command -v simg2img >/dev/null 2>&1; then
        simg2img "$vendor_img" "$raw_img" 2>/dev/null || cp "$vendor_img" "$raw_img"
    else
        cp "$vendor_img" "$raw_img"
    fi

    info "  Listing vendor partition files..."
    debugfs -R 'ls -p -r /' "$raw_img" 2>/dev/null \
        | awk -F/ '$6 != "" && $6 != "." && $6 != ".." { print "/vendor/" $6 }' \
        | sort -u

    rm -f "$raw_img"
}

# ---------------------------------------------------------------------------
# Generate sdk_NN.txt for a given SDK version
# ---------------------------------------------------------------------------

generate_for_sdk() {
    local sdk_ver="$1"
    local out_file="$OUTPUT_DIR/sdk_${sdk_ver}.txt"

    info "=== Generating sdk_${sdk_ver}.txt ==="

    install_image "$sdk_ver"

    local img_dir="$ANDROID_SDK_ROOT/system-images/android-${sdk_ver}/${SDK_VARIANT}/${SDK_ARCH}"
    local system_img="$img_dir/system.img"
    local vendor_img="$img_dir/vendor.img"

    [[ -f "$system_img" ]] || die "system.img not found after install: $system_img"

    {
        # System partition
        if command -v debugfs >/dev/null 2>&1; then
            list_files_debugfs "$system_img"
        else
            # Fall back to mount (requires sudo)
            require_cmd sudo
            list_files_mount "$system_img"
        fi

        # Vendor partition (SDK 26+)
        if [[ "$sdk_ver" -ge 26 ]]; then
            list_vendor_files "$vendor_img"
        fi

        # APEX modules (SDK 29+)
        if [[ "$sdk_ver" -ge 29 ]] && command -v python3 >/dev/null 2>&1 && command -v debugfs >/dev/null 2>&1; then
            info "  Extracting APEX file lists..."
            # Mount system image temporarily to access .apex files
            if command -v sudo >/dev/null 2>&1; then
                local mnt="$WORK_DIR/mnt_apex_$$"
                local raw="$WORK_DIR/system_apex_$$.raw"
                mkdir -p "$mnt"
                simg2img "$system_img" "$raw" 2>/dev/null || cp "$system_img" "$raw"
                sudo mount -o loop,ro "$raw" "$mnt" && {
                    list_apex_files "$mnt/system/apex" 2>/dev/null || true
                    sudo umount "$mnt"
                } || true
                rm -f "$raw"
                rmdir "$mnt" 2>/dev/null || true
            fi
        fi
    } | sort -u > "$out_file"

    local count
    count=$(wc -l < "$out_file")
    info "  Written $count entries → $out_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_cmd unzip

    mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
    setup_sdk_manager

    for ver in "${VERSIONS[@]}"; do
        generate_for_sdk "$ver"
    done

    info "Done. Generated SDK files for: ${VERSIONS[*]}"
}

main "$@"
