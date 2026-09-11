# Photos And Videos

The control app provides a Photos view for media whose original file is currently
present on the device. It works in direct LAN mode and through the authenticated
relay. Indexing and rendering are read-only; an explicit confirmed delete uses a
separate Photos framework transaction.

## Library Index

`core/net/MediaLibrary.mm` opens
`/var/mobile/Media/PhotoData/Photos.sqlite` read-only and indexes visible,
non-deleted `ZASSET` rows. It never writes to the Photos database. Each database
path is canonicalized and accepted only when it resolves to a regular,
non-symlink file below `/var/mobile/Media`.

A DCIM filesystem scan is merged only after a successful database read, for a
new capture that has not appeared in `ZASSET` yet. Files sharing a directory and
filename stem with any database asset are treated as resources of that logical
asset. A visible Live Photo's paired `.MOV` is attached as its motion resource
instead of being exposed as a duplicate zero-length video. Resources belonging
to Hidden and Recently Deleted database rows remain excluded.
An unavailable or incompatible database fails closed instead of risking
disclosure of those assets. Results are cached for 15 seconds and sorted newest
first. iCloud-only placeholders are omitted until iOS downloads their original
file.

## API

```text
GET /v1/media?type=all|photo|video&q=&cursor=&limit=&refresh=1
GET /v1/media_asset?id=<opaque-id>
GET /v1/media_thumb?id=<opaque-id>
GET /v1/media_preview?id=<opaque-id>
POST /v1/media_delete_token?id=<opaque-id>  Content-Type: application/json
POST /v1/media_delete?id=<opaque-id>        Content-Type: application/json
                                            {"token":"<one-time-token>"}
```

List pages are capped at 100 items. IDs are stable path hashes; callers cannot
supply filesystem paths to thumbnail endpoints. Thumbnails are 640-pixel JPEGs
and photo previews are 2048-pixel JPEGs, so HEIC assets work in browsers without
native HEIC decoding. Video thumbnails prefer the device's existing Photos
poster; AVFoundation generates a frame from the original when no usable poster
is available.

Generated images live under
`/var/mobile/Library/Caches/com.greatlove.rctl/media` with a `0700` directory and
`0600` files. Their cache key includes the original modification time and, when
using a Photos poster, a SHA-256 digest of that poster. Replacing a poster thus
invalidates the rendered cache even if the original video is unchanged.

ImageIO and AVFoundation rendering is serialized on the media queue. iOS 14
assigns third-party launch daemons a 6 MiB jetsam limit even when a larger
`JetsamProperties` value is present in their plist, which is below rctld's
normal WebRTC footprint. At startup rctld therefore applies a 128 MiB fatal task
limit with `memorystatus_control`; startup logs must report
`jetsam hard limit configured`. The hard ceiling protects the device, while
serialization and per-request autorelease pools keep normal preview use well
below it. Do not move rendering back onto concurrent HTTP threads or remove the
runtime limit without physical-device stress testing uncached photo and video
previews.

## Browser Behavior

The Media sheet supports photo/video filters, filename search, pagination,
responsive thumbnails, full-screen preview, and an explicit action menu on every
tile. Download uses `/v1/pull_stream`, which writes incrementally to the browser
download manager locally or through the authenticated relay stream tunnel. It
does not materialize the original in `rctld` or a browser `Blob`. Share and
original media playback use the peer-to-peer `files` DataChannel because those
browser APIs require an in-memory object. Copy
Image converts the bounded JPEG preview to PNG for broad clipboard compatibility;
browser image clipboard and Web Share APIs require a secure context. Local plain
HTTP retains Download; unsupported Copy/Share actions are not offered. HTTPS alone
does not guarantee Web Share support: the browser must implement it as well.

On the tested iOS 15.5 rootless device, `AVAssetImageGenerator` failed with
AVFoundation `-11800` / OSStatus `-12437` for both H.264 and HEVC, as both root
and mobile. This is a failure of the standalone native extraction path, not
proof of corrupt originals or a browser playback failure. A previous
`AVAssetReader` attempt did not provide decoded image buffers either.

