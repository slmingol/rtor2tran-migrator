package main

import (
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/zeebo/bencode"
)

const (
	ansiReset  = "\033[0m"
	ansiBold   = "\033[1m"
	ansiDim    = "\033[2m"
	ansiRed    = "\033[31m"
	ansiGreen  = "\033[32m"
	ansiYellow = "\033[33m"
	ansiBlue   = "\033[34m"
	ansiCyan   = "\033[36m"
)

// rtState is parsed from <HASH>.torrent.rtorrent
type rtState struct {
	Complete          int64  `bencode:"complete"`
	ChunksDone        int64  `bencode:"chunks_done"`
	ChunksWanted      int64  `bencode:"chunks_wanted"`
	Directory         string `bencode:"directory"`
	StateChanged      int64  `bencode:"state_changed"`
	TimestampStarted  int64  `bencode:"timestamp.started"`
	TimestampFinished int64  `bencode:"timestamp.finished"`
	TotalUploaded     int64  `bencode:"total_uploaded"`
}

// rtLibResume is parsed from <HASH>.torrent.libtorrent_resume
type rtLibResume struct {
	Bitfield []byte `bencode:"bitfield"`
	Files    []struct {
		Mtime    int64 `bencode:"mtime"`
		Priority int64 `bencode:"priority"`
	} `bencode:"files"`
}

// torrentInfoDict is the info dict inside a .torrent file
type torrentInfoDict struct {
	Name        string `bencode:"name"`
	PieceLength int64  `bencode:"piece length"`
	Length      int64  `bencode:"length"` // single-file torrents
	Files       []struct {
		Length int64    `bencode:"length"`
		Path   []string `bencode:"path"`
	} `bencode:"files"`
}

const (
	transferNone = ""
	transferMove = "move"
	transferCopy = "copy"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("rtor2tran: ")

	var (
		printVersion = flag.Bool("version", false, "print version and exit")
		sessDir      = flag.String("session-dir", "", "rtorrent sessions directory (required)")
		outputDir    = flag.String("output-dir", "", "transmission config directory, e.g. ~/.config/transmission-daemon (required)")
		downloadDir = flag.String("download-dir", "", "override download root from rtorrent state (useful when migrating across machines)")
		dryRun      = flag.Bool("dry-run", false, "print actions without writing files")
		force       = flag.Bool("force", false, "overwrite existing files in output-dir")
		incomplete  = flag.Bool("incomplete", false, "also migrate incomplete torrents (bitfield copied from libtorrent_resume; transmission will verify on first run)")
		onlyHash    = flag.String("only", "", "migrate a single torrent by infohash (for testing)")
		moveFiles   = flag.Bool("move-files", false, "move media files from rtorrent directory to download-dir")
		copyFiles   = flag.Bool("copy-files", false, "copy media files from rtorrent directory to download-dir (safer; keeps originals)")
	)
	flag.Parse()

	if *printVersion {
		fmt.Println(version)
		os.Exit(0)
	}

	if *sessDir == "" || *outputDir == "" {
		fmt.Fprintln(os.Stderr, "usage: rtor2tran-migrator --session-dir <path> --output-dir <path> [flags]")
		fmt.Fprintln(os.Stderr)
		flag.PrintDefaults()
		os.Exit(1)
	}

	transferMode := transferNone
	if *moveFiles {
		transferMode = transferMove
	}
	if *copyFiles {
		transferMode = transferCopy // copy wins over move if both set
	}

	torrentOutDir := filepath.Join(*outputDir, "torrents")
	resumeOutDir := filepath.Join(*outputDir, "resume")

	if !*dryRun {
		for _, dir := range []string{torrentOutDir, resumeOutDir} {
			if err := os.MkdirAll(dir, 0755); err != nil {
				log.Fatalf("create %s: %v", dir, err)
			}
		}
	}

	entries, err := os.ReadDir(*sessDir)
	if err != nil {
		log.Fatalf("read session dir: %v", err)
	}

	filterHash := strings.ToUpper(strings.TrimSpace(*onlyHash))

	var migrated, skipped, errored int
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".torrent.rtorrent") {
			continue
		}

		if filterHash != "" && !strings.EqualFold(strings.TrimSuffix(name, ".torrent.rtorrent"), filterHash) {
			continue
		}

		hashUpper := strings.TrimSuffix(name, ".torrent.rtorrent")
		hashLower := strings.ToLower(hashUpper)

		statePath := filepath.Join(*sessDir, name)
		torrentPath := filepath.Join(*sessDir, hashUpper+".torrent")
		libResumePath := filepath.Join(*sessDir, hashUpper+".torrent.libtorrent_resume")

		torrentName, skipReason, err := migrate(
			hashLower, statePath, torrentPath, libResumePath,
			torrentOutDir, resumeOutDir,
			*downloadDir,
			transferMode,
			*dryRun, *force, *incomplete,
		)
		if err != nil {
			fmt.Printf("%s✗%s  %s%s%s  %s\n", ansiRed, ansiReset, ansiDim, hashLower[:8], ansiReset, err)
			errored++
			continue
		}
		if skipReason != "" {
			fmt.Printf("%s○%s  %s%s%s  %s%s%s  %s(%s)%s\n",
				ansiYellow, ansiReset,
				ansiDim, hashLower[:8], ansiReset,
				ansiDim, torrentName, ansiReset,
				ansiDim, skipReason, ansiReset)
			skipped++
		} else {
			status := ansiGreen + "✔" + ansiReset
			if *dryRun {
				status = ansiCyan + "◇" + ansiReset
			}
			fmt.Printf("%s  %s%s%s  %s%s%s\n",
				status,
				ansiDim, hashLower[:8], ansiReset,
				ansiBold, torrentName, ansiReset)
			migrated++
		}
	}

	fmt.Printf("\n  %s✔%s  %d migrated    %s○%s  %d skipped    %s✗%s  %d errors\n",
		ansiGreen, ansiReset, migrated,
		ansiYellow, ansiReset, skipped,
		ansiRed, ansiReset, errored)

	if errored > 0 {
		os.Exit(1)
	}
}

