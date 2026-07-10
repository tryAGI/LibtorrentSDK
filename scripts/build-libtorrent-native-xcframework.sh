#!/bin/bash
set -euo pipefail

script_dir="$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
bridge_dir="$repo_root/NativeBridge"

libtorrent_ref="${LIBTORRENT_REF:-v2.0.13}"
libtorrent_source="${LIBTORRENT_SOURCE:-}"
build_root="${LIBTORRENT_BUILD_ROOT:-$repo_root/artifacts/libtorrent-native}"
output_path="${LIBTORRENT_XCFRAMEWORK_OUTPUT:-$repo_root/vendor/LibtorrentNative.xcframework}"
ios_deployment_target="${IOS_DEPLOYMENT_TARGET:-26.1}"
openssl_version="${OPENSSL_APPLE_VERSION:-3.6.300}"
openssl_checksum="${OPENSSL_APPLE_CHECKSUM:-ecb4b3972de7967ccaa37518c502a45b79f7a82bc4e10165455ac96309e64558}"
openssl_xcframework="${OPENSSL_XCFRAMEWORK:-}"
ca_bundle_checksum="${LIBTORRENT_CA_BUNDLE_CHECKSUM:-86a1f3366afac7c6f8ae9f3c779ac221129328c43f0ab2b8817eb2f362a5025c}"
ca_bundle="${LIBTORRENT_CA_BUNDLE:-}"
reuse_build="${LIBTORRENT_REUSE_BUILD:-0}"
fetch_source=1

usage() {
    cat <<'EOF'
Usage: scripts/build-libtorrent-native-xcframework.sh [options]

Builds vendor/LibtorrentNative.xcframework from libtorrent source plus the
NativeBridge C ABI.

Options:
  --source <path>       Reuse an existing libtorrent source checkout.
  --ref <tag-or-sha>    libtorrent git ref to fetch when --source is omitted.
                        Default: v2.0.13
  --build-root <path>   Build/cache directory. Default: artifacts/libtorrent-native
  --output <path>       XCFramework output path.
                        Default: vendor/LibtorrentNative.xcframework
  --openssl <path>      Reuse an openssl.xcframework. By default the pinned
                        openssl-apple release is downloaded and verified.
  --ca-bundle <path>    Reuse a PEM CA bundle. By default the pinned Mozilla
                        CA extract published by curl is downloaded and verified.
  --reuse-build         Reuse existing CMake/Xcode slice directories.
                        Default is a clean slice rebuild.
  -h, --help            Show this help.

Environment overrides:
  BOOST_ROOT, LIBTORRENT_REF, LIBTORRENT_SOURCE, LIBTORRENT_BUILD_ROOT,
  LIBTORRENT_XCFRAMEWORK_OUTPUT, LIBTORRENT_REUSE_BUILD,
  LIBTORRENT_FORCE_SUBMODULE_UPDATE, IOS_DEPLOYMENT_TARGET
  OPENSSL_XCFRAMEWORK, OPENSSL_APPLE_VERSION, OPENSSL_APPLE_CHECKSUM
  LIBTORRENT_CA_BUNDLE, LIBTORRENT_CA_BUNDLE_CHECKSUM
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            libtorrent_source="${2:?--source requires a path}"
            fetch_source=0
            shift 2
            ;;
        --ref)
            libtorrent_ref="${2:?--ref requires a value}"
            shift 2
            ;;
        --build-root)
            build_root="${2:?--build-root requires a path}"
            shift 2
            ;;
        --output)
            output_path="${2:?--output requires a path}"
            shift 2
            ;;
        --openssl)
            openssl_xcframework="${2:?--openssl requires a path}"
            shift 2
            ;;
        --ca-bundle)
            ca_bundle="${2:?--ca-bundle requires a path}"
            shift 2
            ;;
        --reuse-build)
            reuse_build=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

missing_tools=()
for tool in awk git cmake cp curl ditto grep otool shasum xcodebuild xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
    fi
done

if [[ "${#missing_tools[@]}" -gt 0 ]]; then
    echo "Missing required tool(s): ${missing_tools[*]}" >&2
    exit 1
fi

if [[ -z "$libtorrent_source" ]]; then
    libtorrent_source="$build_root/libtorrent-src"
fi

ensure_libtorrent_submodules() {
    restore_libtorrent_dependency deps/try_signal \
        https://github.com/arvidn/try_signal.git \
        try_signal.cpp

    restore_libtorrent_dependency deps/asio-gnutls \
        https://github.com/paullouisageneau/boost-asio-gnutls.git \
        include/boost/asio/gnutls.hpp
}

