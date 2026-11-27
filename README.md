# Shuffler

A native macOS app for the iPod shuffle (3rd and 4th generation): copy music onto it, manage its
playlists, and give every song and playlist a spoken name for the VoiceOver button.

It replaces the Python script this repository started as (still here, see
[Legacy script](#legacy-script)) and needs nothing installed besides macOS 14 or later.

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
- **Is careful with the device**: opening never writes; the previous database is copied to the Mac
  before the first change of a session; the database is replaced in one step and checked afterwards.

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
shufflectl check
shufflectl cleanup [--yes]
shufflectl dump
```

`--device PATH` selects an iPod when several are connected, or points at a folder laid out like one.

## How it works

The iPod's firmware plays from one small binary file, `iPod_Control/iTunes/iTunesSD`. It lists the
tracks (path, a type code that selects the decoder, playback options) and the playlists, and
contains no text at all: names exist only as recordings in `iPod_Control/Speakable`. The format is
described in [docs/iTunesSD3gen.md](docs/iTunesSD3gen.md); the layout Apple's current sync writes
differs slightly and is documented in
[ShuffleDatabase.swift](Sources/ShuffleKit/Database/ShuffleDatabase.swift).

| On the iPod | Purpose | Shuffler |
|---|---|---|
| `iPod_Control/iTunes/iTunesSD` | play database | reads and writes |
| `iPod_Control/iTunes/iTunesStats` | play counts and resume positions, written by the iPod | reads, then resets |
| `iPod_Control/iTunes/iTunesDB` | Apple's library file | reads titles from it, never writes |
| `iPod_Control/Music/F00`–`F02` | the music, under short names | adds and removes files |
| `iPod_Control/Speakable/Tracks`, `Playlists` | announcements | adds and removes recordings |
| `iPod_Control/Speakable/Messages`, `System` | system prompts ("Battery low") | leaves alone |
| `iPod_Control/Shuffler/library.json` | titles, playlist names, what was last written | its own notes |

Backups of the database go to `~/Library/Application Support/Shuffler/Backups` (iPod menu ▸ Show
Backups in Finder), the last 20 per iPod.

## Good to know

- **Finder sync and Shuffler do not know about each other.** If Finder syncs the iPod it rewrites
  the database from the Mac's music library. Shuffler notices, reloads, and keeps what it knew about
  songs that are still there; songs it had added may be left behind as unused files (iPod menu ▸
  Remove Unused Files). Turning off automatic syncing for the iPod in Finder avoids surprises.
- **Podcast and audiobook lists** from Apple's sync are shown as ordinary playlists.
- **System prompts** stay in the language they were installed in.
- **Copy-protected purchases** cannot be added; only Apple's sync can authorise an iPod for them.

## Development

```
Sources/ShuffleKit   everything that touches the iPod; no UI (database codec, import, VoiceOver, sync)
Sources/Shuffler     the SwiftUI app
Sources/shufflectl   the terminal tool
Tests/               tests, including fixtures of real databases (one written by Apple's sync)
scripts/             app bundle, disk image and icon
```

A folder can stand in for an iPod, which is how everything is tested without the device:

```bash
SHUFFLER_DEVICE=/path/to/folder-with-iPod_Control swift run Shuffler
```

`SHUFFLER_SNAPSHOT=/tmp/window.png` makes the app draw its windows into PNG files and quit (see
[Snapshot.swift](Sources/Shuffler/Support/Snapshot.swift)); `SHUFFLER_BACKUP_DIR` redirects backups.

## Legacy script

`ipod-shuffle-4g.py` is the original command-line script (Python 3, optional
[Mutagen](https://mutagen.readthedocs.io)). It rebuilds the database from whatever files are already
on the iPod and is kept for Linux users:

```
$ ./ipod-shuffle-4g.py --help
usage: ipod-shuffle-4g.py [-h] [-t] [-p] [-u] [-g TRACK_GAIN]
                          [-d [AUTO_DIR_PLAYLISTS]] [-i [ID3_TEMPLATE]] [-v]
                          path
```

Two things it gets wrong that the new code does not: WAV files are given the MP3 type code, so the
iPod stays silent for them, and paths longer than 256 bytes are cut off without warning.

Its tips still apply when the iPod is managed from Linux:

- **Disable the trash**: an empty file named `.Trash-1000` in the iPod's root makes Linux delete
  files instead of moving them to a trash folder ([extras](extras)).
- **Rhythmbox**: put [extras/.is_audio_player](extras/.is_audio_player) in the iPod's root, disable
  Rhythmbox's iPod plugin and enable its MTP plugin; the script then picks up the `.pls` playlists
  Rhythmbox writes.
- **Reformatting**: the iPod has no partition table; create the FAT file system directly on the
  device (`sudo mkfs.vfat -I -F 16 -n IPOD /dev/sdX`), then rebuild the database.

## Credits and further reading

Forked from the [shuffle-db-ng project](https://code.google.com/p/shuffle-db-ng/), improved by
nims11 and NicoHood. Licensed under the GPL, version 2 ([COPYING](COPYING)).

- [shuffle3db specification](docs/iTunesSD3gen.md) and [iTunesStats](docs/iTunesStats3gen.md)
  (copies of the vanished wiki; [original via the Wayback Machine](https://web.archive.org/web/20131016014401/http://shuffle3db.wikispaces.com/iTunesSD3gen))
- [gtkpod](http://www.gtkpod.org/wiki/Home) and libgpod, the reference implementation on Linux
- [iPod management apps (Arch wiki)](https://wiki.archlinux.org/index.php/IPod#iPod_management_apps)
