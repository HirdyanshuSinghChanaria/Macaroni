# Macaroni

**Per-app volume control for macOS, plus the small utilities you'd otherwise
install five separate apps for.** Lives in the menu bar. Free and open source.

![Macaroni's per-app volume mixer in action](docs/demo.gif)

*Two apps playing at once, each with its own slider — turn one down without
touching the other.*

## Why

macOS has no way to set the volume of one app. If Spotify is too loud under a
call, your options are "turn Spotify down inside Spotify" or "turn everything
down".

Macaroni fixes that with a real per-app mixer — a slider per app, independent
of everything else — and adds the handful of utilities that otherwise mean
running a clipboard manager, a network monitor and a disk cleaner alongside it.

It is deliberately small. Five features, one file each, no settings window, no
plugin system, no account. The whole thing is a few thousand lines you can read
in an afternoon — which is the point, if you'd rather understand the thing
intercepting your audio than trust it.

## What it does

<img src="docs/panel.png" width="360" alt="The Macaroni panel">

**App volume** — every app currently playing audio gets its own row and its own
slider. Turn Spotify to 20% while a call stays at 100%. Levels are remembered
per app, so an app you turned down comes back at that level next time it plays.
(On Bluetooth headsets during a call, macOS may switch the headset to its
hands-free profile while an app is being tapped, which lowers audio quality —
that's a macOS behavior, not something Macaroni can override.)

**Output control** — master volume, mute, and a dropdown to switch output
device (speakers, headphones, AirPods) without opening System Settings.

**Clipboard history** — the last 200 things you copied, in a scrollable list.
Click to copy again. Copying something already in the list moves it to the top
rather than duplicating it. Memory only — nothing is written to disk, so
nothing you copy outlives the app.

**Network speed** — live download and upload rates in the menu bar, next to the
icon, whether or not the panel is open, plus session totals in the panel.

**Scroll direction** — invert mouse scrolling independently of macOS's Natural
Scrolling setting, so your mouse and trackpad can behave differently.

**Disk cleaner** — finds old caches, logs, temp files, Trash and leftover
`.dmg`/`.pkg` installers, then shows you **exactly what it found**, grouped by
which app it belongs to, with sizes, before deleting anything. Everything
starts unticked. Nothing is ever removed without you selecting it and
confirming.

![The junk files review window](docs/junk-files.png)

## Requirements

- macOS 14.4 or later (per-app volume relies on Core Audio process taps, which
  don't exist before 14.4)
- Apple Silicon or Intel

## Install

**Build it yourself** — you only need the Xcode Command Line Tools
(`xcode-select --install`), not full Xcode:

```bash
git clone https://github.com/HirdyanshuSinghChanaria/Macaroni.git
cd Macaroni
./build-app.sh
open Macaroni.app
```

Move `Macaroni.app` to `/Applications` to keep it.

A prebuilt app is also attached to the latest [Release](../../releases). It
isn't notarized (that needs a paid Apple Developer account), so the first
launch needs **right-click → Open** rather than a double-click — macOS will
warn about an unidentified developer, which is expected for open-source apps
distributed outside the App Store.

## Permissions

- **Audio recording** — required for per-app volume. Core Audio taps are
  classified as recording, even though Macaroni never records anything; it
  reads an app's audio, applies your volume, and plays it straight back out.
- **Accessibility** — required only for scroll inversion, since intercepting
  scroll events needs it.

Nothing else needs permission. The disk cleaner only touches your own
`~/Library` caches, never system files or other apps' sandboxed data.

## How it works

The interesting part is per-app volume, because macOS has no API for it.

1. When you move an app's slider below 100%, Macaroni creates a **Core Audio
   process tap** on that app with `muteBehavior = .mutedWhenTapped`. The app's
   own audio stops reaching your speakers and arrives in our tap instead.
2. That tap is combined with your real output device into a private **aggregate
   device**.
3. An IOProc on that device multiplies every sample by your slider value and
   writes the result to the real output — handling any sample-rate or channel
   mismatch between the tap and the device along the way.

The net effect is that one app is quieter and nothing else is touched. Apps
left at 100% are never tapped at all, so audio only detours through Macaroni
when you've actually changed something.

Network speed comes from the kernel's own per-interface byte counters via
`sysctl(NET_RT_IFLIST2)` — the same source `netstat -ib` uses — sampled once a
second. It generates no traffic of its own.

## License

MIT — see [LICENSE](LICENSE).
