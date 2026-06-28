# LibtorrentSDK

Swift torrent runtime wrapper backed by a prebuilt libtorrent XCFramework for
iOS.

`LibtorrentSDK` owns the Swift-facing model types, session protocol, and native
adapter. The native implementation ships as `LibtorrentNative.xcframework`,
distributed as a GitHub release asset and linked only for iOS. macOS tests can
exercise the Swift ABI wrapper through in-process fake C symbols.

## Usage

```swift
.package(url: "https://github.com/tryAGI/LibtorrentSDK", exact: "0.2.0")
```

## Refreshing LibtorrentNative.xcframework

Use the manual **Release XCFramework** GitHub Actions workflow for normal binary
refreshes. It installs the native build prerequisites, rebuilds
`vendor/LibtorrentNative.xcframework`, zips the framework as the archive root,
computes the SwiftPM checksum, and publishes the release asset.

Refresh the binary only when the C ABI bridge changes, the pinned libtorrent ref
changes, or Xcode starts rejecting the existing binary slice.

```bash
# Optional: set a newer libtorrent tag or SHA.
LIBTORRENT_REF=v2.0.13 bash scripts/build-libtorrent-native-xcframework.sh
```

The builder uses `NativeBridge/` for the C ABI framework source and clones
libtorrent into `artifacts/libtorrent-native/libtorrent-src` unless
`--source <path>` or `LIBTORRENT_SOURCE` is provided. It emits
`vendor/LibtorrentNative.xcframework` by default.

Release artifacts must be zipped with the XCFramework directory as the archive
root:

```bash
ditto -c -k --sequesterRsrc --keepParent vendor/LibtorrentNative.xcframework LibtorrentNative.xcframework.zip
swift package compute-checksum LibtorrentNative.xcframework.zip
```

The expected slices are:

```bash
xcrun lipo -info vendor/LibtorrentNative.xcframework/ios-arm64/LibtorrentNative.framework/LibtorrentNative
xcrun lipo -info vendor/LibtorrentNative.xcframework/ios-arm64_x86_64-simulator/LibtorrentNative.framework/LibtorrentNative
```

## Native ABI

The native bridge uses a package-owned `tryagi_libtorrent_*` symbol prefix and
the `io.github.tryagi.libtorrent-native` framework bundle identifier.

```c
typedef void (*tryagi_libtorrent_event_callback_t)(const char *json, void *context);

int tryagi_libtorrent_session_create(
    tryagi_libtorrent_event_callback_t callback,
    void *context,
    void **session
);

void tryagi_libtorrent_session_destroy(void *session);
int tryagi_libtorrent_job_start(void *session, const char *json);
int tryagi_libtorrent_job_apply_selection(void *session, const char *json);
int tryagi_libtorrent_job_pause(void *session, const char *json);
int tryagi_libtorrent_job_resume(void *session, const char *json);
int tryagi_libtorrent_job_cancel(void *session, const char *json);
const char *tryagi_libtorrent_last_error(void *session);
```

Requests are UTF-8 JSON encoded from the Swift `LibtorrentJobInput`,
`LibtorrentFileSelection`, and job control models. Events sent to the callback
must use this envelope:

```json
{
  "type": "progress | stream_ready | completed",
  "progress": { "...": "LibtorrentProgress for progress/completed" },
  "readiness": { "...": "LibtorrentStreamReadiness for stream_ready" }
}
```
