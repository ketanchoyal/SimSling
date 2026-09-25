<p align="center">
  <img src="Assets/logo.png" width="160" alt="SimDrop logo">
</p>

<h1 align="center">SimDrop</h1>

<p align="center">
  Drop files into iOS simulators again.<br>
  A menu bar app, a floating toolbar docked beside each simulator, and a CLI for the Xcode 27 Device Hub.
</p>

<p align="center">
  <img src="Assets/screenshot.png" width="520" alt="SimDrop toolbar docked beside an iPhone simulator">
</p>

## Why

In Xcode 27 the simulator lives in **Device Hub**, and getting arbitrary files into it got harder:
drag and drop is ignored, there's no "share with simulator" in Finder, and Finder copies into the
simulator's storage can land as zero-byte files
([developer.apple.com/forums/thread/846994](https://developer.apple.com/forums/thread/846994)).

SimDrop writes straight into the Files app's **On My iPhone** storage with `rsync`, and uses
`simctl` for everything else.

## Features

**Floating toolbar.** A slim toolbar docks beside every open simulator window and follows it as you
move it (it flips to the left when there's no room on the right). It sits just above its own
window, not over everything, and never steals focus from the simulator. Hover a button to see
what it does. Everything on a toolbar acts on **that simulator only**.

| Button | Does |
| --- | --- |
| Send Files | Pick files, or drop files anywhere on the toolbar |
| Destination | Auto, Files, Photos, or an app's Documents folder |
| Paste Mac Clipboard | Put the Mac clipboard onto the simulator |
| Copy Sim Clipboard | Bring the simulator's clipboard to the Mac |
| Open URL | Open a URL or deep link |
| Show in Finder | Reveal the simulator's Files storage |

**Menu bar app.** Drop files on the menu bar icon or in its panel to send them to every checked
booted simulator. The ⋯ menu turns the floating toolbar on or off.

**Auto routing.**

| Drop | Goes to |
| --- | --- |
| Images, videos, `.vcf` | Photos / Contacts (`simctl addmedia`) |
| `.app` bundle | Installed (`simctl install`) |
| Anything else, including folders | Files › On My iPhone |

## Install

### Download

Grab **SimDrop-x.y.z.zip** from the [latest release](https://github.com/ketanchoyal/SimDrop/releases/latest),
unzip it and move **SimDrop.app** to Applications. It's a universal build (Apple Silicon and Intel)
for macOS 15 or later, and needs Xcode installed for `xcrun simctl`.

SimDrop is ad-hoc signed and not notarized, so macOS blocks the first launch. Either open it once
and then click **Open Anyway** in **System Settings › Privacy & Security**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/SimDrop.app
```

### Build from source

```sh
git clone https://github.com/ketanchoyal/SimDrop.git
cd SimDrop
./scripts/build-app.sh            # -> build/SimDrop.app
cp -R build/SimDrop.app /Applications/
open /Applications/SimDrop.app
```

To publish a release: bump `VERSION`, then run `./scripts/release.sh`.

The floating toolbar reads simulator window titles to know which device each window is. If macOS
hides them, allow SimDrop under **System Settings › Privacy & Security › Screen Recording**.

## CLI

The app binary doubles as a CLI:

```sh
ln -s /Applications/SimDrop.app/Contents/MacOS/SimDrop /usr/local/bin/simdrop

simdrop list
simdrop send backup.dat photos/*.heic          # all booted sims, auto-routed
simdrop send -d "iPhone 17 Pro" --files data/
simdrop send --app com.example.myapp seed.sqlite
simdrop clip-to-sim
simdrop clip-from-sim
simdrop open "myapp://settings"
```

## License

MIT
