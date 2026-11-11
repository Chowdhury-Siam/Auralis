#!/usr/bin/env bash
set -euo pipefail

abi=${1:?Pass arm64-v8a or x86_64}
case "$abi" in
  arm64-v8a|x86_64) ;;
  *) echo "Unsupported Android ABI: $abi" >&2; exit 1 ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
: "${sdk:?Set ANDROID_HOME to the Android SDK directory}"
ndk="$sdk/ndk/28.2.13676358"
cmake="$sdk/cmake/3.22.1/bin/cmake"
version=0.18.0
checksum=28bcd89aa3683fd2a946537e5ce3f11cc46b5cbf3383c7561aaef3df5ff9f1dd
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

archive="$scratch/quickjs.tar.gz"
curl --fail --location --retry 3 --output "$archive" \
  "https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/v$version"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check
tar -xzf "$archive" -C "$scratch"

"$cmake" -S "$scratch/quickjs-$version" -B "$scratch/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$sdk/cmake/3.22.1/bin/ninja" \
  -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$abi" -DANDROID_PLATFORM=24 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DQJS_ENABLE_INSTALL=OFF
"$cmake" --build "$scratch/build" --target qjs_exe --parallel "${JOBS:-2}"
destination="$root/android/app/src/main/jniLibs/$abi"
install -d "$destination"
install -m 0755 "$scratch/build/qjs" "$destination/libqjs.so"
