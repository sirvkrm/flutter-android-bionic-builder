# Flutter Android Bionic Builder

Minimal wrapper project for building the Flutter engine and Android embedding artifacts against Android bionic with the Android NDK.

This repo does not vendor the full Flutter engine checkout. `build.sh` bootstraps `depot_tools`, fetches the Flutter engine source on first run, applies the local compatibility patches, and then builds the requested Android ABI.

## What it builds

- `libflutter.so`
- `flutter.jar`
- ABI-specific Android jar such as `arm64_v8a_debug.jar`

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

Argument format:

```bash
./build.sh <debug|profile|release> <arm64-v8a|armeabi-v7a|x86|x86_64|all> <y|n>
```

The last flag controls whether Vulkan validation layers are disabled in debug builds for better portability.

## Patches

Stored patches live in `patches/` and are applied automatically to the `src/build` checkout when needed.

## Contact

- GitHub: `@sirvkrm`
- Telegram: `@sirvkrm` (`https://t.me/sirvkrm`)
