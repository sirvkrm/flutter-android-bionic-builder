#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE_DIR=$SCRIPT_DIR
SRC_DIR="$WORKSPACE_DIR/src"
SRC_REPO_DIR="$SRC_DIR"
BUILD_REPO_DIR="$SRC_DIR/build"
ENGINE_DIR="$SRC_DIR/flutter"
PATCH_DIR="$WORKSPACE_DIR/patches"
LOCAL_BIN_DIR="$WORKSPACE_DIR/bin"
DEPOT_TOOLS_DIR="$WORKSPACE_DIR/depot_tools"
GN_TOOL="$SRC_DIR/flutter/tools/gn"
NINJA_BIN="$SRC_DIR/flutter/third_party/ninja/ninja"
DEPOT_TOOLS_REPO="https://chromium.googlesource.com/chromium/tools/depot_tools.git"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

ensure_git_exec_path() {
  if ! command -v git >/dev/null 2>&1; then
    die "git is required"
  fi

  if [[ -n "${GIT_EXEC_PATH:-}" && -d "${GIT_EXEC_PATH}" ]]; then
    return
  fi

  local current_exec_path
  current_exec_path=$(git --exec-path 2>/dev/null || true)
  if [[ -n "$current_exec_path" && -d "$current_exec_path" ]]; then
    export GIT_EXEC_PATH="$current_exec_path"
    return
  fi

  if [[ -d /snap/codex/21/usr/lib/git-core ]]; then
    export GIT_EXEC_PATH=/snap/codex/21/usr/lib/git-core
    return
  fi

  die "unable to locate a valid git exec path"
}

prepare_path() {
  export PATH="$LOCAL_BIN_DIR:$DEPOT_TOOLS_DIR:$PATH"
}

download_to() {
  local url=$1
  local dest=$2

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --output "$dest" "$url"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
    return 0
  fi

  local python_bin
  python_bin=$(command -v python3 2>/dev/null || true)
  [[ -n "$python_bin" ]] || die "need curl, wget, or python3 to download $url"

  "$python_bin" - "$url" "$dest" <<'PY'
import pathlib
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
path = pathlib.Path(dest)
path.parent.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(url) as response:
    path.write_bytes(response.read())
PY
}

detect_cipd_platform() {
  local os_name
  local machine
  os_name=$(uname -s)
  machine=$(uname -m)

  case "$os_name:$machine" in
    Linux:x86_64|Linux:amd64)
      printf 'linux-amd64\n'
      ;;
    Linux:aarch64|Linux:arm64)
      printf 'linux-arm64\n'
      ;;
    Darwin:x86_64)
      printf 'mac-amd64\n'
      ;;
    Darwin:arm64)
      printf 'mac-arm64\n'
      ;;
    *)
      die "unsupported host for CIPD bootstrap: $os_name $machine"
      ;;
  esac
}

ensure_depot_tools() {
  if [[ ! -x "$DEPOT_TOOLS_DIR/fetch" ]]; then
    note "Cloning depot_tools into $DEPOT_TOOLS_DIR"
    git clone "$DEPOT_TOOLS_REPO" "$DEPOT_TOOLS_DIR"
  fi

  if [[ -x "$DEPOT_TOOLS_DIR/.cipd_client" ]]; then
    return 0
  fi

  local version_file="$DEPOT_TOOLS_DIR/cipd_client_version"
  [[ -f "$version_file" ]] || die "missing depot_tools cipd_client_version"

  local cipd_version
  cipd_version=$(<"$version_file")
  local cipd_platform
  cipd_platform=$(detect_cipd_platform)
  local cipd_url="https://chrome-infra-packages.appspot.com/client?platform=$cipd_platform&version=$cipd_version"

  note "Bootstrapping depot_tools CIPD client"
  download_to "$cipd_url" "$DEPOT_TOOLS_DIR/.cipd_client"
  chmod +x "$DEPOT_TOOLS_DIR/.cipd_client"
}

