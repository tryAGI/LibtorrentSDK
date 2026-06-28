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
  --reuse-build         Reuse existing CMake/Xcode slice directories.
                        Default is a clean slice rebuild.
  -h, --help            Show this help.

Environment overrides:
  BOOST_ROOT, LIBTORRENT_REF, LIBTORRENT_SOURCE, LIBTORRENT_BUILD_ROOT,
  LIBTORRENT_XCFRAMEWORK_OUTPUT, LIBTORRENT_REUSE_BUILD,
  LIBTORRENT_FORCE_SUBMODULE_UPDATE, IOS_DEPLOYMENT_TARGET
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
for tool in git cmake xcodebuild xcrun; do
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
    local sdk_path
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

    if [[ "$reuse_build" != "1" ]]; then
        rm -rf "$slice_root"
    else
        reset_stale_cmake_cache "$slice_root"
    fi
    mkdir -p "$slice_root"

    echo "Configuring $label ($sdk, $architectures)"
    cmake -S "$bridge_dir" -B "$slice_root" \
        "${cmake_common_args[@]}" \
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

echo "Built $output_path"
