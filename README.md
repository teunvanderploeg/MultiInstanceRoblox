# MultiInstanceRoblox

Native macOS utility for managing multiple Roblox profiles on Apple Silicon Macs.

The app creates a separate managed copy of the installed Roblox app per profile, keeps a separate WebKit login session per profile, and routes `roblox:` / `roblox-player:` launch URLs to the selected profile copy.

It does not store Roblox passwords, automate gameplay, patch the original `/Applications/Roblox.app`, or attempt to bypass Roblox platform checks.

## Build

```sh
swift build -c release
./Scripts/package_app.sh
open dist/MultiInstanceRoblox.app
```

## Runtime Data

Profiles and managed Roblox copies are stored at:

```text
~/Library/Application Support/MultiInstanceRoblox/
```

Each profile has its own:

- Persistent WebKit data store UUID.
- Managed Roblox copy.
- Profile metadata JSON.

If Roblox updates, the app detects the source version mismatch and offers to repair/rebuild the profile copy.

## Features

- Multiple profiles with separate Roblox web sessions.
- Per-profile managed Roblox copies.
- Profile rename, duplicate, color, icon, notes, search, and reorder.
- Bulk profile selection for launching and repair actions.
- Paste URL/search launcher.
- Favorites and recent URLs per profile.
- Repair all, stop all, clone health details, and diagnostics export.
- Running process CPU/RAM display.
- Best-effort Roblox window arrangement: grid, columns, rows, and cascade.
- Per-profile session clearing.

## URL Launching

Roblox web game URLs usually need the logged-in browser session to generate a session-specific `roblox-player:` URL. Because of that:

- `roblox:` and `roblox-player:` URLs can be launched directly across selected profiles.
- Normal `https://www.roblox.com/...` URLs are queued into each selected profile browser; select each profile and press Play from that logged-in Roblox page.

## Window Arrangement

Window arrangement uses macOS Accessibility automation through System Events. If it does not move Roblox windows, allow the app or Terminal/Codex host in:

```text
System Settings -> Privacy & Security -> Accessibility
```
