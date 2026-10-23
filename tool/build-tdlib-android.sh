#!/usr/bin/env bash
set -euo pipefail
# ARM64 phones by default; x86_64 is available for emulator/device testing.
ABI=${1:-arm64-v8a}
case "$ABI" in
  arm64-v8a) OPENSSL_TARGET=android-arm64; TRIPLE=aarch64-linux-android ;;
  x86_64) OPENSSL_TARGET=android-x86_64; TRIPLE=x86_64-linux-android ;;
  *) echo 'Use arm64-v8a or x86_64.' >&2; exit 1 ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.native-build/android"
NDK_VERSION=28.2.13676358
TD_REVISION=a94b83d67ab4c8397c6245e541b31a4131ea2f79
OPENSSL_REVISION=c1eeb9406b6142148f267594197d853403d10208 # OpenSSL 3.5.4
JOBS=${JOBS:-2}
export ANDROID_NDK_ROOT="${ANDROID_HOME:?Set ANDROID_HOME to your SDK}/ndk/$NDK_VERSION"
TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"
test -f "$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake"
mkdir -p "$WORK"

pinned_repository() {
  local url=$1 revision=$2 destination=$3
  if [ ! -d "$destination/.git" ]; then
    git init "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach FETCH_HEAD
  fi
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
}
pinned_repository https://github.com/tdlib/td.git "$TD_REVISION" "$WORK/td"
pinned_repository https://github.com/openssl/openssl.git "$OPENSSL_REVISION" "$WORK/openssl"

# Generate schemas with host executables before cross-compiling Android binaries.
cmake -S "$WORK/td" -B "$WORK/host" -G Ninja -DTD_GENERATE_SOURCE_FILES=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK/host" --target prepare_cross_compiling --parallel "$JOBS"

OPENSSL_PREFIX="$WORK/openssl-install-$ABI"
mkdir -p "$WORK/openssl-build-$ABI"
(
  cd "$WORK/openssl-build-$ABI"
  "$WORK/openssl/Configure" "$OPENSSL_TARGET" -U__ANDROID_API__ -D__ANDROID_API__=24 no-shared no-tests \
    -fPIC --prefix="$OPENSSL_PREFIX" --libdir=lib
  make -j"$JOBS"
  make install_sw
)

cmake -S "$WORK/td" -B "$WORK/build-$ABI" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384 \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
  -DZLIB_LIBRARY="$TOOLCHAIN/sysroot/usr/lib/$TRIPLE/24/libz.so" \
  -DZLIB_INCLUDE_DIR="$TOOLCHAIN/sysroot/usr/include" \
  -DTD_ENABLE_JNI=OFF -DTD_ENABLE_DOTNET=OFF -DTD_ENABLE_LTO=OFF -DTD_INSTALL_STATIC_LIBRARIES=OFF
cmake --build "$WORK/build-$ABI" --target tdjson --parallel "$JOBS"
OUTPUT="$ROOT/android/app/src/main/jniLibs/$ABI"
mkdir -p "$OUTPUT" "$ROOT/native/android/licenses"
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$WORK/build-$ABI/libtdjson.so" -o "$OUTPUT/libtdjson.so"
cp "$WORK/td/LICENSE_1_0.txt" "$ROOT/native/android/licenses/TDLib.txt"
cp "$WORK/openssl/LICENSE.txt" "$ROOT/native/android/licenses/OpenSSL.txt"
printf '{"tdlib":"%s","openssl":"%s","ndk":"%s","abi":"%s","api":24}\n' \
  "$TD_REVISION" "$OPENSSL_REVISION" "$NDK_VERSION" "$ABI" > "$ROOT/native/android/build-manifest.json"
echo "Built pinned TDLib for $ABI: $OUTPUT/libtdjson.so"
