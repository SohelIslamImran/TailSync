# TailSync

TailSync is a native iOS app for syncing photos, videos, and shared files to your own Tailscale Taildrop devices. It is built around the same local Taildrop PeerAPI receiver that Tailscale clients expose on a private tailnet, so transfers stay inside your Tailscale network instead of going through a cloud storage service.

The app is intentionally cautious: originals are exported at full quality, each file is tracked per destination device, and photo-library deletion only happens after every enabled destination has received the file.

## Highlights

- Sync photos and videos from the iOS Photos library.
- Send arbitrary files from inside the app.
- Send files from other apps through the iOS share sheet extension.
- Add multiple Taildrop devices by MagicDNS name or Tailscale IP.
- Enable Auto Sync per device.
- Avoid duplicate sends by remembering which device received each asset.
- Send again, retry failed items, or resend previously sent items when needed.
- Show active transfer progress with filename, destination, bytes sent, and percent complete.
- Pause on connection failure, recheck reachability, then retry with exponential backoff.
- Optional auto-delete delays: never, immediately, 24 hours, 1 week, 15 days, or 30 days.
- Optional smart delete behavior for low-storage situations.

## How It Works

TailSync sends files to a Taildrop device's local PeerAPI upload endpoint:

```text
http://<taildrop-device>:<peerapi-port>/v0/put/<filename>
```

You do not need to type the protocol or port in the UI. Add only a MagicDNS name or Tailscale IP, for example:

```text
my-phone.tailnet-name.ts.net
```

or:

```text
100.x.y.z
```

PeerAPI ports can differ between Tailscale clients and platforms. TailSync probes likely PeerAPI ports, remembers the working port for each device, and checks reachability before sending.

## Setup

1. Install Tailscale on the iPhone and each destination device.
2. Sign in to the same tailnet.
3. Make sure Taildrop/file sharing is enabled for the destination device.
4. Open TailSync and grant Photos permission.
5. Add a device using its MagicDNS name or Tailscale IP.
6. Turn on Auto Sync for devices that should receive all new photos and videos.

The app cannot install, sign in to, or control the Tailscale client for you. Tailscale must already be connected on the devices.

## Safety Model

TailSync treats deletion as a final step, never as part of upload preparation.

- Originals are exported from Photos without recompression.
- A file is marked sent only after the receiver returns success.
- The same asset is not sent twice to the same device unless you choose a resend action.
- Auto-delete is off by default.
- If one transfer fails, the queue pauses instead of trying every remaining file.
- Retry checks use exponential backoff so unreachable devices do not create notification spam.

## Share Extension

TailSync includes an iOS Share Extension. From Photos, Files, or another app:

1. Tap Share.
2. Choose TailSync.
3. Select one or more configured devices.
4. Tap Send.

The extension reads saved devices through the app group and uses the same Taildrop upload path as the main app.

## Background Behavior

iOS limits long-running background work. TailSync uses photo-library change observation while running and background refresh opportunities when the system permits. It can continue short transfers after leaving the app, but iOS does not guarantee indefinite background execution or work after force-quitting the app.

## Building

Open the project in Xcode:

```bash
open TailSync.xcodeproj
```

Signing and identifiers are configured in one place:

```text
Config/TailSyncIdentifiers.xcconfig
```

Keep that file committed. For your own Apple Developer account, create a local override:

```text
Config/TailSyncIdentifiers.local.xcconfig
```

Then set:

- `TAILSYNC_DEVELOPMENT_TEAM`
- `TAILSYNC_BUNDLE_PREFIX`

`TailSyncIdentifiers.local.xcconfig` is ignored by git. The app bundle ID, share extension bundle ID, App Group, and background refresh identifier are derived from those values. Xcode will use them in the app target, share extension target, entitlements, and runtime storage config.

Command-line build:

```bash
xcodebuild \
  -project TailSync.xcodeproj \
  -scheme TailSync \
  -destination 'generic/platform=iOS' \
  build
```

## Smoke Testing Taildrop

`TaildropSmokeTest` is optional debug code. It does not contain a real device address. Pass a PeerAPI base URL through the environment when running a custom smoke test:

```bash
TAILSYNC_SMOKE_PEER_API_URL='http://device-name.example.ts.net:12345' \
  # launch your debug target here
```

## Privacy

TailSync stores device settings and transfer state locally on device. The app is designed for your private Tailscale network and does not require a third-party backend.

## Status

This is an experimental personal sync utility. Test with non-critical files first, keep backups, and review deletion settings before enabling automatic deletion.
