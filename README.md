# Flutter Android Bionic Builder

Minimal wrapper project for building the Flutter engine, Android embedding artifacts, and a Termux-ready Android-bionic host toolchain bundle with the Android NDK.

This repo does not vendor the full Flutter engine checkout. `build.sh` bootstraps `depot_tools`, fetches the Flutter engine source on first run, applies the local compatibility patches, and then builds either the requested Android ABI or the Termux host bundle overlay.

## What it builds

- `libflutter.so`
- `flutter.jar`
- ABI-specific Android jar such as `arm64_v8a_debug.jar`
- a Termux host bundle tarball that overlays Flutter's `bin/cache` with:
  - Android-bionic `dart-sdk`
  - `font-subset`
  - `const_finder.dart.snapshot`
  - `gen_snapshot` for:
    - `android-arm-profile/android-arm64`
    - `android-arm-release/android-arm64`
    - `android-arm64-profile/android-arm64`
    - `android-arm64-release/android-arm64`
    - `android-x64-profile/android-arm64`
    - `android-x64-release/android-arm64`
- standalone mirror zips in `dist/`:
  - `android-arm-profile-android-arm64.zip`
  - `android-arm-release-android-arm64.zip`
  - `android-arm64-profile-android-arm64.zip`
  - `android-arm64-release-android-arm64.zip`
  - `android-x64-profile-android-arm64.zip`
  - `android-x64-release-android-arm64.zip`
  - `dart-sdk-android-arm64.zip`

The Termux host bundle rewrites the Dart SDK version from prerelease syntax to
stable build-metadata syntax (for example `3.7.0-260.0.dev` becomes
`3.7.0+260.0.dev`) so Flutter's `pub` dependency resolution accepts it.

The current patch set is tuned for Android NDK `r27c` and keeps `libflutter.so` linked only against Android system libraries for broad compatibility.

## Supported ABIs

- `arm64-v8a`
- `armeabi-v7a`
- `x86`
- `x86_64`

## Prerequisites

- `git`
- `python3`
- Android NDK (`ANDROID_NDK_HOME` is preferred)

The script auto-detects these NDK locations:

- `$ANDROID_NDK_HOME`
- `/root/codex-termux/.build-tools/android/android-ndk-r27c`
- Flutter's vendored NDK inside the fetched checkout
- `/data/data/com.termux/files/home/.build-tools/android/android-ndk-r27c`

If `curl` or `wget` is unavailable, the script falls back to `python3` for downloads.

## Usage

Build one ABI:

```bash
./build.sh debug arm64-v8a y
```

Build all Android ABIs:

```bash
./build.sh debug all y
```

Build the Termux host bundle overlay:

```bash
./build.sh termux-sdk
```

Argument format:

```bash
./build.sh <debug|profile|release> <arm64-v8a|armeabi-v7a|x86|x86_64|all> <y|n>
```

The last flag controls whether Vulkan validation layers are disabled in debug builds for better portability.

The Termux host bundle command currently builds the `arm64` host overlay only and writes a tarball into `dist/`.

## Patches

Stored patches live in `patches/` and are applied automatically to the matching engine checkout (`src/` or `src/flutter/`) when needed.

## Contact

- GitHub: `@sirvkrm`
- Telegram: `@sirvkrm` (`https://t.me/sirvkrm`)
