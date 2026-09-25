# SimDrop

A menu bar app (and CLI) for the stuff the Xcode 27 Device Hub dropped: getting files into
iOS simulators. Drag files onto the menu bar icon, or open it and drop them in the panel.

Background: [developer.apple.com/forums/thread/846994](https://developer.apple.com/forums/thread/846994).
Device Hub ignores drag and drop and Finder copies can land as zero-byte files, so SimDrop
writes straight into the Files app's "On My iPhone" storage with `rsync`, and uses `simctl`
for everything else.

## What it does

| Drop | Goes to |
| --- | --- |
| Images, videos, `.vcf` | Photos / Contacts (`simctl addmedia`) |
| `.app` bundle | Installed (`simctl install`) |
| Anything else, including folders | Files › On My iPhone |

Destination can be forced to **Files**, **Photos**, or an installed **App**'s `Documents` folder.
It sends to every booted simulator that's checked. Also: push/pull the clipboard (`pbsync`),
open URLs/deep links, reveal the Files storage folder in Finder.

## Build

```sh
./scripts/build-app.sh          # -> build/SimDrop.app
cp -R build/SimDrop.app /Applications/
```

## CLI

The app binary doubles as a CLI:

```sh
ln -s /Applications/SimDrop.app/Contents/MacOS/SimDrop /usr/local/bin/simdrop

simdrop list
simdrop send backup.dat photos/*.heic          # all booted sims, auto-routed
simdrop send -d "iPhone 17 Pro" --files data/
simdrop send --app com.example.myapp seed.sqlite
simdrop clip-to-sim | clip-from-sim
simdrop open "myapp://settings"
```