run_gclient_cmd() {
  (
    cd "$WORKSPACE_DIR"
    export DEPOT_TOOLS_UPDATE=0
    export DEPOT_TOOLS_METRICS=0
    "$@"
  )
}

ensure_flutter_checkout() {
  local needs_hooks=0

  if [[ ! -d "$SRC_DIR" ]]; then
    if [[ -f "$WORKSPACE_DIR/.gclient" ]]; then
      note "Syncing existing gclient checkout into $SRC_DIR"
      run_gclient_cmd gclient sync
    else
      note "Fetching Flutter engine source into $SRC_DIR"
      run_gclient_cmd fetch --no-history flutter
    fi
    needs_hooks=1
  fi

  if [[ ! -f "$GN_TOOL" || ! -x "$NINJA_BIN" ]]; then
    note "Syncing Flutter checkout"
    run_gclient_cmd gclient sync
    needs_hooks=1
  fi

  if [[ "$needs_hooks" == "1" || "${RUN_HOOKS:-0}" == "1" ]]; then
    note "Running gclient hooks"
    run_gclient_cmd gclient runhooks
  fi

  [[ -f "$GN_TOOL" ]] || die "missing $GN_TOOL after checkout bootstrap"
  [[ -x "$NINJA_BIN" ]] || die "missing $NINJA_BIN after checkout bootstrap"
}

patch_first_path() {
  local patch_file=$1
  sed -n 's|^diff --git a/\([^[:space:]]\+\) b/.*$|\1|p;q' "$patch_file"
}

detect_patch_repo() {
  local patch_file=$1
  local first_path=""

  first_path=$(patch_first_path "$patch_file" || true)

  if [[ -n "$first_path" && -e "$SRC_REPO_DIR/$first_path" ]]; then
    printf '%s\n' "$SRC_REPO_DIR"
    return 0
  fi

  if [[ -n "$first_path" && -e "$ENGINE_DIR/$first_path" ]]; then
    printf '%s\n' "$ENGINE_DIR"
    return 0
  fi

  if git -C "$SRC_REPO_DIR" apply --check "$patch_file" >/dev/null 2>&1 ||
    git -C "$SRC_REPO_DIR" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    printf '%s\n' "$SRC_REPO_DIR"
    return 0
  fi

  if git -C "$ENGINE_DIR" apply --check "$patch_file" >/dev/null 2>&1 ||
    git -C "$ENGINE_DIR" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    printf '%s\n' "$ENGINE_DIR"
    return 0
  fi

  return 1
}

apply_patch_if_needed() {
  local patch_file=$1
  local repo_dir=""

  [[ -f "$patch_file" ]] || return 0

  if ! repo_dir=$(detect_patch_repo "$patch_file"); then
    note "Skipping $(basename "$patch_file") (no matching checkout found)"
    return 0
  fi

  if git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "$repo_dir" apply --check "$patch_file" >/dev/null 2>&1; then
    note "Applying $(basename "$patch_file") in $(basename "$repo_dir")"
    git -C "$repo_dir" apply "$patch_file"
    return 0
  fi

  note "Skipping $(basename "$patch_file") (already diverged or manually applied)"
}

apply_workspace_patches() {
  shopt -s nullglob
  local patch
  for patch in "$PATCH_DIR"/*.patch; do
    apply_patch_if_needed "$patch"
  done
  shopt -u nullglob
}

detect_native_clang() {
  command -v clang 2>/dev/null || true
}

detect_llvm_readelf() {
  local candidate
  candidate=$(find "$SRC_DIR/flutter/buildtools" -path '*/clang/bin/llvm-readelf' -print -quit)
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

detect_ndk() {
  local candidates=()

  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    candidates+=("$ANDROID_NDK_HOME")
  fi

  candidates+=(
    "/root/codex-termux/.build-tools/android/android-ndk-r27c"
    "$ENGINE_DIR/third_party/android_tools/ndk"
    "/data/data/com.termux/files/home/.build-tools/android/android-ndk-r27c"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -d "$candidate/toolchains/llvm/prebuilt" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

detect_ndk_host_tag() {
  local os_name
  local machine
  os_name=$(uname -s)
  machine=$(uname -m)

  case "$os_name:$machine" in
    Linux:x86_64|Linux:amd64)
      printf 'linux-x86_64\n'
      ;;
    Linux:aarch64|Linux:arm64)
      printf 'linux-aarch64\n'
      ;;
    Darwin:x86_64)
      printf 'darwin-x86_64\n'
      ;;
    Darwin:arm64)
      printf 'darwin-arm64\n'
      ;;
    *)
      die "unsupported host for NDK prebuilts: $os_name $machine"
      ;;
  esac
}

