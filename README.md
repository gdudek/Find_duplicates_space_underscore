# Find duplicates space underscore

Utility script to find duplicate files whose names differ only by spaces vs underscores, using size tolerance and audio matching, with optional cleanup.

## Usage

```bash
./find_space_underscore_dupes.sh --dir . --tolerance 1024
./find_space_underscore_dupes.sh --dir . --tolerance 0 --delete
```

Run `./find_space_underscore_dupes.sh --help` for full options.

## Installation and requirements

This is a standalone Bash script. Place it anywhere on your PATH or run it from its directory.

Requirements:
- **bash** (uses associative arrays; `sh` won’t work)
- **ffprobe** (required for audio signatures; comes with ffmpeg)
- **ffmpeg** (required for `--audio-hash=stream|samples`)

On macOS (Homebrew):
```bash
brew install ffmpeg
```

On Ubuntu/Debian:
```bash
sudo apt-get install ffmpeg
```

If `ffprobe` is missing, audio signature matching is disabled and only size tolerance is used.

## Options and behavior

The script groups files whose names differ only by spaces vs underscores. It then decides whether to report a group as a duplicate based on size tolerance and/or audio matching.

### `--dir DIR`
Directory to scan (non-recursive). Default: current directory.

### `--tolerance BYTES`
Maximum size difference (bytes) to still consider files duplicates **by size**. Default: `0`.

Justification: some outputs only differ by ID3 padding or cover art. A small tolerance lets those collapse without relying on audio signatures.

### `--audio-hash=probe|stream|samples|off`
Controls how audio equivalence is detected when size does **not** match:

- `probe` (default): compares a fast audio signature based on `ffprobe` output: sample rate, channels, bitrate, and duration (rounded to milliseconds).  
  **Pros:** very fast, works well for long files.  
  **Cons:** heuristic — two different files with identical params could collide (rare for audiobooks).

- `stream`: hashes the compressed audio stream (`ffmpeg -map 0:a:0 -c copy -f md5`).  
  **Pros:** ignores tags/cover art and is more reliable than `probe`.  
  **Cons:** can be slow for very long files.

- `samples`: hashes decoded audio samples (`ffmpeg -map 0:a:0 -f md5`).  
  **Pros:** strictest, detects any audio difference.  
  **Cons:** slowest — decodes the entire file.

- `off`: disables audio matching and only uses size tolerance.

### `--delete=underscores|spaces|smaller|larger`
After printing matches, delete one side of each duplicate group:

- `underscores`: delete files containing `_` and no spaces (keeps spaced names).
- `spaces`: delete files containing spaces (keeps underscored names).
- `smaller`: delete all but the largest file in the group.
- `larger`: delete all but the smallest file in the group.

If you pass `--delete` with no mode, it defaults to `underscores`.

### `--yes`
Skip per-file confirmation when deleting.

### `-h`, `--help`
Print usage and exit.

## How flags interact

1) **Grouping** is always by normalized name (spaces → underscores).  
2) A group is **reported** if:
   - any pair is within size tolerance **OR**
   - audio matching (per `--audio-hash`) finds identical audio.  
3) If `--delete` is set, deletion is applied **after** a group is reported.

Recommended defaults:
- For large libraries: `--audio-hash=probe` (default) + small `--tolerance` (e.g., 1024).
- For exact audio verification: `--audio-hash=stream` or `--audio-hash=samples`.
