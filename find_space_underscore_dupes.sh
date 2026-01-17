#!/usr/bin/env bash
set -euo pipefail

# This script uses bash features (associative arrays).
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "Please run with bash: ./find_space_underscore_dupes.sh or bash find_space_underscore_dupes.sh" >&2
  exit 2
fi

# Find files in the given directory (default: current dir) whose names only differ
# by spaces vs underscores and punctuation (case-insensitive), and whose sizes
# match within a tolerance, or whose audio streams are identical (ignoring cover art/tags).
# Usage: ./find_space_underscore_dupes.sh [dir] [tolerance_bytes]
#        ./find_space_underscore_dupes.sh --dir DIR --tolerance BYTES [--recursive] [--approx-even-for-non-media] [--delete=underscores|spaces|smaller|larger] [--audio-hash=probe|stream|samples|off] [--yes]
#        ./find_space_underscore_dupes.sh -h|--help

dir="."
tolerance="0"
dir_set=0
tolerance_set=0
delete_mode=""
assume_yes=0
audio_hash_mode="probe"
recursive=0
approx_non_media=0

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'USAGE'
Usage:
  find_space_underscore_dupes.sh [dir] [tolerance_bytes] [--recursive] [--approx-even-for-non-media] [--delete=underscores|spaces|smaller|larger] [--audio-hash=probe|stream|samples|off] [--yes]
  find_space_underscore_dupes.sh --dir DIR --tolerance BYTES [--recursive] [--approx-even-for-non-media] [--delete=underscores|spaces|smaller|larger] [--audio-hash=probe|stream|samples|off] [--yes]
  find_space_underscore_dupes.sh -h|--help

Notes:
  - Matches files whose names only differ by spaces vs underscores.
  - Reports matches if sizes are within tolerance OR audio streams are identical (ignores cover art/tags).
  - --delete removes duplicates after printing; use --yes to skip prompts.
  - --recursive scans subdirectories and matches across the full subtree.
  - For non-media files, size must match exactly unless --approx-even-for-non-media is set.
  - --audio-hash=probe uses ffprobe audio params (fast, heuristic).
  - --audio-hash=stream hashes the compressed audio stream (slow for long files).
  - --audio-hash=samples hashes decoded audio samples (slowest, strict).
  - --audio-hash=off disables audio hashing.
USAGE
      exit 0
      ;;
    --dir=*)
      dir="${arg#*=}"
      dir_set=1
      ;;
    --dir)
      need_dir=1
      continue
      ;;
    --tolerance=*)
      tolerance="${arg#*=}"
      tolerance_set=1
      ;;
    --tolerance)
      need_tol=1
      continue
      ;;
    --recursive)
      recursive=1
      ;;
    --approx-even-for-non-media)
      approx_non_media=1
      ;;
    --audio-hash=*)
      audio_hash_mode="${arg#*=}"
      ;;
    --delete=*)
      delete_mode="${arg#*=}"
      ;;
    --delete)
      need_delete=1
      delete_mode="underscores"
      continue
      ;;
    --yes)
      assume_yes=1
      ;;
    *)
      if [[ "${need_dir:-0}" == "1" ]]; then
        dir="$arg"
        dir_set=1
        need_dir=0
        continue
      fi
      if [[ "${need_tol:-0}" == "1" ]]; then
        tolerance="$arg"
        tolerance_set=1
        need_tol=0
        continue
      fi
      if [[ "${need_delete:-0}" == "1" ]]; then
        if [[ "$arg" == --* ]]; then
          need_delete=0
        else
          delete_mode="$arg"
          need_delete=0
          continue
        fi
      fi
      if (( ! dir_set )); then
        dir="$arg"
        dir_set=1
      elif (( ! tolerance_set )); then
        tolerance="$arg"
        tolerance_set=1
      else
        echo "Unknown argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

if ! [[ "$tolerance" =~ ^[0-9]+$ ]]; then
  echo "Tolerance must be a non-negative integer (bytes): $tolerance" >&2
  exit 1
