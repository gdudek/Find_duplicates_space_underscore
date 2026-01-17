# Find duplicates space underscore

Utility script to find duplicate files whose names differ only by spaces vs underscores, using size tolerance and audio matching, with optional cleanup.

## Usage

```bash
./find_space_underscore_dupes.sh --dir . --tolerance 1024
./find_space_underscore_dupes.sh --dir . --tolerance 0 --delete
```

Run `./find_space_underscore_dupes.sh --help` for full options.