func migrate(
	hashLower, statePath, torrentPath, libResumePath string,
	torrentOutDir, resumeOutDir string,
	downloadDirOverride string,
	transferMode string,
	dryRun, force, includeIncomplete bool,
) (torrentName, skipReason string, err error) {

	// Parse rtorrent state file
	stateBytes, err := os.ReadFile(statePath)
	if err != nil {
		return "", "", fmt.Errorf("read state: %w", err)
	}
	var state rtState
	if err := bencode.DecodeBytes(stateBytes, &state); err != nil {
		return "", "", fmt.Errorf("decode state: %w", err)
	}

	if state.Complete != 1 && !includeIncomplete {
		return "(incomplete)", "use --incomplete to migrate", nil
	}

	// Parse torrent file
	torrentBytes, err := os.ReadFile(torrentPath)
	if err != nil {
		return "", "", fmt.Errorf("read torrent: %w", err)
	}
	var torrentFile struct {
		Info torrentInfoDict `bencode:"info"`
	}
	if err := bencode.DecodeBytes(torrentBytes, &torrentFile); err != nil {
		return "", "", fmt.Errorf("decode torrent: %w", err)
	}
	info := torrentFile.Info
	torrentName = info.Name

	// Parse libtorrent_resume (best-effort)
	var libResume rtLibResume
	if lrBytes, readErr := os.ReadFile(libResumePath); readErr == nil {
		_ = bencode.DecodeBytes(lrBytes, &libResume)
	}

	// Compute file count, total size, and per-file mtimes
	numFiles := 1
	var totalSize int64
	if len(info.Files) > 0 {
		numFiles = len(info.Files)
		for _, f := range info.Files {
			totalSize += f.Length
		}
	} else {
		totalSize = info.Length
	}

	mtimes := make([]int64, numFiles)
	for i, f := range libResume.Files {
		if i < numFiles {
			mtimes[i] = f.Mtime
		}
	}

	// Determine destination directory.
	// rtorrent sometimes stores the full path including the torrent name as the
	// last component; transmission's destination is always the parent directory.
	dlDir := expandTilde(state.Directory)
	if downloadDirOverride != "" {
		dlDir = expandTilde(downloadDirOverride)
	}
	if dlDir == "" {
		return torrentName, "", fmt.Errorf("no download directory in state file; set --download-dir")
	}
	// Strip trailing torrent name if present so transmission can find the files.
	if len(info.Files) > 0 && filepath.Base(strings.TrimRight(dlDir, "/")) == info.Name {
		dlDir = filepath.Dir(strings.TrimRight(dlDir, "/"))
	}

	// Compute file transfer source/dest paths
	mediaSrc, mediaDst := mediaTransferPaths(expandTilde(state.Directory), dlDir, info.Name, len(info.Files) > 0)

	// Check for existing output files
	destTorrent := filepath.Join(torrentOutDir, hashLower+".torrent")
	destResume := filepath.Join(resumeOutDir, hashLower+".resume")

	if !force {
		if _, statErr := os.Stat(destResume); statErr == nil {
			return torrentName, "already exists (use --force to overwrite)", nil
		}
	}

	// Build the progress subdictionary
	progress := map[string]interface{}{
		"mtimes": mtimes,
	}
	if state.Complete == 1 {
		progress["blocks"] = "all"
		progress["pieces"] = "all"
	} else if len(libResume.Bitfield) > 0 {
		progress["blocks"] = libResume.Bitfield
	}

	// Build the transmission resume dictionary
	resume := map[string]interface{}{
		"activity-date":      state.StateChanged,
		"added-date":         state.TimestampStarted,
		"bandwidth-priority": int64(0),
		"corrupt":            int64(0),
		"destination":        dlDir,
		"downloaded":         totalSize,
		"dnd":                make([]byte, numFiles), // 0 = download all files
		"file-priorities":    make([]byte, numFiles), // 0 = normal priority
		"mtimes":             mtimes,
		"progress":           progress,
		"uploaded":           state.TotalUploaded,
	}
	if state.TimestampFinished > 0 {
		resume["done-date"] = state.TimestampFinished
	}

	if dryRun {
		if transferMode != transferNone && mediaSrc != mediaDst {
			fmt.Printf("    %s%-8s%s  %s\n            %s→%s  %s\n",
				ansiYellow, transferMode, ansiReset, mediaSrc,
				ansiDim, ansiReset, mediaDst)
		}
		fmt.Printf("    %s%-8s%s  %s\n            %s→%s  %s\n",
			ansiCyan, "torrent", ansiReset, filepath.Base(torrentPath),
			ansiDim, ansiReset, destTorrent)
		fmt.Printf("    %s%-8s%s  %s→%s  %s\n",
			ansiBlue, "resume", ansiReset,
			ansiDim, ansiReset, destResume)
		return torrentName, "", nil
	}

	// Transfer media files first; if this fails we don't write transmission files
	if transferMode != transferNone && mediaSrc != mediaDst {
		verb := "copying"
		if transferMode == transferMove {
			verb = "moving"
		}
		fmt.Printf("    %s%-8s%s  %s\n            %s→%s  %s\n",
			ansiYellow, verb, ansiReset, mediaSrc,
			ansiDim, ansiReset, mediaDst)
		if err := transferMedia(mediaSrc, mediaDst, transferMode == transferMove); err != nil {
			return torrentName, "", fmt.Errorf("transfer media: %w", err)
		}
	}

	// Copy .torrent file
	if err := copyFile(torrentPath, destTorrent); err != nil {
		return torrentName, "", fmt.Errorf("copy torrent: %w", err)
	}

	// Encode and write .resume file
	resumeBytes, err := bencode.EncodeBytes(resume)
	if err != nil {
		return torrentName, "", fmt.Errorf("encode resume: %w", err)
	}
	if err := os.WriteFile(destResume, resumeBytes, 0644); err != nil {
		return torrentName, "", fmt.Errorf("write resume: %w", err)
	}

	return torrentName, "", nil
}

