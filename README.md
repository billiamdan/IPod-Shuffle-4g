# Shuffler

A native macOS app for the iPod shuffle (3rd and 4th generation): copy music onto it, manage its
playlists, and give every song and playlist a spoken name for the VoiceOver button.

It replaces the Python script this repository started as and needs nothing installed besides
macOS 14 or later. The script, `ipod-shuffle-4g.py`, also runs on Linux and lives on in the
[project this one was forked from](https://github.com/nims11/IPod-Shuffle-4g).

## What it does

- **Adds music** by drag and drop or from a file dialog: MP3, AAC, Apple Lossless and WAV go over
  without re-encoding. AIFF, FLAC and anything high-resolution is converted to something the iPod
  plays, using the encoders built into macOS.
- **Manages playlists**: create, rename, delete, fill by dragging, reorder. "All Songs" can be
  reordered and sorted too.
- **Records VoiceOver announcements** with the voices that ship with macOS, in the layout Apple's
  own recordings on the iPod use. Titles in another alphabet are spoken with a matching voice.
  Wording and language can be set per song.
- **Per-song playback options** the iPod supports: remember the playback position (useful for long
  mixes and audiobooks) and skip when shuffling.
- **Reads what is already there**: music synced earlier by Finder keeps its titles, playlists and
  recordings.
- **Keeps Finder in the picture**: Finder lists an iPod's songs from a second file on it, Apple's
  library file. Shuffler updates that file along with the play database, so a song removed or added
  here is removed or added there too.
- **Is careful with the device**: an iPod it has not changed before is only read until you change
  something; the files about to be replaced are copied to the Mac before the first change of a
  session; each is replaced in one step and checked afterwards.

## Install

Build the disk image (see below), open `dist/Shuffler-<version>.dmg` and drag Shuffler to
Applications. The first time it sees the iPod, macOS asks whether the app may access files on a
removable volume.

An image built this way is signed for the Mac that built it. To hand it to other people it has to be
signed with a Developer ID and notarized; `scripts/build-app.sh` does both when given the identity.

## Build

Requires a Swift 6 toolchain (developed with Xcode 27).

```bash
swift test                # no iPod needed
```

```bash
scripts/build-app.sh      # dist/Shuffler.app and dist/Shuffler-2.0.0.dmg
```

Settings for the build script are environment variables: `VERSION`, `ARCHS` (default
`"arm64 x86_64"`), `SIGN_IDENTITY` (default ad-hoc), `NOTARY_PROFILE`, `BUNDLE_ID`.

## Using the app

Connect the iPod; it appears on its own. The sidebar lists "All Songs" and the playlists, the table
shows songs in the order the iPod plays them, and the panel on the right (toolbar button, or
double-click a song) shows details of the selection.

- Drag songs or folders from Finder onto the list, or onto a playlist in the sidebar.
- Drag rows to reorder them; drag them onto a playlist to add them.
- Delete removes songs from a playlist. In "All Songs" it removes them from the iPod, after asking.
- Changes are written a moment after you make them. The status bar says when everything is saved.
- Use the Eject button (or ⌘E) before unplugging.

VoiceOver language, voice and wording are in Settings; so is what to do with lossless music, which
is large for a 2 GB player.

## Command line

The app bundle carries the same engine as a terminal tool:
`Shuffler.app/Contents/MacOS/shufflectl` (or `swift run shufflectl`).

```
shufflectl devices
shufflectl info
shufflectl list [--playlist NAME]
shufflectl add FILE|FOLDER... [--playlist NAME] [--lossless keep|alac|aac]
shufflectl remove TRACK...
shufflectl set TRACK [--title T] [--artist A] [--say TEXT] [--language TAG] [--remember on|off] [--skip-shuffle on|off]
shufflectl playlist create|delete|rename|add|remove ...
shufflectl voiceover on|off|rebuild
shufflectl sync
shufflectl check
shufflectl cleanup [--yes]
shufflectl dump
```

`--device PATH` selects an iPod when several are connected, or points at a folder laid out like one.
`sync` writes what is pending without changing anything else: plays the iPod recorded, and Finder's
list of songs if it has fallen behind. `check` says whether there is anything of the kind.

## How it works

The iPod's firmware plays from one small binary file, `iPod_Control/iTunes/iTunesSD`. It lists the
tracks (path, a type code that selects the decoder, playback options) and the playlists, and
contains no text at all: names exist only as recordings in `iPod_Control/Speakable`. The format is
described in [docs/iTunesSD3gen.md](docs/iTunesSD3gen.md); the layout Apple's current sync writes
differs slightly and is documented in
[ShuffleDatabase.swift](Sources/ShuffleKit/Database/ShuffleDatabase.swift).

Next to it lies `iTunesDB`, the library file of Apple's own software: titles, albums, playlists by
name, play counts. The iPod never reads it, but Finder does, and lists the iPod's songs from it.
Shuffler edits it in place rather than rebuilding it: records of removed songs go, songs and playlists
made here get records shaped like the ones Apple wrote, and everything else stays byte for byte as it
was. The file is only touched if it can be read completely and written back identically first; the
layout is described in [AppleLibraryFile.swift](Sources/ShuffleKit/Library/AppleLibraryFile.swift)
and [AppleLibraryMirror.swift](Sources/ShuffleKit/Library/AppleLibraryMirror.swift).

| On the iPod | Purpose | Shuffler |
|---|---|---|
| `iPod_Control/iTunes/iTunesSD` | play database | reads and writes |
| `iPod_Control/iTunes/iTunesStats` | play counts and resume positions, written by the iPod | reads, then resets |
| `iPod_Control/iTunes/iTunesDB` | Apple's library file, which Finder shows | reads titles from it; keeps it in step |
| `iPod_Control/Music/F00`–`F02` | the music, under short names | adds and removes files |
| `iPod_Control/Speakable/Tracks`, `Playlists` | announcements | adds and removes recordings |
| `iPod_Control/Speakable/Messages`, `System` | system prompts ("Battery low") | leaves alone |
| `iPod_Control/Shuffler/library.json` | titles, playlist names, what was last written | its own notes |

Backups of both databases go to `~/Library/Application Support/Shuffler/Backups` (iPod menu ▸ Show
Backups in Finder), the last 20 per iPod.

## Good to know

- **Finder sees what Shuffler did, but its sync still follows the Mac's music library.** A sync
  from Finder makes the iPod match what is ticked there: a song removed here comes back if it is
  still selected in Finder, and one added here may be taken off again. Shuffler notices, reloads,
  and keeps what it knew about songs that are still there; files left belonging to nothing can be
  cleared with iPod menu ▸ Remove Unused Files. Turning off automatic syncing for the iPod in
  Finder avoids surprises.
- **Finder reads the iPod when it is connected.** A change made here shows in Finder after the iPod
  has been ejected and connected again.
- **Apple's library file is updated, never invented.** An iPod that has none (it was never synced by
  Apple's software) does not get one, and a file Shuffler cannot reproduce exactly is left as it is;
  `shufflectl check` says so. The iPod plays the same either way.
- **An iPod Shuffler already changed is brought in line on opening.** Earlier builds left Apple's
  file alone, so Finder kept listing removed songs. Opening such an iPod now corrects the file once,
  after a backup. An iPod Shuffler has never written is not touched until you change something.
- **Podcast and audiobook lists** from Apple's sync are shown as ordinary playlists.
- **System prompts** stay in the language they were installed in.
- **Copy-protected purchases** cannot be added; only Apple's sync can authorise an iPod for them.

## Development

```
Sources/ShuffleKit   everything that touches the iPod; no UI (database codec, import, VoiceOver, sync)
Sources/Shuffler     the SwiftUI app
Sources/shufflectl   the terminal tool
Tests/               tests, including fixtures of real databases and of Apple's library file
scripts/             app bundle, disk image and icon
```

A folder can stand in for an iPod, which is how everything is tested without the device:

```bash
SHUFFLER_DEVICE=/path/to/folder-with-iPod_Control swift run Shuffler
```

`SHUFFLER_SNAPSHOT=/tmp/window.png` makes the app draw its windows into PNG files and quit (see
[Snapshot.swift](Sources/Shuffler/Support/Snapshot.swift)); `SHUFFLER_BACKUP_DIR` redirects backups.

## Licence

Copyright © 2026 billiamdan. Shuffler is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free Software Foundation,
either version 2 of the License, or (at your option) any later version. It comes with no warranty.
The full text is in [COPYING](COPYING); each source file carries the short form,
`SPDX-License-Identifier: GPL-2.0-or-later`.

The disk image contains the licence and a note naming the commit it was built from. When you pass
the image on, make that source available as well, for example by publishing the image as a release
of this repository.

The two pages in [docs](docs) are copies of a wiki that never stated a licence. They are kept for
reference and are not covered by the statement above ([docs/README.md](docs/README.md)).

iPod is a trademark of Apple Inc. Shuffler is not affiliated with or endorsed by Apple.

## Credits and further reading

Shuffler grew out of [IPod-Shuffle-4g](https://github.com/nims11/IPod-Shuffle-4g), a Python script
by Nimesh Ghelani, NicoHood and contributors, which was based on
[shuffle-db-ng](https://code.google.com/p/shuffle-db-ng/) by ikelos. Shuffler is written anew in
Swift; their work and the format descriptions below showed the way.

- [shuffle3db specification](docs/iTunesSD3gen.md) and [iTunesStats](docs/iTunesStats3gen.md)
  (copies of the vanished wiki; [original via the Wayback Machine](https://web.archive.org/web/20131016014401/http://shuffle3db.wikispaces.com/iTunesSD3gen))
- [gtkpod](http://www.gtkpod.org/wiki/Home) and libgpod, the reference implementation on Linux
- [iPod management apps (Arch wiki)](https://wiki.archlinux.org/index.php/IPod#iPod_management_apps)
