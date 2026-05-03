#!/usr/bin/env bash
# generate_sdk_files.sh — generate emulator_systems/sdk_NN.txt file listings
# from AOSP emulator system images via the Android SDK Manager.
#
# Supports standard phone/tablet images, Android TV (SDK 21+),
# and Google TV (SDK 30+). TV and Google TV files are merged into the
# same sdk_NN.txt so TV-specific AOSP libraries are not falsely flagged
# as proprietary when analyzing blobs from TV devices.
#
# Requirements (Linux):
#   - curl or wget
#   - unzip
#   - e2fsprogs  (debugfs, simg2img)
#   - sudo       (to loop-mount images for APEX extraction)
#   - Python 3   (for APEX extraction on SDK 29+)
#   - Android SDK command-line tools  OR  $ANDROID_SDK_ROOT already set up
#
# Usage:
#   ./tools/generate_sdk_files.sh [SDK_VERSION ...]
#
# Examples:
#   ./tools/generate_sdk_files.sh 27 28 29 30 31 32 33 34 35
#   MERGE_TV=false ./tools/generate_sdk_files.sh 33
#   SDK_VARIANT=default ./tools/generate_sdk_files.sh 28
#
# Environment variables:
#   ANDROID_SDK_ROOT   Existing Android SDK installation path.
#                      If unset, downloads command-line tools to $WORK_DIR.
#   SDK_VARIANT        Base image variant (default: google_apis).
#                      Other options: default, google_apis_playstore
#   SDK_ARCH           Base image architecture (default: x86_64).
#   MERGE_TV           Merge Android TV / Google TV files into each SDK file
#                      (default: true). Set to false to skip TV images.
#   OUTPUT_DIR         Where to write sdk_NN.txt files
#                      (default: emulator_systems/ sibling of this script).
#   WORK_DIR           Scratch space (default: /tmp/abd-sdk-gen).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/emulator_systems}"
WORK_DIR="${WORK_DIR:-/tmp/abd-sdk-gen}"
SDK_VARIANT="${SDK_VARIANT:-google_apis}"
SDK_ARCH="${SDK_ARCH:-x86_64}"
MERGE_TV="${MERGE_TV:-true}"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$WORK_DIR/android-sdk}"
SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

DEFAULT_VERSIONS=(27 28 29 30 31 32 33 34 35)
VERSIONS=("${@:-${DEFAULT_VERSIONS[@]}}")

