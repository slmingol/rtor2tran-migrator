<div align="center">

```
 ██████╗ ████████╗  ██████╗ ██████╗     ██████╗ ████████╗██████╗   █████╗ ███╗  ██╗
 ██╔══██╗╚══██╔══╝ ██╔═══██╗██╔══██╗    ╚════██╗╚══██╔══╝██╔══██╗ ██╔══██╗████╗ ██║
 ██████╔╝   ██║    ██║   ██║██████╔╝     █████╔╝   ██║   ██████╔╝ ███████║██╔██╗██║
 ██╔══██╗   ██║    ██║   ██║██╔══██╗    ██╔═══╝    ██║   ██╔══██╗ ██╔══██║██║╚████║
 ██║  ██║   ██║    ╚██████╔╝██║  ██║    ███████╗   ██║   ██║  ██║ ██║  ██║██║ ╚███║
 ╚═╝  ╚═╝   ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═╝  ╚═╝╚═╝  ╚══╝
```

**Migrate rtorrent session data to transmission — no re-hashing, no lost stats**

[![Release](https://img.shields.io/github/v/release/slmingol/rtor2tran-migrator?style=flat-square)](https://github.com/slmingol/rtor2tran-migrator/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/slmingol/rtor2tran-migrator/release.yml?label=build&style=flat-square)](https://github.com/slmingol/rtor2tran-migrator/actions/workflows/release.yml)
[![Release Please](https://img.shields.io/github/actions/workflow/status/slmingol/rtor2tran-migrator/release-please.yml?label=release-please&style=flat-square)](https://github.com/slmingol/rtor2tran-migrator/actions/workflows/release-please.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/slmingol/rtor2tran-migrator?style=flat-square)](go.mod)
[![Docker](https://img.shields.io/badge/ghcr.io-latest-blue?style=flat-square&logo=docker)](https://github.com/slmingol/rtor2tran-migrator/pkgs/container/rtor2tran-migrator)
[![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational?style=flat-square)](https://github.com/slmingol/rtor2tran-migrator/releases)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey?style=flat-square)](https://github.com/slmingol/rtor2tran-migrator/releases)

</div>

## How it works

For each torrent in the rtorrent session directory, the tool:

1. Reads `<HASH>.torrent.rtorrent` for upload stats, download directory, and timestamps
2. Reads `<HASH>.torrent.libtorrent_resume` for per-file modification times
3. Copies `<HASH>.torrent` into transmission's `torrents/` directory
4. Writes a `<hash>.resume` file into transmission's `resume/` directory with `progress.blocks = "all"`, which tells transmission the torrent is complete without triggering a re-hash

Infohashes are taken directly from filenames, so no torrent parsing is needed for that step.

## Prerequisites

- Go 1.21+ (build only; binaries available in [Releases](https://github.com/slmingol/rtor2tran-migrator/releases))
- rtorrent session files on disk (stop rtorrent before migrating so files are fully flushed)

## Install

Download a pre-built binary from [Releases](https://github.com/slmingol/rtor2tran-migrator/releases):

```bash
# Linux ARM64 (Raspberry Pi 4)
curl -L https://github.com/slmingol/rtor2tran-migrator/releases/latest/download/rtor2tran-migrator-linux-arm64 \
  -o rtor2tran-migrator && chmod +x rtor2tran-migrator

# Linux x86-64
curl -L https://github.com/slmingol/rtor2tran-migrator/releases/latest/download/rtor2tran-migrator-linux-amd64 \
  -o rtor2tran-migrator && chmod +x rtor2tran-migrator
```

Or run via Docker (no Go required):

```bash
docker run --rm \
  -v ~/rtorrent/sessions:~/rtorrent/sessions:ro \
  -v /var/lib/transmission-daemon/.config/transmission-daemon:/var/lib/transmission-daemon/.config/transmission-daemon \
  ghcr.io/slmingol/rtor2tran-migrator:latest \
  --session-dir ~/rtorrent/sessions \
  --output-dir /var/lib/transmission-daemon/.config/transmission-daemon
```

## Build from source

```bash
# Build for the current machine
make build

# Build for Raspberry Pi 4 (ARM64) -- most common target
make linux-arm64

# Build for x86-64 Linux
make linux-amd64

# Build all targets at once
make all
```

Binaries are placed in `dist/`. The version string is injected at build time from the current git tag (falls back to `dev` if no tag).

## Migration steps

### 1. Stop rtorrent

Ensures all session state is flushed to disk before reading it.

```bash
systemctl stop rtorrent
# or: killall rtorrent
```

### 2. Copy the binary to your server

```bash
make deploy
# or manually:
scp dist/rtor2tran-migrator-linux-arm64 root@pi-vpn:~/rtor2tran-migrator/dist/
```

### 3. Dry-run a single torrent first

List available hashes to pick one:

```bash
make list-hashes
```

Then dry-run it:

```bash
make test-one HASH=<hash from above>
```

Or with file copy to verify the full path:

```bash
make test-one HASH=<hash> COPY_FILES=1
```

### 4. Inspect the output

Confirm the dry-run shows a sensible destination path and that the files exist where expected. Then run for real:

```bash
make migrate-one HASH=<hash>
# or with file copy:
make migrate-one HASH=<hash> COPY_FILES=1
```

Spot-check the generated resume file:

```bash
strings /var/lib/transmission-daemon/.config/transmission-daemon/resume/<hash>.resume
```

You should see the download path, a non-zero uploaded bytes value, and `3:all` (the bencoded encoding of `"all"`) for the progress blocks.

### 5. Start transmission and verify

```bash
systemctl start transmission-daemon
transmission-remote -l
```

The test torrent should appear as **Seeding**, not Checking or Stopped. Upload stats should reflect what rtorrent had accumulated.

### 6. Migrate everything

Once the single-torrent test passes:

```bash
make migrate
# or with file copy to transmission's download dir:
make migrate COPY_FILES=1
```

Then restart transmission to pick up all the new files:

```bash
systemctl restart transmission-daemon
```

### Example output

```
$ make migrate FORCE=1

Running migration
────────────────────────────────────────
 ▶ SESSION_DIR=~/rtorrent/sessions
 ▶ OUTPUT_DIR=/var/lib/transmission-daemon/.config/transmission-daemon
 ! Transmission must be stopped before running

✔  1a2b3c4d  Some.Movie.2019.1080p.WEB-DL.x264
✔  2b3c4d5e  Some Artist - Greatest Hits (2002) [FLAC]
✔  3c4d5e6f  Some.TV.Show.S09.Complete.1080p.WEB-DL.X265
✔  4d5e6f7a  Some Movie (2015) [BluRay] [720p] [YTS.AM]
✔  5e6f7a8b  Some Book Title - Author Name.epub
  ... 51 more ...

  ✔  56 migrated    ○  0 skipped    ✗  0 errors
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--session-dir` | *(required)* | rtorrent sessions directory |
| `--output-dir` | *(required)* | Transmission config directory |
| `--download-dir` | *(from session)* | Override the download root path. Use this when migrating files to a different machine or path. |
| `--only` | | Migrate a single torrent by infohash. Case-insensitive. Useful for testing. |
| `--dry-run` | `false` | Print what would happen without writing any files. |
| `--force` | `false` | Overwrite existing files in the output directory. |
| `--incomplete` | `false` | Also migrate incomplete torrents. The piece bitfield is copied from `libtorrent_resume`; transmission will verify on first run. |
| `--version` | | Print version and exit. |

## Notes

- **Architecture**: The Raspberry Pi 4 uses ARM64. Use `make linux-arm64` and the `dist/rtor2tran-migrator-linux-arm64` binary, or `make deploy` to build and push in one step.
- **Transmission config dir**: When transmission-daemon runs as a system user (e.g. `debian-transmission`), its config is at `/var/lib/transmission-daemon/.config/transmission-daemon`, not `~/.config/transmission-daemon`. Check with `find /var/lib/transmission-daemon -name "settings.json"`.
- **Download paths**: If the rtorrent `directory` field ends with the torrent name (e.g. `/downloads/Movie Name/`), the tool automatically strips the trailing component so transmission's `destination` points to the parent, which is what transmission expects.
- **Incomplete torrents**: Omitted by default. Pass `--incomplete` to include them. Transmission will do a hash-check pass on first run to confirm which pieces are present.
- **Re-running / resuming**: The tool skips torrents that already have a `.resume` file in the output directory, so it is safe to Ctrl-C and re-run — completed torrents are skipped and only the interrupted one is retried. Use `--force` to overwrite everything.
- **Versioning**: Releases are managed by [release-please](https://github.com/googleapis/release-please). Merge a PR with conventional commits (`feat:`, `fix:`, `chore:`) and release-please will open a version-bump PR automatically.