fi

if [[ -n "$delete_mode" ]]; then
  case "$delete_mode" in
    underscores|spaces|smaller|larger) ;;
    *)
      echo "Invalid --delete mode: $delete_mode (use underscores|spaces|smaller|larger)" >&2
      exit 1
      ;;
  esac
fi

if [[ "$audio_hash_mode" != "probe" && "$audio_hash_mode" != "stream" && "$audio_hash_mode" != "samples" && "$audio_hash_mode" != "off" ]]; then
  echo "Invalid --audio-hash mode: $audio_hash_mode (use probe|stream|samples|off)" >&2
  exit 1
fi

if [[ ! -d "$dir" ]]; then
  echo "Directory not found: $dir" >&2
  exit 1
fi

if [[ -x "/Users/dudek/bin/ffmpeg" ]]; then
  FFMPEG="/Users/dudek/bin/ffmpeg"
else
  FFMPEG="$(command -v ffmpeg || true)"
fi

if [[ -x "/Users/dudek/bin/ffprobe" ]]; then
  FFPROBE="/Users/dudek/bin/ffprobe"
else
  FFPROBE="$(command -v ffprobe || true)"
fi

file_size() {
  # Works on macOS (stat -f%z) and GNU/Linux (stat -c %s).
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f%z "$1"
  fi
}

