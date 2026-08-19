# Photos And Videos

The control app provides a read-only Photos view for media whose original file
is currently present on the device. It works in direct LAN mode and through the
authenticated relay.

## Library Index

`core/net/MediaLibrary.mm` opens
`/var/mobile/Media/PhotoData/Photos.sqlite` read-only and indexes visible,
non-deleted `ZASSET` rows. It never writes to the Photos database. Each database
path is canonicalized and accepted only when it resolves to a regular,
non-symlink file below `/var/mobile/Media`.

A DCIM filesystem scan is merged only after a successful database read, for a
new capture that has not appeared in `ZASSET` yet. Files sharing a directory and
filename stem with any database asset are treated as resources of that logical
asset, so a Live Photo's paired `.MOV` is not exposed as a duplicate zero-length
video. This exclusion also covers Hidden and Recently Deleted database rows.
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
```

List pages are capped at 100 items. IDs are stable path hashes; callers cannot
supply filesystem paths to thumbnail endpoints. Thumbnails are 640-pixel JPEGs
and photo previews are 2048-pixel JPEGs, so HEIC assets work in browsers without
native HEIC decoding. Video thumbnails use AVFoundation at a representative
frame.

Generated images live under
`/var/mobile/Library/Caches/com.greatlove.rctl/media` with a `0700` directory and
`0600` files. Their cache key includes the original modification time.

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

The Photos sheet supports photo/video filters, filename search, pagination,
responsive thumbnails, full-screen photo preview, video preview, and original
download. Originals travel over the existing peer-to-peer `files` DataChannel,
not through the relay HTTP body tunnel.

Browser video playback currently materializes one Blob, so previews are limited
to 250 MiB to avoid exhausting mobile-browser memory. Larger videos remain
downloadable. A future large-video player should use a bounded streaming
protocol and a browser-compatible fragmented MP4 path rather than increasing
this limit.

The gallery is read-only by design. Delete, edit, favorite, Hidden album, and
forced iCloud download are outside the current release contract.

## Qualification

Test JPEG, HEIC, PNG, MOV, and MP4 assets; portrait and landscape orientation;
duplicate filenames; an edited asset; an iCloud-only placeholder; Hidden and
Recently Deleted; pagination above 100 assets; relay reconnect during original
download; and a video above the preview limit.
