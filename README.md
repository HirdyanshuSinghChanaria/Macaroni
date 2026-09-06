# Macaroni

**Per-app volume control for macOS, plus the small utilities you'd otherwise
install five separate apps for.** Lives in the menu bar. Free and open source.

![Macaroni's per-app volume mixer in action](docs/demo.gif)

*Two apps playing at once, each with its own slider — turn one down without
touching the other.*

## Why

macOS has no way to set the volume of one app. Apps aren't mastered at the same
level — a YouTube video at 100% can be far louder than Spotify at 100%, a game
buries your voice chat, one browser tab is twice as loud as everything else —
and the only control you have is the system volume, which moves all of it
together. Turn it down and the thing you actually wanted to hear gets quieter
too.

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
slider. Drop a loud video to 20% while your music stays where it is. Levels are
remembered per app, so an app you turned down comes back at that level next
time it plays.
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

**Turn off what you don't want** — the Settings button in the panel switches off
any feature individually, and off means off: the clipboard poller stops, the
network sampler stops, the scroll event tap is removed, and any audio taps are
released.

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

### Permissions stop working after an update — here's why

macOS ties a permission to an app's **code signature**, and Macaroni is ad-hoc
signed (a Developer ID certificate costs $99/year, which this project doesn't
have yet). Ad-hoc signatures are regenerated on every build, so each release is
a different app as far as macOS is concerned.

The result is confusing: after updating, Macaroni still appears ticked in
System Settings, but it behaves as though it has no permission — because the
grant belongs to the previous build.

The fix, in System Settings → Privacy & Security → Accessibility (or
Microphone): select Macaroni, remove it with the **−** button, then let the app
prompt you again. Or from a terminal:

```bash
tccutil reset Accessibility com.hirdyanshu.macaroni
tccutil reset Microphone com.hirdyanshu.macaroni
```

This goes away entirely once the project is signed with a stable Developer ID.

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

## Troubleshooting

**"Macaroni can't be opened because it is from an unidentified developer."**
Expected — the app isn't notarized. Right-click it in Finder and choose
**Open**, then confirm. You only need to do this once per version.

**I ticked the permission, but Macaroni still says it doesn't have it.**
Updating the app invalidates the old grant — see [above](#permissions-stop-working-after-an-update--heres-why).
Remove Macaroni from the list with **−** and let it prompt you again.

**An app went completely silent when I moved its slider.**
That was a bug in 1.0: creating an audio tap mutes the app even when macOS
denies access, so a blocked tap left it silent. Fixed in 1.1 — any tap that
receives no audio is released within a couple of seconds and the app's volume
is restored. If you're on 1.0, update.

**Two Macaroni icons in my menu bar.**
Two copies running at once, usually from launching a new build while the old
one was still going. Fixed in 1.1 (a new launch retires the old one). To clear
it now: `pkill -x Macaroni`, then open the app again.

**Music gets quiet on its own when a call starts.**
That's macOS, not Macaroni. The system ducks other audio whenever an app opens
a voice-chat session, and it happens after Macaroni in the audio path, so
there's nothing the app can do about it.

**My Bluetooth headset sounds worse during calls when I use app volume.**
Tapping audio makes Macaroni a recording client as far as macOS is concerned,
which can push a Bluetooth headset into its low-quality hands-free profile. Not
currently fixable from the app's side; using per-app volume on wired output or
the built-in speakers avoids it.

**My output device has no volume slider.**
Some devices — many Bluetooth ones especially — expose no software volume to
macOS at all. Macaroni shows mute only in that case; use the device's own
controls or its buttons.

**Clipboard history is empty after restarting.**
By design. History lives in memory only and is never written to disk, so
nothing you copy survives a quit.

**The network numbers look too low.**
They're **bytes**, not bits. A 100 Mbps connection maxes out around 12 MB/s.
The reading also covers all traffic on your Wi-Fi/Ethernet interface — system
updates and background sync included — not just the app you're looking at.

**The menu bar shows only the icon, no numbers.**
Network speed is switched off in Settings. Turn it back on and the readout
returns.

### Building from source

**`swift: command not found`** — install the Xcode Command Line Tools with
`xcode-select --install`. Full Xcode isn't needed.

**A change doesn't show up no matter how often I rebuild** — clear the
incremental build cache:

```bash
rm -rf .build Macaroni.app && ./build-app.sh
```

**Rebuilt, but the app looks unchanged** — the running copy isn't replaced
automatically. Quit it first: `pkill -x Macaroni`. Also check you don't have an
older copy in `/Applications` that you're opening by habit.

## License

MIT — see [LICENSE](LICENSE).