detect_ndk_clang_version() {
  local ndk_root=$1
  local host_tag=$2
  local clang_root="$ndk_root/toolchains/llvm/prebuilt/$host_tag/lib/clang"

  [[ -d "$clang_root" ]] || die "missing clang resource dir: $clang_root"

  local version
  version=$(find "$clang_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)
  [[ -n "$version" ]] || die "unable to detect NDK clang version in $clang_root"

  printf '%s\n' "$version"
}

prompt_with_default() {
  local __var_name=$1
  local prompt_text=$2
  local default_value=$3
  local reply

  if [[ -t 0 ]]; then
    read -r -p "$prompt_text [$default_value]: " reply || true
    reply=${reply:-$default_value}
  else
    reply=$default_value
  fi

  printf -v "$__var_name" '%s' "$reply"
}

normalize_mode() {
  case "${1,,}" in
    debug|d)
      printf 'debug\n'
      ;;
    profile|p)
      printf 'profile\n'
      ;;
    release|r)
      printf 'release\n'
      ;;
    *)
      die "unsupported mode: $1"
      ;;
  esac
}

normalize_abi() {
  case "${1,,}" in
    all)
      printf 'all\n'
      ;;
    arm64|arm64-v8a|aarch64)
      printf 'arm64-v8a\n'
      ;;
    arm|armeabi-v7a|armeabi)
      printf 'armeabi-v7a\n'
      ;;
    x86|i686)
      printf 'x86\n'
      ;;
    x64|x86_64)
      printf 'x86_64\n'
      ;;
    *)
      die "unsupported ABI: $1"
      ;;
  esac
}

abi_to_cpu() {
  case "$1" in
    arm64-v8a)
      printf 'arm64\n'
      ;;
    armeabi-v7a)
      printf 'arm\n'
      ;;
    x86)
      printf 'x86\n'
      ;;
    x86_64)
      printf 'x64\n'
      ;;
    *)
      die "unsupported ABI: $1"
      ;;
  esac
}

out_dir_for() {
  local mode=$1
  local cpu=$2
  local suffix="android_${mode}"

  if [[ "$mode" == "debug" ]]; then
    suffix+="_unopt"
  fi

  if [[ "$cpu" != "arm" ]]; then
    suffix+="_${cpu}"
  fi

  printf '%s\n' "$SRC_DIR/out/$suffix"
}

release_stamp() {
  if [[ -n "${RELEASE_STAMP:-}" ]]; then
    printf '%s\n' "$RELEASE_STAMP"
    return 0
  fi

  date -u +%Y%m%d
}

termux_host_out_dir() {
  printf '%s\n' "$SRC_DIR/out/android_debug_unopt_arm64_termuxsdk"
}