Photos already maintains image derivatives under
`PhotoData/Thumbnails/V2/<original-relative-path>/`. The renderer reads only the
exact directory corresponding to an asset admitted by the visible, local index.
It does not globally index thumbnail directories, fetch iCloud originals, modify
Photos data, or infer assets from cached posters. Directory traversal uses
`openat` with `O_NOFOLLOW` for every component; candidate files must be regular,
at most 8 MiB, with image dimensions no greater than 4096 on either axis. At most
32 entries are inspected per asset. The largest valid candidate is downsampled
with ImageIO, preserving its orientation. JPEG encoding and the existing private
render cache remain daemon-owned and serialized.

This Photos cache layout is an optional private-format adapter, not a guaranteed
iOS API. Missing, incompatible, oversized, symlinked or undecodable derivatives
fall back to the unchanged `AVAssetImageGenerator` path. If both sources fail,
the client retains its video placeholder and original playback/download actions.
The browser never downloads an entire video merely to populate a tile. Failed
native-generation diagnostics contain only error domains/codes, never paths.

Physical verification on 2026-09-11: all locally indexed video originals on the
iOS 15.5 rootless target produced decodable, bounded JPEGs, both from an isolated
build of the real renderer and through the updated daemon's HTTP endpoint. The
browser's Media -> Videos page decoded all 60 initial tiles with no failed images.
The same renderer also produced the rootful iOS 14 target's video thumbnail.
The rootless installation was a backed-up, watchdog-protected daemon-only
replacement; SpringBoard payloads and package-manager version were unchanged.
This does not qualify relay transport or a full-package upgrade. Host tests cover
poster replacement without original changes, portrait/landscape bounds, candidate
selection, corrupt/missing/oversized data, and symlink rejection.

GIF previews remain static until the user requests the original, then the browser
renders the original animated file. A Live Photo remains one library item and
offers its paired motion resource from the same viewer. Motion uses the original
QuickTime codec: browsers that cannot decode that codec show an explicit error
and retain Download Original rather than transcoding on the memory-constrained
device.

## Deletion

Only visible `ZASSET` rows with a Photos UUID are marked deletable. A DCIM
fallback item is never deletable because it does not yet have a stable Photos
identity. The browser shows a destructive confirmation, requests a random
128-bit token valid for 30 seconds, then submits that token once in a JSON body.
Both endpoints require `POST application/json`: because the LAN server's legacy
read APIs allow wildcard CORS, the non-simple content type deliberately forces a
cross-origin preflight, which the device does not authorize. Tokens are never put
in URLs or relay access paths.

`rctld` resolves the opaque ID back to the UUID from the current visible index
and sends only that UUID over request/reply IPC. SpringBoard performs
`PHAssetChangeRequest deleteAssets` inside `PHPhotoLibrary performChangesAndWait`.
Photos therefore owns Recently Deleted, iCloud, album, and Live Photo resource
bookkeeping. The implementation never unlinks DCIM files and never writes
`Photos.sqlite` directly. A successful transaction invalidates the daemon's
cached index before the browser refreshes.

Browser video and Live Photo playback currently materializes one Blob, so motion
previews are limited to 250 MiB. Animated image previews are limited to 50 MiB,
and Web Share preparation to 100 MiB. Larger originals remain downloadable
through the bounded stream. A future large-media player should consume a
seekable bounded protocol and browser-compatible fragmented MP4 path rather
than increasing these limits.

Edit, favorite, Hidden album browsing, permanent deletion, Recently Deleted
browsing, and forced iCloud download are outside the current release contract.

## Qualification

Test JPEG, HEIC, PNG, animated GIF, Live Photo, MOV, and MP4 assets; portrait and
landscape orientation; duplicate filenames; an edited asset; an iCloud-only
placeholder; Hidden and Recently Deleted; pagination above 100 assets; Copy over
HTTPS; Share on supported Safari/Chrome versions; relay reconnect during original
download; an unsupported motion codec; and media above each preview limit. On a
physical iOS 14 device, delete a disposable photo, video, GIF, and Live Photo;
verify each leaves the main library, appears in Recently Deleted, remains
recoverable, and does not remove an adjacent asset. Also verify expired/replayed
tokens, missing SpringBoard, local cross-origin requests, and relay reconnects
fail without deleting anything.