// mediaTransferPaths returns the source and destination paths for the media files.
func mediaTransferPaths(sourceDlDir, destDlDir, torrentName string, isMultiFile bool) (src, dst string) {
	rawSrc := strings.TrimRight(sourceDlDir, "/")

	if isMultiFile {
		if filepath.Base(rawSrc) == torrentName {
			src = rawSrc
		} else {
			src = filepath.Join(rawSrc, torrentName)
		}
	} else {
		src = filepath.Join(rawSrc, torrentName)
	}

	dst = filepath.Join(destDlDir, torrentName)
	return src, dst
}

// transferMedia moves or copies src to dst.
// For moves it tries os.Rename first; falls back to copy+delete on cross-device.
func transferMedia(src, dst string, move bool) error {
	if _, err := os.Stat(src); errors.Is(err, os.ErrNotExist) {
		log.Printf("warning: media source not found, skipping transfer: %s", src)
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return fmt.Errorf("create dest dir: %w", err)
	}

	if move {
		err := os.Rename(src, dst)
		if err == nil {
			return nil
		}
		if !isCrossDevice(err) {
			return err
		}
		if err := copyPath(src, dst); err != nil {
			return fmt.Errorf("cross-device copy: %w", err)
		}
		return os.RemoveAll(src)
	}

	return copyPath(src, dst)
}

func isCrossDevice(err error) bool {
	var linkErr *os.LinkError
	if errors.As(err, &linkErr) {
		return errors.Is(linkErr.Err, syscall.EXDEV)
	}
	return false
}

func copyPath(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyDir(src, dst)
	}
	return copyFile(src, dst)
}

func copyDir(src, dst string) error {
	if err := os.MkdirAll(dst, 0755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := copyPath(filepath.Join(src, entry.Name()), filepath.Join(dst, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst string) error {
	sf, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sf.Close()

	df, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer df.Close()

	_, err = io.Copy(df, sf)
	return err
}

// expandTilde replaces a leading ~ with the current user's home directory.
// Go does not shell-expand paths, so rtorrent session values containing ~/
// must be resolved before use with os.Stat or filepath operations.
func expandTilde(path string) string {
	if !strings.HasPrefix(path, "~/") && path != "~" {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, path[2:])
}

// infoHashFromFilename extracts the lowercase hex infohash from a session filename.
func infoHashFromFilename(name string) string {
	base := filepath.Base(name)
	base = strings.TrimSuffix(base, ".torrent.rtorrent")
	base = strings.TrimSuffix(base, ".torrent")
	if len(base) != 40 {
		return ""
	}
	b, err := hex.DecodeString(base)
	if err != nil || len(b) != 20 {
		return ""
	}
	return strings.ToLower(base)
}