find_termux_font_subset() {
  local out_dir=$1
  local candidate

  for candidate in "$out_dir/font-subset" "$out_dir/exe.stripped/font-subset"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

find_termux_const_finder() {
  local out_dir=$1
  local candidate

  candidate=$(find "$out_dir" -type f -name const_finder.dart.snapshot -print -quit)
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

normalize_dart_sdk_semver() {
  local cache_root=$1
  local version_file="$cache_root/dart-sdk/version"
  local current_version=""
  local normalized_version=""

  [[ -f "$version_file" ]] || return 0
  current_version=$(tr -d '\r\n' < "$version_file")

  if [[ "$current_version" != *-* || "$current_version" == *+* ]]; then
    return 0
  fi

  normalized_version="${current_version/-/+}"
  note "Normalizing Dart SDK version: $current_version -> $normalized_version"

  python3 - "$cache_root" "$current_version" "$normalized_version" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
old = sys.argv[2].encode()
new = sys.argv[3].encode()
changed = 0

for path in root.rglob('*'):
    if not path.is_file():
        continue
    data = path.read_bytes()
    if old not in data:
        continue
    path.write_bytes(data.replace(old, new))
    changed += 1

print(f"Patched {changed} files under {root}")
PY
}

package_termux_host_bundle() {
  local out_dir=$1
  local bundle_stamp
  bundle_stamp=$(release_stamp)
  local bundle_name="flutter-android-bionic-termux-host-arm64-$bundle_stamp"
  local stage_dir="$WORKSPACE_DIR/out/$bundle_name"
  local archive_path="$WORKSPACE_DIR/dist/$bundle_name.tar.gz"
  local overlay_root="$stage_dir/overlay"
  local cache_root="$overlay_root/bin/cache"
  local engine_root="$cache_root/artifacts/engine"
  local host_engine_dir="$engine_root/linux-arm64"
  local -a host_gen_snapshot_dirs=(
    "$engine_root/android-arm-profile/linux-arm64"
    "$engine_root/android-arm-release/linux-arm64"
    "$engine_root/android-arm64-profile/linux-arm64"
    "$engine_root/android-arm64-release/linux-arm64"
    "$engine_root/android-x64-profile/linux-arm64"
    "$engine_root/android-x64-release/linux-arm64"
  )
  local dart_sdk_dir="$out_dir/dart-sdk"
  local gen_snapshot_src="$dart_sdk_dir/bin/utils/gen_snapshot"
  local font_subset_src=""
  local const_finder_src=""

  [[ -d "$dart_sdk_dir" ]] || die "missing Dart SDK output: $dart_sdk_dir"
  [[ -f "$gen_snapshot_src" ]] || die "missing Termux gen_snapshot: $gen_snapshot_src"

  font_subset_src=$(find_termux_font_subset "$out_dir") ||
    die "missing font-subset output in $out_dir"
  const_finder_src=$(find_termux_const_finder "$out_dir") ||
    die "missing const_finder.dart.snapshot output in $out_dir"

  rm -rf "$stage_dir"
  mkdir -p "$cache_root" "$host_engine_dir" "$WORKSPACE_DIR/dist"
  local dir
  for dir in "${host_gen_snapshot_dirs[@]}"; do
    mkdir -p "$dir"
  done

  cp -a "$dart_sdk_dir" "$cache_root/"
  cp -a "$font_subset_src" "$host_engine_dir/font-subset"
  cp -a "$const_finder_src" "$host_engine_dir/const_finder.dart.snapshot"
  cp -a "$gen_snapshot_src" "$host_engine_dir/gen_snapshot"
  for dir in "${host_gen_snapshot_dirs[@]}"; do
    cp -a "$gen_snapshot_src" "$dir/gen_snapshot"
  done

  if [[ -f "$out_dir/gen_snapshot_product" ]]; then
    cp -a "$out_dir/gen_snapshot_product" "$host_engine_dir/gen_snapshot_product"
    for dir in "${host_gen_snapshot_dirs[@]}"; do
      cp -a "$out_dir/gen_snapshot_product" "$dir/gen_snapshot_product"
    done
  fi

  normalize_dart_sdk_semver "$cache_root"

  cat >"$stage_dir/README.md" <<EOF
# Flutter Android Bionic Termux Host Bundle

This archive overlays the Flutter SDK cache with Android-bionic host tools for
Termux-style environments.

Files provided:

- bin/cache/dart-sdk
- bin/cache/artifacts/engine/linux-arm64/font-subset
- bin/cache/artifacts/engine/linux-arm64/const_finder.dart.snapshot
- bin/cache/artifacts/engine/linux-arm64/gen_snapshot
- bin/cache/artifacts/engine/android-*-{profile,release}/linux-arm64/gen_snapshot

Copy the contents of overlay/ on top of a Flutter SDK checkout after applying
the Termux host compatibility patch in the installer repo.
EOF

  tar -czf "$archive_path" -C "$WORKSPACE_DIR/out" "$bundle_name"

  note ""
  note "Built Termux host bundle:"
  note "  $archive_path"
  note "Overlay root:"
  note "  $overlay_root"
}

build_termux_host_bundle() {
  local ndk_root=$1
  local ndk_clang_version=$2
  local out_dir
  out_dir=$(termux_host_out_dir)
  local target_dir
  target_dir=$(basename "$out_dir")

  local gn_cmd=(
    "$GN_TOOL"
    --android
    --android-cpu arm64
    --runtime-mode debug
    --unoptimized
    --no-prebuilt-dart-sdk
    --disable-desktop-embeddings
    --target-dir "$target_dir"
    "--gn-args=android_ndk_root=\"$ndk_root\""
    "--gn-args=android_toolchain_clang_version=\"$ndk_clang_version\""
    "--gn-args=flutter_build_engine_artifacts_for_android=true"
    "--gn-args=enable_vulkan_validation_layers=false"
    "--gn-args=impeller_enable_vulkan_validation_layers=false"
  )

  note ""
  note "Generating Termux host SDK in $target_dir"
  (
    cd "$SRC_DIR"
    "${gn_cmd[@]}"
  )

  note "Building Termux host tools: dart_sdk_archive, font-subset, const_finder"
  (
    cd "$SRC_DIR"
    "$NINJA_BIN" -C "${out_dir#$SRC_DIR/}" dart_sdk_archive font-subset \
      flutter/tools/const_finder:const_finder
  )

  package_termux_host_bundle "$out_dir"

  local llvm_readelf=""
  llvm_readelf=$(detect_llvm_readelf || true)
  if [[ -n "$llvm_readelf" && -f "$out_dir/dart-sdk/bin/dart" ]]; then
    note ""
    note "dart-sdk/bin/dart NEEDED entries:"
    "$llvm_readelf" -d "$out_dir/dart-sdk/bin/dart" | sed -n '1,120p' | grep 'Shared library' || true
  fi
}

build_one() {
  local mode=$1
  local abi=$2
  local ndk_root=$3
  local ndk_clang_version=$4
  local portable_debug=$5

  local cpu
  cpu=$(abi_to_cpu "$abi")

  local out_dir
  out_dir=$(out_dir_for "$mode" "$cpu")

  local gn_cmd=(
    "$GN_TOOL"
    --android
    --android-cpu "$cpu"
    --runtime-mode "$mode"
    "--gn-args=android_ndk_root=\"$ndk_root\""
    "--gn-args=android_toolchain_clang_version=\"$ndk_clang_version\""
  )

  if [[ "$mode" == "debug" ]]; then
    gn_cmd+=(--unoptimized)
    if [[ "$portable_debug" == "1" ]]; then
      gn_cmd+=(
        "--gn-args=enable_vulkan_validation_layers=false"
        "--gn-args=impeller_enable_vulkan_validation_layers=false"
      )
    fi
  elif [[ "${NO_LTO:-1}" == "1" ]]; then
    gn_cmd+=(--no-lto)
  fi

  note ""
  note "Generating $abi ($mode) in $(basename "$out_dir")"
  (
    cd "$SRC_DIR"
    "${gn_cmd[@]}"
  )

  note "Building flutter/shell/platform/android:android_jar"
  (
    cd "$SRC_DIR"
    "$NINJA_BIN" -C "${out_dir#$SRC_DIR/}" flutter/shell/platform/android:android_jar
  )

  local libflutter="$out_dir/libflutter.so"
  local flutter_jar="$out_dir/flutter.jar"
  local abi_jar_name
  abi_jar_name=$(printf '%s_%s.jar' "${abi//-/_}" "$mode")
  local abi_jar="$out_dir/$abi_jar_name"
  local host_snapshot=""
  host_snapshot=$(find "$out_dir" -maxdepth 2 -type f -name gen_snapshot -print -quit)
  local llvm_readelf=""
  llvm_readelf=$(detect_llvm_readelf || true)

  note ""
  note "Built artifacts for $abi ($mode):"
  note "  $libflutter"
  note "  $flutter_jar"
  if [[ -f "$abi_jar" ]]; then
    note "  $abi_jar"
  fi
  if [[ -f "$host_snapshot" ]]; then
    note "  $host_snapshot"
  fi

  if [[ -n "$llvm_readelf" && -f "$libflutter" ]]; then
    note ""
    note "libflutter.so NEEDED entries:"
    "$llvm_readelf" -d "$libflutter" | sed -n '1,120p' | grep 'Shared library' || true
  fi
}

main() {
  ensure_git_exec_path
  prepare_path
  ensure_depot_tools
  ensure_flutter_checkout
  apply_workspace_patches

  local native_clang
  native_clang=$(detect_native_clang)
  if [[ -n "$native_clang" ]]; then
    note "Detected native clang: $native_clang"
  fi

  local ndk_root
  if ! ndk_root=$(detect_ndk); then
    if [[ -n "$native_clang" ]]; then
      die "found native clang but no Android NDK; set ANDROID_NDK_HOME or install an NDK-style toolchain"
    fi
    die "no Android NDK found; set ANDROID_NDK_HOME"
  fi
  export ANDROID_NDK_HOME="$ndk_root"

  local host_tag
  host_tag=$(detect_ndk_host_tag)
  local ndk_clang_version
  ndk_clang_version=$(detect_ndk_clang_version "$ndk_root" "$host_tag")

  local command_input=${1:-}
  case "${command_input,,}" in
    termux-sdk|host-sdk|termux-host)
      local host_abi_input=${2:-${TARGET_ABI:-arm64-v8a}}
      local host_abi
      host_abi=$(normalize_abi "$host_abi_input")
      [[ "$host_abi" == "arm64-v8a" ]] ||
        die "Termux host bundle is currently only supported for arm64-v8a"
      note "Using Android NDK: $ndk_root"
      note "NDK clang runtime version: $ndk_clang_version"
      build_termux_host_bundle "$ndk_root" "$ndk_clang_version"
      return 0
      ;;
  esac

  local mode_input abi_input portable_input
  mode_input=${1:-${BUILD_MODE:-}}
  abi_input=${2:-${TARGET_ABI:-}}
  portable_input=${3:-${PORTABLE_DEBUG:-}}

  if [[ -z "$mode_input" ]]; then
    prompt_with_default mode_input "Build mode (debug/profile/release)" "debug"
  fi
  if [[ -z "$abi_input" ]]; then
    prompt_with_default abi_input "ABI (arm64-v8a/armeabi-v7a/x86/x86_64/all)" "arm64-v8a"
  fi
  if [[ -z "$portable_input" ]]; then
    prompt_with_default portable_input "Disable Android Vulkan validation layers in debug builds? (y/n)" "y"
  fi

  local mode
  mode=$(normalize_mode "$mode_input")
  local abi
  abi=$(normalize_abi "$abi_input")

  local portable_debug=0
  case "${portable_input,,}" in
    y|yes|1|true)
      portable_debug=1
      ;;
    n|no|0|false)
      portable_debug=0
      ;;
    *)
      die "unsupported portable flag: $portable_input"
      ;;
  esac

  note "Using Android NDK: $ndk_root"
  note "NDK clang runtime version: $ndk_clang_version"

  local targets=()
  if [[ "$abi" == "all" ]]; then
    targets=(arm64-v8a armeabi-v7a x86 x86_64)
  else
    targets=("$abi")
  fi

  local target_abi
  for target_abi in "${targets[@]}"; do
    build_one "$mode" "$target_abi" "$ndk_root" "$ndk_clang_version" "$portable_debug"
  done
}

main "$@"