restore_libtorrent_dependency() {
    local relative_path="$1"
    local remote_url="$2"
    local sentinel_path="$3"
    local expected_commit
    local target_path="$libtorrent_source/$relative_path"
    local current_commit=""

    expected_commit="$(git -C "$libtorrent_source" rev-parse "HEAD:$relative_path")"

    if [[ -d "$target_path/.git" ]]; then
        current_commit="$(git -C "$target_path" rev-parse HEAD 2>/dev/null || true)"
    fi

    if [[ "${LIBTORRENT_FORCE_SUBMODULE_UPDATE:-0}" != "1" &&
        "$current_commit" == "$expected_commit" &&
        -f "$target_path/$sentinel_path" ]]; then
        echo "Reusing libtorrent dependency $relative_path at $expected_commit"
        return
    fi

    echo "Restoring libtorrent dependency $relative_path at $expected_commit"
    rm -rf "$target_path"
    mkdir -p "$target_path"
    git -C "$target_path" init
    git -C "$target_path" remote add origin "$remote_url"

    if ! GIT_TERMINAL_PROMPT=0 git -C "$target_path" fetch --depth 1 origin "$expected_commit"; then
        GIT_TERMINAL_PROMPT=0 git -C "$target_path" fetch origin "$expected_commit"
    fi
    git -C "$target_path" checkout --detach FETCH_HEAD

    if [[ ! -f "$target_path/$sentinel_path" ]]; then
        echo "Restored $relative_path but missing $sentinel_path" >&2
        exit 1
    fi
}

mkdir -p "$build_root"

prepare_openssl() {
    if [[ -n "$openssl_xcframework" ]]; then
        if [[ ! -d "$openssl_xcframework" ]]; then
            echo "OpenSSL XCFramework does not exist: $openssl_xcframework" >&2
            exit 1
        fi
        return
    fi

    local openssl_root="$build_root/openssl-apple-$openssl_version"
    local archive="$openssl_root/openssl.xcframework.zip"
    openssl_xcframework="$openssl_root/openssl.xcframework"

    if [[ ! -f "$archive" ]]; then
        mkdir -p "$openssl_root"
        curl --fail --location --retry 3 \
            "https://github.com/partout-io/openssl-apple/releases/download/$openssl_version/openssl.xcframework.zip" \
            --output "$archive"
    fi

    local actual_checksum
    actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual_checksum" != "$openssl_checksum" ]]; then
        echo "OpenSSL archive checksum mismatch: expected $openssl_checksum, got $actual_checksum" >&2
        exit 1
    fi

    if [[ ! -d "$openssl_xcframework" ]]; then
        ditto -x -k "$archive" "$openssl_root"
    fi
}

prepare_openssl

prepare_ca_bundle() {
    if [[ -n "$ca_bundle" ]]; then
        if [[ ! -f "$ca_bundle" ]]; then
            echo "CA bundle does not exist: $ca_bundle" >&2
            exit 1
        fi
    else
        local ca_root="$build_root/mozilla-ca-2026-05-14"
        ca_bundle="$ca_root/cacert.pem"
        if [[ ! -f "$ca_bundle" ]]; then
            mkdir -p "$ca_root"
            curl --fail --location --retry 3 \
                "https://curl.se/ca/cacert.pem" \
                --output "$ca_bundle"
        fi
    fi

    local actual_checksum
    actual_checksum="$(shasum -a 256 "$ca_bundle" | awk '{print $1}')"
    if [[ "$actual_checksum" != "$ca_bundle_checksum" ]]; then
        echo "CA bundle checksum mismatch: expected $ca_bundle_checksum, got $actual_checksum" >&2
        exit 1
    fi
}

prepare_ca_bundle

if [[ "$fetch_source" -eq 1 ]]; then
    if [[ -d "$libtorrent_source/.git" ]]; then
        echo "Updating libtorrent source at $libtorrent_source ($libtorrent_ref)"
        git -C "$libtorrent_source" fetch --tags --depth 1 origin "$libtorrent_ref"
        git -C "$libtorrent_source" checkout --detach FETCH_HEAD
    else
        echo "Cloning libtorrent $libtorrent_ref into $libtorrent_source"
        git clone --branch "$libtorrent_ref" --depth 1 https://github.com/arvidn/libtorrent.git "$libtorrent_source"
    fi
    ensure_libtorrent_submodules
elif [[ ! -d "$libtorrent_source" ]]; then
    echo "libtorrent source directory does not exist: $libtorrent_source" >&2
    exit 1
fi

boost_root="${BOOST_ROOT:-}"
if [[ -z "$boost_root" ]] && command -v brew >/dev/null 2>&1; then
    boost_root="$(brew --prefix boost 2>/dev/null || true)"
fi

cmake_common_args=(
    -G Xcode
    -DLIBTORRENT_SOURCE_DIR="$libtorrent_source"
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$ios_deployment_target"
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO
    -DCMAKE_XCODE_ATTRIBUTE_BUILD_LIBRARY_FOR_DISTRIBUTION=YES
    -DCMAKE_XCODE_ATTRIBUTE_SKIP_INSTALL=NO
)