# ---------------------------------------------------------------------------
# Android TV / Google TV variant matrix
#
# Each entry: "min_sdk:max_sdk:variant:arch"
# Entries are tried in order; the first that sdkmanager can install wins.
# google-tv (SDK 30+) is listed first so it takes priority over android-tv
# on overlapping SDK versions.
# ---------------------------------------------------------------------------
TV_VARIANT_TABLE=(
    "30:99:google-tv:x86"          # Google TV (modern, SDK 30+)
    "21:99:android-tv:x86"         # Android TV (legacy, SDK 21+)
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[generate_sdk_files] $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Install it and retry."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

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
    if have_cmd curl; then
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
# Try to install a specific system image variant.
# Returns 0 on success, 1 if the package is not available.
# ---------------------------------------------------------------------------

try_install_image() {
    local sdk_ver="$1" variant="$2" arch="$3"
    local package="system-images;android-${sdk_ver};${variant};${arch}"
    info "  Trying: $package"
    if yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "$package" 2>&1 \
            | grep -qv "^[[:space:]]*$"; then
        local img_dir="$ANDROID_SDK_ROOT/system-images/android-${sdk_ver}/${variant}/${arch}"
        [[ -f "$img_dir/system.img" ]]
    else
        return 1
    fi
}

install_image() {
    local sdk_ver="$1" variant="$2" arch="$3"
    local package="system-images;android-${sdk_ver};${variant};${arch}"
    info "Installing: $package"
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "$package" 2>&1 \
        | grep -v "^[[:space:]]*$" || true
}

# ---------------------------------------------------------------------------
# Convert sparse Android image to raw ext4 in-place (if needed).
# Outputs the path to the raw image (caller must clean it up).
# ---------------------------------------------------------------------------

to_raw_img() {
    local img="$1"
    local raw="${img%.img}_$$.raw"

    # Use 'file' for reliable format detection (qemu-img reports "raw" for
    # Android sparse images and therefore can't distinguish them from real raw).
    local magic=""
    have_cmd file && magic=$(file -b "$img" 2>/dev/null)

    # Android sparse ext4 → raw ext4  (most common format from sdkmanager)
    if [[ "$magic" == *"Android sparse image"* ]]; then
        info "    Android sparse detected: $(basename "$img")"
        if have_cmd simg2img && simg2img "$img" "$raw" 2>/dev/null; then
            echo "$raw"; return 0
        fi
        warn "simg2img not available or failed for $(basename "$img") — mount will likely fail"
        cp "$img" "$raw"; echo "$raw"; return 0
    fi

    # QCOW2 → raw ext4
    if have_cmd qemu-img; then
        local fmt
        fmt=$(qemu-img info "$img" 2>/dev/null | awk '/^file format:/{print $3}')
        if [[ "$fmt" == "qcow2" || "$fmt" == "qcow" ]]; then
            info "    Converting $fmt → raw: $(basename "$img")"
            if qemu-img convert -O raw -S 4k "$img" "$raw" 2>/dev/null; then
                echo "$raw"; return 0
            fi
            warn "qemu-img convert failed for $(basename "$img"); falling through"
        fi
    fi

    # Raw ext4 / erofs / unknown — use as-is
    cp "$img" "$raw"
    echo "$raw"
}

# ---------------------------------------------------------------------------
# List all files inside an ext4 image using debugfs (no root required).
# Outputs one path per line, each prefixed with $prefix.
#
# The debugfs 'ls -p -r' parseable format is:
#   /inode/type/size/mode/uid/gid/name/
# Use $(NF-1) for the name — the trailing slash makes $NF always empty.
# ---------------------------------------------------------------------------

list_img_debugfs() {
    local img="$1" prefix="$2"
    local raw
    raw="$(to_raw_img "$img")"

    # ls -p: parseable format  ls -r: recursive (e2fsprogs >= 1.46)
    # Format per line: /dir_inode/file_type/size/mode/uid/gid/name/
    # $(NF-1) is the name regardless of exact field count — $NF is always
    # the empty string after the trailing slash.
    debugfs -R 'ls -p -r /' "$raw" 2>/dev/null \
        | awk -F'/' -v p="$prefix" \
              'NF>=8 { n=$(NF-1); if (n!="" && n!="." && n!="..") print p "/" n }' \
        | sort -u

    rm -f "$raw"
}

# ---------------------------------------------------------------------------
# List all files inside an ext4 image by loop-mounting it (requires sudo).
# Outputs one path per line, each prefixed with $prefix.
# ---------------------------------------------------------------------------

list_img_mount() {
    local img="$1" prefix="$2"
    local raw mnt
    raw="$(to_raw_img "$img")"
    mnt="$WORK_DIR/mnt_$$"
    mkdir -p "$mnt"

    # Try ext4 first, then erofs (Android 11+ system partitions), then auto.
    local mounted=false fstype
    for fstype in ext4 erofs ""; do
        local opts="-o loop,ro"
        [[ -n "$fstype" ]] && opts="-t $fstype $opts"
        # shellcheck disable=SC2086
        if sudo mount $opts "$raw" "$mnt" 2>/dev/null; then
            mounted=true; break
        fi
    done

    if $mounted; then
        find "$mnt" \( -type f -o -type l \) | sed "s|$mnt|$prefix|" | sort
        sudo umount "$mnt"
    else
        warn "All mount attempts failed for $(basename "$img") — check image format"
    fi

    rmdir "$mnt" 2>/dev/null || true
    rm -f "$raw"
}

# ---------------------------------------------------------------------------
# Generic: list files from an image, trying debugfs first, then mount.
# ---------------------------------------------------------------------------

list_image_files() {
    local img="$1" prefix="$2"

    if ! [[ -f "$img" ]]; then
        warn "Image not found, skipping: $img"
        return 0
    fi

    # Loop-mount + find is the only approach that yields complete recursive
    # paths.  debugfs 'ls -r' means "raw format", not "recursive" — it only
    # lists immediate children of /, giving ~1 KB of top-level entries.
    if have_cmd sudo; then
        list_img_mount "$img" "$prefix"
        return $?
    fi

    # No sudo: fall back to debugfs for top-level-only partial listing.
    if have_cmd debugfs; then
        warn "No sudo — debugfs will only list top-level entries of $(basename "$img")"
        list_img_debugfs "$img" "$prefix"
    else
        warn "Neither sudo nor debugfs available — cannot list $(basename "$img")"
    fi
}

# ---------------------------------------------------------------------------
# Extract file listings from APEX packages inside a mounted system directory.
# Each *.apex / *.capex is a zip containing apex_payload.img (ext4).
# Requires Python 3, debugfs, simg2img.
# ---------------------------------------------------------------------------

list_apex_files() {
    local apex_dir="$1"
    [[ -d "$apex_dir" ]] || return 0
    have_cmd python3   || return 0
    have_cmd debugfs   || return 0

    python3 - "$apex_dir" <<'PYEOF'
import sys, os, zipfile, subprocess, tempfile, shutil

apex_dir = sys.argv[1]

for apex_name in sorted(os.listdir(apex_dir)):
    if not (apex_name.endswith(".apex") or apex_name.endswith(".capex")):
        continue
    apex_path = os.path.join(apex_dir, apex_name)
    module = apex_name.replace(".capex", "").replace(".apex", "")
    prefix = f"/apex/{module}"

    tmp = tempfile.mkdtemp()
    try:
        with zipfile.ZipFile(apex_path, 'r') as z:
            payload = next(
                (c for c in ("apex_payload.img", "apex.img") if c in z.namelist()),
                None)
            if not payload:
                continue
            z.extract(payload, tmp)

        raw = os.path.join(tmp, "payload.raw")
        ret = subprocess.run(["simg2img", os.path.join(tmp, payload), raw],
                             capture_output=True)
        if ret.returncode != 0:
            shutil.copy(os.path.join(tmp, payload), raw)

        result = subprocess.run(
            ["debugfs", "-R", "ls -p -r /", raw],
            capture_output=True, text=True)
        for line in result.stdout.splitlines():
            parts = line.split("/")
            if len(parts) >= 9 and parts[8] not in ("", ".", ".."):
                print(f"{prefix}/{parts[8]}")
    except Exception as e:
        print(f"# Warning: could not process {apex_name}: {e}", file=sys.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

# ---------------------------------------------------------------------------
# Collect all files for one image variant (system + vendor + APEX)
# and append them to the given output file.
# ---------------------------------------------------------------------------

collect_variant_files() {
    local sdk_ver="$1" variant="$2" arch="$3" out_file="$4"
    local img_dir="$ANDROID_SDK_ROOT/system-images/android-${sdk_ver}/${variant}/${arch}"
    local system_img="$img_dir/system.img"
    local vendor_img="$img_dir/vendor.img"

    [[ -f "$system_img" ]] || { warn "system.img not found: $system_img"; return 1; }

    info "  Collecting files from ${variant}/${arch}..."

    # System partition
    list_image_files "$system_img" "/system" >> "$out_file"

    # Vendor partition (post-Treble, SDK 26+)
    if [[ "$sdk_ver" -ge 26 ]] && [[ -f "$vendor_img" ]]; then
        list_image_files "$vendor_img" "/vendor" >> "$out_file"
    fi

    # APEX modules (SDK 29+) — requires mounting to access .apex files
    if [[ "$sdk_ver" -ge 29 ]] && have_cmd sudo && have_cmd python3 && have_cmd debugfs; then
        local raw mnt
        raw="$(to_raw_img "$system_img")"
        mnt="$WORK_DIR/mnt_apex_$$"
        mkdir -p "$mnt"
        if sudo mount -o loop,ro "$raw" "$mnt" 2>/dev/null; then
            local apex_subdir
            for apex_subdir in "$mnt/system/apex" "$mnt/apex"; do
                list_apex_files "$apex_subdir" >> "$out_file" 2>/dev/null || true
            done
            sudo umount "$mnt"
        else
            warn "Could not mount $raw for APEX extraction (skipping APEX for ${variant}/${arch})"
        fi
        rmdir "$mnt" 2>/dev/null || true
        rm -f "$raw"
    fi
}

# ---------------------------------------------------------------------------
# Determine which TV variants to try for a given SDK version.
# Prints "variant:arch" pairs, one per line.
# ---------------------------------------------------------------------------

tv_variants_for_sdk() {
    local sdk_ver="$1"
    local min max variant arch

    for entry in "${TV_VARIANT_TABLE[@]}"; do
        IFS=: read -r min max variant arch <<< "$entry"
        if [[ "$sdk_ver" -ge "$min" && "$sdk_ver" -le "$max" ]]; then
            echo "${variant}:${arch}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Generate sdk_NN.txt for a given SDK version.
# Merges: base variant + Android TV + Google TV (if available and MERGE_TV=true)
# ---------------------------------------------------------------------------

generate_for_sdk() {
    local sdk_ver="$1"
    local out_file="$OUTPUT_DIR/sdk_${sdk_ver}.txt"
    local tmp_file
    tmp_file="$(mktemp "$WORK_DIR/sdk_${sdk_ver}_XXXXXX.tmp")"

    info "=== Generating sdk_${sdk_ver}.txt ==="

    # ---- Base variant (phone/tablet) ----
    # Some older SDKs (e.g. 27, 28) were only published for x86, not x86_64.
    # Try SDK_ARCH first; if system.img is absent after install, fall back to x86.
    local base_arch="" arch_candidates=("$SDK_ARCH")
    [[ "$SDK_ARCH" != "x86" ]] && arch_candidates+=("x86")

    local try_arch
    for try_arch in "${arch_candidates[@]}"; do
        [[ "$try_arch" == "$SDK_ARCH" ]] \
            || info "  $SDK_ARCH not available for SDK $sdk_ver — trying $try_arch"
        install_image "$sdk_ver" "$SDK_VARIANT" "$try_arch"
        local img_dir="$ANDROID_SDK_ROOT/system-images/android-${sdk_ver}/${SDK_VARIANT}/${try_arch}"
        if [[ -f "$img_dir/system.img" ]]; then
            base_arch="$try_arch"
            break
        fi
        warn "system.img not found after install (${SDK_VARIANT}/${try_arch})"
    done

    [[ -n "$base_arch" ]] \
        || die "Failed to install base image for SDK $sdk_ver (tried: ${arch_candidates[*]})"

    collect_variant_files "$sdk_ver" "$SDK_VARIANT" "$base_arch" "$tmp_file" \
        || die "Failed to collect base image files for SDK $sdk_ver"

    # ---- TV / Google TV variants ----
    if [[ "$MERGE_TV" == "true" ]]; then
        local seen_variants=()
        while IFS=: read -r tv_variant tv_arch; do
            # Avoid re-downloading if same variant/arch already processed
            local key="${tv_variant}:${tv_arch}"
            local already_seen=false
            for v in "${seen_variants[@]:-}"; do
                [[ "$v" == "$key" ]] && already_seen=true && break
            done
            $already_seen && continue
            seen_variants+=("$key")

            info "  Trying TV variant: ${tv_variant}/${tv_arch} for SDK ${sdk_ver}..."
            if try_install_image "$sdk_ver" "$tv_variant" "$tv_arch"; then
                collect_variant_files "$sdk_ver" "$tv_variant" "$tv_arch" "$tmp_file" || true
            else
                info "  Not available: ${tv_variant}/${tv_arch} for SDK ${sdk_ver} (skipping)"
            fi
        done < <(tv_variants_for_sdk "$sdk_ver")
    fi

    # ---- Deduplicate and write final output ----
    sort -u "$tmp_file" > "$out_file"
    rm -f "$tmp_file"

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
    [[ "$MERGE_TV" == "true" ]] && info "(Android TV + Google TV merged in)"
}

main "$@"
