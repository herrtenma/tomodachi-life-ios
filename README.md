# Tomodachi Life: Living the Dream for iPhone

A native iOS port of *Tomodachi Life: Living the Dream* (Nintendo Switch). It is not an emulator: the game's own
ARM64 code runs directly on the iPhone's CPU, with the Switch's operating system services and its NVN graphics API
reimplemented on top of iOS and Metal.

**You bring the game.** Nothing of the game is in this repository or in its releases: you need your own dump of the
game and the keys from your own Switch. The [Packager app](https://github.com/herrtenma/nx-packager) turns them into
the playable app, on your phone.

> This project is not affiliated with, endorsed by or sponsored by Nintendo. *Tomodachi Life* and *Nintendo Switch*
> are trademarks of Nintendo. Do not open issues asking for game files or keys.

## What you need

| | |
|---|---|
| **The game** | *Tomodachi Life: Living the Dream*, **version 1.0.0** (title ID `010051F0207B2000`, title version 0), dumped from your cartridge as an **`.xci`**, without updates. (`.nsp` dumps aren't supported yet: the app reads the game's data from the dump while it runs, and only reads `.xci` so far.) The Packager checks the version and every file before it builds anything. |
| **Keys** | `prod.keys` dumped from your own Switch (e.g. with Lockpick_RCM). |
| **Device** | An iPhone or iPad with **6 GB of RAM or more** (iPhone 12 Pro and later Pro models, iPhone 14 and later, M-series iPads) on iOS 16.4 or later. The game needs about 3.2 GB while it runs. Tested on an iPhone 14. |
| **LiveContainer** (recommended) | [LiveContainer](https://github.com/khanhduytran0/LiveContainer), installed with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io). See *Install* for why. It is what the game was developed and tested in. |
| **Free space** | About 100 MB for the app, plus the game dump (the app reads the game's data straight from it). |

## Install

**Install LiveContainer first.** A free Apple ID can only have a few app IDs at a time (3 active apps, 10 new app IDs
per week), and every app you sideload uses one for 7 days. Apps that run *inside* LiveContainer don't use their own
app IDs, so the Packager and Tomodachi cost nothing extra. Install them any other way and each one takes a slot.

1. **Get LiveContainer** on your phone with SideStore or AltStore (follow
   [LiveContainer's own setup](https://github.com/khanhduytran0/LiveContainer#installation)) and open it once.
2. **Get the Packager.** Download `Packager.ipa` from [nx-packager's releases](https://github.com/herrtenma/nx-packager/releases),
   then in LiveContainer tap **+** and open it.
3. **Put your files in the Packager's folder** (**Files › LiveContainer › Packager**; if you skipped LiveContainer,
   **Files › On My iPhone › Packager**):
   - **`tomodachi.nxport`**, from this repository's [releases](../../releases)
   - your game dump, **`Tomodachi Life.xci`**
   - your **`prod.keys`**
4. **Build.** Open the Packager and tap **Build Tomodachi-<version>.ipa**. It checks the game, builds the app and
   saves the `.ipa` in the same folder.
5. **Add the game.** In LiveContainer tap **+** again and open that `.ipa`, then launch **Tomodachi**. It finds the
   `.xci` and `prod.keys` in the Packager's folder by itself. Keep the `.xci` there: the game reads its data from the
   dump while it runs.

Outside LiveContainer, install the `.ipa` with SideStore or AltStore, and put the `.xci` and `prod.keys` in
**Files › On My iPhone › Tomodachi** (or choose them on the first screen). The app asks for the *increased memory
limit* and *extended virtual addressing* entitlements; installers keep them only if your Apple ID allows it.

The first time you play, the game's shaders are translated on your phone as they appear, so new places can stutter
briefly; after that they load from the cache.

**Mac:** a Mac release will follow shortly after launch.

### Your save

**Import a save from an emulator:** in the launcher, **Settings › Islands › Import a save…**, choose the save folder
(or a `.zip` of it), then the island to put it in. Ryujinx, yuzu and its forks, and Checkpoint / JKSV backups all work:
pick the emulator's whole save folder, the app finds the right one (it must be for *Tomodachi Life: Living the
Dream*, `010051F0207B2000`). The island it replaces is kept in the app's folder as `save-before-import-<time>`. If the
file picker doesn't open files in your setup, put the save in **Files › Tomodachi › Import** and choose *Use the
Import folder*.
Where the emulator keeps it: Ryujinx `bis/user/save/<id>/0`; yuzu `nand/user/save/0000000000000000/<user id>/010051F0207B2000`.

### Updates, news and feedback

- The launcher checks this repository's [`news.json`](news.json) when it opens. A **news** button shows the latest patch
  notes, and a banner tells you when a newer version is out. Updating means a new `tomodachi.nxport`: download it from
  the [releases](../../releases) and rebuild with the Packager (your saves stay).
- The **feedback** button sends a bug report, crash report or suggestion with the game log (never your saves). After a
  crash the launcher offers to send one. Reports are rate limited.
- **Settings › Feedback › Respect silent mode** is off by default: the game plays even with the phone on silent. Turn
  it on to let the silent switch mute it.

## Features

- Full touch controls over the game's own interface (taps, swipes, pinch, long press, a floating Back button), game
  controllers, haptics.
- Widescreen (fills the whole screen instead of 16:9), MetalFX upscaling (Quality: 720p, Performance: 540p, shown at
  1080p), FXAA.
- Three save slots with island snapshots, a launcher with the game's own look that follows the time of day.
- Local save snapshots: every time the game saves, a copy is kept in the island's folder (`snapshots/`, the 8 newest).
- Save import from emulators, news and update notices, in-app feedback and crash reports.
- Online play (sharing an island with a friend, online Local Play) is **coming soon**.

## How it works

| Piece | Where |
|---|---|
| The game's NSOs are patched once, offline, so they can run as a normal iOS process (Horizon uses register x18, which Darwin reserves; system calls, thread-local storage and a few system registers are redirected). The changed words are this project's `port/patches/`. | `tools/nxrecomp/` |
| The patched code is linked into the app's binary in fixed slots; the released app has the slots empty, and the Packager fills them from your dump. iOS never has to make anything executable at run time. | `tools/nxrecomp/embed.py`, `port/` |
| The Switch's kernel (threads, synchronization, memory, IPC) and the services the game talks to (file system, HID, audio renderer, time, applets...) | `runtime/src/` |
| NVN, the Switch's graphics API, implemented on Metal | `runtime/src/gfx_*.m`, `nvn.c` |
| Shaders: translated on the device with Ryujinx's shader translator and SPIRV-Cross, compiled ahead of time into the app | `runtime/xlat/`, `runtime/src/shader_xlat.m` |

## Building from source

Requirements: macOS on Apple Silicon, the Xcode Command Line Tools, the [.NET 10 SDK](https://dotnet.microsoft.com),
and an iPhoneOS SDK (e.g. `iPhoneOS16.5.sdk` from [theos/sdks](https://github.com/theos/sdks/releases) in `~/sdks`).

```sh
make -C runtime/xlat RID=ios-arm64        # the on-device shader translator (NativeAOT static library)
make -C ios                               # ios/build/Payload/nxrt.app: the app, game slots empty
make -C ios pack                          # ios/build/tomodachi.nxport: the port pack for the Packager
```

The Mac build (`make -C runtime`, then `runtime/build/nxrt <dir with the patched NSOs>`) is the development target:
the same runtime with an AppKit launcher, mouse and keyboard controls.

## Credits and license

The code of this project is licensed under the [GNU General Public License v3.0](LICENSE).

It stands on the work of the Switch homebrew and emulation communities: **Ryujinx** (its shader translator is
included, and its source documented much of the hardware and the services), **Atmosphère**, **yuzu**, **switchbrew**,
**hactool** and **libnx**, as well as **SPIRV-Cross**, **Zstandard**, **bcdec** and **.NET NativeAOT**. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what is used where, and under which license.

The launcher plays tracks from the game's soundtrack (`ios/music/`); all other game content (code, graphics, sound,
text) comes only from the user's own dump at run time.