if [[ -n "$boost_root" ]]; then
    cmake_common_args+=(
        -DBOOST_ROOT="$boost_root"
        -DBoost_INCLUDE_DIR="$boost_root/include"
    )
fi

find_framework() {
    local search_root="$1"
    local framework=""

    while IFS= read -r candidate; do
        framework="$candidate"
        break
    done < <(find "$search_root" -type d -name LibtorrentNative.framework -print 2>/dev/null | sort)

    if [[ -z "$framework" ]]; then
        echo "Could not find LibtorrentNative.framework under $search_root" >&2
        exit 1
    fi

    printf '%s\n' "$framework"
}

reset_stale_cmake_cache() {
    local slice_root="$1"
    local cache_file="$slice_root/CMakeCache.txt"
    local cached_source=""

    if [[ ! -f "$cache_file" ]]; then
        return
    fi

    cached_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" 2>/dev/null || true)"
    if [[ -n "$cached_source" && "$cached_source" != "$bridge_dir" ]]; then
        echo "Removing stale CMake cache for $slice_root; cached source was $cached_source"
        rm -rf "$slice_root"
    fi
}

build_slice() {
    local label="$1"
    local sdk="$2"
    local architectures="$3"
    local slice_root="$build_root/$label"
    local openssl_framework
    local openssl_include_root
    local staged_ca_bundle
    local sdk_path
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

    case "$sdk" in
        iphoneos)
            openssl_framework="$openssl_xcframework/ios-arm64_arm64e/openssl.framework"
            ;;
        iphonesimulator)
            openssl_framework="$openssl_xcframework/ios-arm64_x86_64-simulator/openssl.framework"
            ;;
        *)
            echo "Unsupported SDK for OpenSSL slice selection: $sdk" >&2
            exit 1
            ;;
    esac
    if [[ ! -f "$openssl_framework/openssl" ]]; then
        echo "Missing OpenSSL framework binary: $openssl_framework/openssl" >&2
        exit 1
    fi

    if [[ "$reuse_build" != "1" ]]; then
        rm -rf "$slice_root"
    else
        reset_stale_cmake_cache "$slice_root"
    fi
    mkdir -p "$slice_root"
    staged_ca_bundle="$slice_root/cacert.pem"
    cp "$ca_bundle" "$staged_ca_bundle"
    openssl_include_root="$slice_root/openssl-include"
    mkdir -p "$openssl_include_root"
    ln -sfn "$openssl_framework/Headers" "$openssl_include_root/openssl"

    echo "Configuring $label ($sdk, $architectures)"
    cmake -S "$bridge_dir" -B "$slice_root" \
        "${cmake_common_args[@]}" \
        -DOPENSSL_ROOT_DIR="$openssl_framework" \
        -DOPENSSL_INCLUDE_DIR="$openssl_include_root" \
        -DOPENSSL_SSL_LIBRARY="$openssl_framework/openssl" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_framework/openssl" \
        -DLIBTORRENT_CA_BUNDLE="$staged_ca_bundle" \
        -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_ARCHITECTURES="$architectures"

    echo "Building $label"
    xcodebuild \
        -project "$slice_root/LibtorrentNative.xcodeproj" \
        -scheme LibtorrentNative \
        -configuration Release \
        -sdk "$sdk" \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        SKIP_INSTALL=NO \
        build

    built_framework="$(find_framework "$slice_root")"
}

built_framework=""
build_slice ios-device iphoneos arm64
device_framework="$built_framework"
build_slice ios-simulator iphonesimulator "arm64;x86_64"
simulator_framework="$built_framework"

echo "Creating XCFramework at $output_path"
rm -rf "$output_path"
mkdir -p "$(dirname "$output_path")"
xcodebuild -create-xcframework \
    -framework "$device_framework" \
    -framework "$simulator_framework" \
    -output "$output_path"

for binary in \
    "$output_path/ios-arm64/LibtorrentNative.framework/LibtorrentNative" \
    "$output_path/ios-arm64_x86_64-simulator/LibtorrentNative.framework/LibtorrentNative"; do
    if ! otool -L "$binary" | grep -q '@rpath/openssl.framework/openssl'; then
        echo "Built native framework is missing its OpenSSL runtime dependency: $binary" >&2
        exit 1
    fi
    embedded_ca_bundle="$(dirname "$binary")/cacert.pem"
    if [[ ! -f "$embedded_ca_bundle" ]]; then
        echo "Built native framework is missing its CA bundle: $embedded_ca_bundle" >&2
        exit 1
    fi
    embedded_ca_checksum="$(shasum -a 256 "$embedded_ca_bundle" | awk '{print $1}')"
    if [[ "$embedded_ca_checksum" != "$ca_bundle_checksum" ]]; then
        echo "Embedded CA bundle checksum mismatch in $embedded_ca_bundle" >&2
        exit 1
    fi
done

echo "Built $output_path"