human_size() {
  # Convert bytes to human-readable (base-1024).
  local bytes="$1"
  local units=("B" "KB" "MB" "GB" "TB" "PB")
  local i=0
  local whole="$bytes"
  local frac=0
  while (( whole >= 1024 && i < ${#units[@]}-1 )); do
    frac=$(( (whole % 1024) * 100 / 1024 ))
    whole=$(( whole / 1024 ))
    ((i++))
  done
  if (( i == 0 )); then
    printf "%d%s" "$whole" "${units[$i]}"
  else
    printf "%d.%02d%s" "$whole" "$frac" "${units[$i]}"
  fi
}

audio_md5() {
  # Hash only the audio stream to ignore cover art/tags.
  # mode=stream hashes compressed packets (fast); mode=samples hashes decoded audio (slow).
  local f="$1"
  local mode="$2"
  if [[ -z "$FFMPEG" || "$mode" == "off" ]]; then
    echo ""
    return 1
  fi
  if [[ "$mode" == "stream" ]]; then
    "$FFMPEG" -v error -i "$f" -map 0:a:0 -c copy -f md5 - 2>/dev/null | awk -F= 'NR==1{print $2}'
  else
    "$FFMPEG" -v error -i "$f" -map 0:a:0 -f md5 - 2>/dev/null | awk -F= 'NR==1{print $2}'
  fi
}

is_media_file() {
  local f="$1"
  local ext="${f##*.}"
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    # audio
    mp3|m4a|m4b|flac|wav|ogg|opus|aac|aax|aaxc|aa|wma|alac)
      return 0
      ;;
    # video
    mp4|mkv|mov|avi|m4v|wmv|webm|flv|mpeg|mpg|3gp)
      return 0
      ;;
    # images
    jpg|jpeg|png|gif|webp|bmp|tiff|tif|heic|heif)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

audio_probe_sig() {
  local f="$1"
  if [[ -z "$FFPROBE" ]]; then
    echo ""
    return 1
  fi
  # Use rounded duration to milliseconds to avoid tiny metadata jitter.
  "$FFPROBE" -v error \
    -show_entries stream=sample_rate,channels,bit_rate \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=0 "$f" 2>/dev/null \
  | awk -F= '
      BEGIN{sr="";ch="";br="";dur="";}
      /^sample_rate=/{sr=$2}
      /^channels=/{ch=$2}
      /^bit_rate=/{if (br=="") br=$2}
      /^duration=/{dur=$2}
      END{
        if (dur=="") {print ""; exit 1}
        ms=int(dur*1000+0.5);
        printf "%s|%s|%s|%d\n", sr,ch,br,ms
      }'
}

declare -A groups
declare -A sizes_for_norm
declare -A files_for_norm
declare -A media_for_norm

if (( recursive )); then
  find_cmd=(find "$dir" -type f -print0)
else
  find_cmd=(find "$dir" -maxdepth 1 -type f -print0)
fi

# Collect files
while IFS= read -r -d '' path; do
  size=$(file_size "$path")
  name=$(basename "$path")
  norm=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  norm=${norm// /_}
  norm=${norm//\\/}
  norm=${norm//\//}   # defensive; names shouldn't contain '/'
  norm=${norm//,/}
  norm=${norm//./}
  norm=${norm//:/}
  norm=${norm//-/_}
  norm=${norm//_/}    # strip underscores
  norm=${norm// /}    # strip spaces
  # normalize multiple punctuation/space variants to the same key
  # final key is alnum only
  norm=$(printf '%s' "$norm" | tr -cd '[:alnum:]')
  key="$norm|$size"
  groups[$key]+="$path"$'\n'
  sizes_for_norm["$norm"]+="$size"$'\n'
  files_for_norm["$norm"]+="$path"$'\n'
  if is_media_file "$name"; then
    media_for_norm["$norm"]+="1"$'\n'
  else
    media_for_norm["$norm"]+="0"$'\n'
  fi
done < <("${find_cmd[@]}")

confirm_delete() {
  local f="$1"
  if (( assume_yes )); then
    return 0
  fi
  read -r -p "Delete \"$f\"? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

found=0
for norm in "${!sizes_for_norm[@]}"; do
  mapfile -t sizes < <(printf '%s' "${sizes_for_norm[$norm]}")
  mapfile -t uniq_sizes < <(printf '%s\n' "${sizes[@]}" | sort -un)
  mapfile -t media_flags < <(printf '%s' "${media_for_norm[$norm]}")
  all_media=1
  for m in "${media_flags[@]}"; do
    if [[ "$m" != "1" ]]; then
      all_media=0
      break
    fi
  done
  if (( ${#uniq_sizes[@]} < 2 )); then
    continue
  fi
  # Check if any two sizes are within tolerance.
  match=0
  match_reason=""
  for ((i=0; i<${#uniq_sizes[@]}; i++)); do
    for ((j=i+1; j<${#uniq_sizes[@]}; j++)); do
      diff=$(( uniq_sizes[j] - uniq_sizes[i] ))
      (( diff < 0 )) && diff=$(( -diff ))
      if (( all_media == 0 && approx_non_media == 0 )); then
        if (( diff == 0 )); then
          match=1
          match_reason="size"
          break
        fi
      else
        if (( diff <= tolerance )); then
          match=1
          match_reason="size"
          break
        fi
      fi
    done
    (( match )) && break
  done
  # If size doesn't match, fall back to audio hash (if ffmpeg exists).
  if (( ! match )); then
    if (( all_media == 1 )) && [[ "$audio_hash_mode" == "probe" ]]; then
      if [[ -n "$FFPROBE" ]]; then
        mapfile -t files < <(printf '%s' "${files_for_norm[$norm]}")
        declare -A sig_counts=()
        for f in "${files[@]}"; do
          [[ -f "$f" ]] || continue
          s="$(audio_probe_sig "$f" || true)"
          [[ -n "$s" ]] && sig_counts["$s"]=$(( ${sig_counts["$s"]:-0} + 1 ))
        done
        for s in "${!sig_counts[@]}"; do
          if (( ${sig_counts[$s]} > 1 )); then
            match=1
            match_reason="audio-probe"
            break
          fi
        done
      fi
    elif (( all_media == 1 )) && [[ -n "$FFMPEG" && "$audio_hash_mode" != "off" ]]; then
      mapfile -t files < <(printf '%s' "${files_for_norm[$norm]}")
      declare -A hash_counts=()
      for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        h="$(audio_md5 "$f" "$audio_hash_mode" || true)"
        [[ -n "$h" ]] && hash_counts["$h"]=$(( ${hash_counts["$h"]:-0} + 1 ))
      done
      for h in "${!hash_counts[@]}"; do
        if (( ${hash_counts[$h]} > 1 )); then
          match=1
          match_reason="audio-$audio_hash_mode"
          break
        fi
      done
    fi
  fi
  if (( match )); then
    # Gather all names across all sizes for this norm.
    names_combined=""
    paths_combined=""
    for sz in "${uniq_sizes[@]}"; do
      key="$norm|$sz"
      paths_combined+="${groups[$key]}"
    done
    mapfile -t paths < <(printf '%s' "$paths_combined")
    mapfile -t uniq_paths < <(printf '%s\n' "${paths[@]}" | sort -u)
    mapfile -t uniq_names < <(printf '%s\n' "${uniq_paths[@]##*/}" | sort -u)
    if (( ${#uniq_names[@]} > 1 )); then
      found=$((found + 1))
      min_size=${uniq_sizes[0]}
      max_size=${uniq_sizes[${#uniq_sizes[@]}-1]}
      size_diff=$(( max_size - min_size ))
      min_h=$(human_size "$min_size")
      max_h=$(human_size "$max_size")
      echo "---"
      if [[ "$match_reason" == "size" ]]; then
        echo "Normalized: $norm | Sizes: ${min_h}..${max_h} (diff ${size_diff} bytes) | Match: size"
      elif [[ "$match_reason" == "audio-probe" ]]; then
        echo "Normalized: $norm | Sizes: ${min_h}..${max_h} (diff ${size_diff} bytes) | Match: audio probe"
      elif [[ "$match_reason" == "audio-stream" ]]; then
        echo "Normalized: $norm | Sizes: ${min_h}..${max_h} (diff ${size_diff} bytes) | Match: audio hash (stream)"
      elif [[ "$match_reason" == "audio-samples" ]]; then
        echo "Normalized: $norm | Sizes: ${min_h}..${max_h} (diff ${size_diff} bytes) | Match: audio hash (samples)"
      else
        echo "Normalized: $norm | Sizes: ${min_h}..${max_h} (diff ${size_diff} bytes) | Match: unknown"
      fi
      if (( recursive )); then
        for p in "${uniq_paths[@]}"; do
          echo "  - $p"
        done
      else
        for n in "${uniq_names[@]}"; do
          echo "  - $n"
        done
      fi

      if [[ -n "$delete_mode" ]]; then
        to_delete=()
        case "$delete_mode" in
          underscores)
            for p in "${uniq_paths[@]}"; do
              b="${p##*/}"
              if [[ "$b" == *"_"* && "$b" != *" "* ]]; then
                to_delete+=("$p")
              fi
            done
            ;;
          spaces)
            for p in "${uniq_paths[@]}"; do
              b="${p##*/}"
              if [[ "$b" == *" "* ]]; then
                to_delete+=("$p")
              fi
            done
            ;;
          smaller|larger)
            # Sort by size and delete all but one.
            mapfile -t size_pairs < <(for p in "${uniq_paths[@]}"; do printf '%s\t%s\n' "$(file_size "$p")" "$p"; done | sort -n)
            if [[ "$delete_mode" == "smaller" ]]; then
              # Keep largest, delete smaller ones.
              for ((i=0; i<${#size_pairs[@]}-1; i++)); do
                to_delete+=("${size_pairs[$i]#*$'\t'}")
              done
            else
              # Keep smallest, delete larger ones.
              for ((i=1; i<${#size_pairs[@]}; i++)); do
                to_delete+=("${size_pairs[$i]#*$'\t'}")
              done
            fi
            ;;
        esac

        if (( ${#to_delete[@]} > 0 )); then
          for p in "${to_delete[@]}"; do
            if confirm_delete "$p"; then
              rm -f -- "$p"
            fi
          done
        fi
      fi
    fi
  fi
done

if (( found == 0 )); then
  echo "No space/underscore duplicates within ${tolerance} bytes found in \"$dir\"."
fi
