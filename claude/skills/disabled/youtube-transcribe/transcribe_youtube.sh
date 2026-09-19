#!/bin/bash
#
# transcribe_youtube.sh
#
# Takes a YouTube URL and produces, in output/youtube/<slug>/ :
#   audio.mp3       - kept listening copy (128kbps mono)
#   transcript.txt  - reflowed into readable paragraphs (decimal-number safe)
#   transcript.srt  - timestamped segments (used for the summary's outline links)
#   metadata.json   - id, title, uploader, duration, upload date, URL
#
# The assistant then writes summary.md into the same folder (see SKILL.md).
#
# Pipeline: uvx yt-dlp (bestaudio download) -> ffmpeg (kept mp3 + temp 16kHz
# mono WAV for STT) -> uvx whisper. No pip installs: every Python tool runs
# via uvx into cached ephemeral environments. The Whisper model weights
# auto-download from Hugging Face on first run and are cached under
# ~/.cache/huggingface.
#
# Two speech-to-text backends, picked automatically (see WHISPER_BACKEND):
#   mlx  - mlx-whisper, Apple Silicon only (Metal). Used on Darwin/arm64.
#   ct2  - whisper-ctranslate2 (faster-whisper/CTranslate2), CPU or CUDA.
#          Used everywhere else, including Linux.
#
# Runs on macOS (Apple Silicon) or Linux. The assistant's Cowork sandbox
# cannot reach YouTube, so it is not a valid host either way. One-time setup
# is handled by the dotfiles ansible bootstrap (ffmpeg, uv, node); by hand it
# is: brew install ffmpeg uv
#
# Usage:
#   bash "/path/to/Skills/youtube-transcribe/transcribe_youtube.sh" "<youtube-url>" [model]
#
#   model is a plain Whisper size name - small.en (default, validated on the
#   lecture-processing pipeline), medium.en, large-v3-turbo, ... Each backend
#   spells it its own way; this script does the translation. For non-English
#   videos pass a multilingual size, e.g.:  ... "<url>" small
#   (language auto-detect is enabled automatically for non-.en models).
#
# Output base defaults to <repo>/output/youtube (repo root derived from this
# script's location: Skills/youtube-transcribe/ is two levels down). Override
# with OUTPUT_BASE=/some/path.

set -e

# Homebrew tools (uv, ffmpeg) live outside the default PATH of non-login
# shells (e.g. the assistant's Bash tool) - /opt/homebrew on macOS,
# /home/linuxbrew/.linuxbrew on Linux.
for brew_bin in /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin; do
  [ -d "$brew_bin" ] && PATH="$brew_bin:$PATH"
done

URL="$1"
MODEL="${2:-small.en}"

# mlx-whisper needs Apple Silicon's Metal; everywhere else falls back to
# whisper-ctranslate2, which runs the same Whisper models on CPU or CUDA.
# Override with WHISPER_BACKEND=mlx|ct2.
if [ -z "$WHISPER_BACKEND" ]; then
  if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    WHISPER_BACKEND=mlx
  else
    WHISPER_BACKEND=ct2
  fi
fi

if [ -z "$URL" ]; then
  echo "Usage: transcribe_youtube.sh <youtube-url> [model]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_BASE="${OUTPUT_BASE:-$REPO_ROOT/output/youtube}"

KEPT_AUDIO_BITRATE="128k"
PARAGRAPH_EVERY=5   # sentences per paragraph in the reflowed transcript

if ! command -v uvx >/dev/null 2>&1; then
  echo "uvx not found. Rerun the dotfiles ansible bootstrap, or: brew install uv"
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Rerun the dotfiles ansible bootstrap, or: brew install ffmpeg"
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/youtube-transcribe.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Pin HF_HOME so the model cache location is deterministic, and go fully
# offline when the model is already cached (no revision-check latency).
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# $MODEL is a plain size name; each backend wants it spelled differently and
# caches it under a different Hugging Face repo.
case "$WHISPER_BACKEND" in
  mlx)
    BACKEND_MODEL="mlx-community/whisper-${MODEL}-mlx"
    MODEL_CACHE_DIR="$HF_HOME/hub/models--mlx-community--whisper-${MODEL}-mlx"
    ;;
  ct2)
    BACKEND_MODEL="$MODEL"
    MODEL_CACHE_DIR="$HF_HOME/hub/models--Systran--faster-whisper-${MODEL}"
    ;;
  *)
    echo "Unknown WHISPER_BACKEND '$WHISPER_BACKEND' (expected mlx or ct2)"
    exit 1
    ;;
esac

# Only an optimisation: an unrecognised cache path just means we stay online.
if [ -d "$MODEL_CACHE_DIR/snapshots" ] && [ -n "$(ls -A "$MODEL_CACHE_DIR/snapshots" 2>/dev/null)" ]; then
  export HF_HUB_OFFLINE=1
fi

echo "Fetching video metadata..."
# One field per line; titles cannot contain newlines, so line-based parsing
# is safe even when the title contains pipes, quotes, etc.
META="$(uvx yt-dlp --skip-download --no-playlist \
  --print "%(id)s" --print "%(duration)s" --print "%(upload_date)s" \
  --print "%(uploader)s" --print "%(webpage_url)s" --print "%(title)s" \
  "$URL")"
VIDEO_ID="$(echo "$META" | sed -n 1p)"
DURATION="$(echo "$META" | sed -n 2p)"
UPLOAD_DATE="$(echo "$META" | sed -n 3p)"
UPLOADER="$(echo "$META" | sed -n 4p)"
WEBPAGE_URL="$(echo "$META" | sed -n 5p)"
TITLE="$(echo "$META" | sed -n 6p)"

if [ -z "$VIDEO_ID" ]; then
  echo "Could not fetch metadata for $URL"
  exit 1
fi

# Slug: sanitized title (lowercase, alnum + dashes, <=60 chars) + video id
# for uniqueness. Dot-free by construction, which also sidesteps
# mlx-whisper's pathlib .with_suffix() filename-truncation bug.
TITLE_SLUG="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-60 | sed 's/-$//')"
SLUG="${TITLE_SLUG:-video}-${VIDEO_ID}"
OUT_DIR="$OUTPUT_BASE/$SLUG"

echo "Title:    $TITLE"
echo "Uploader: $UPLOADER"
echo "Duration: ${DURATION}s"
echo "Backend:  $WHISPER_BACKEND ($BACKEND_MODEL)"
echo "Output:   $OUT_DIR"
echo ""

mkdir -p "$OUT_DIR"

echo "Downloading audio (yt-dlp via uvx)..."
uvx yt-dlp -f bestaudio --no-playlist -o "$WORKDIR/source.%(ext)s" "$URL"
SOURCE="$(ls "$WORKDIR"/source.* | head -n 1)"

echo "Extracting kept-quality audio (mp3, ${KEPT_AUDIO_BITRATE} mono)..."
ffmpeg -y -i "$SOURCE" -vn -ac 1 -ab "$KEPT_AUDIO_BITRATE" "$WORKDIR/audio.mp3" -loglevel error

echo "Extracting STT-quality audio (16kHz mono WAV, temp only)..."
# Named transcript.wav, not stt.wav: whisper-ctranslate2 has no --output-name
# and derives output filenames from the input stem, so this is what makes both
# backends write transcript.txt / transcript.srt.
ffmpeg -y -i "$SOURCE" -ar 16000 -ac 1 "$WORKDIR/transcript.wav" -loglevel error

echo "Transcribing ($WHISPER_BACKEND via uvx, this is the slow part)..."
# Only force English for English-only (.en) models; multilingual models
# auto-detect the language.
LANG_ARGS=()
case "$MODEL" in
  *.en) LANG_ARGS=(--language en) ;;
esac
# Output format takes ONE value (repeating it keeps only the last), so ask for
# "all"; the extra vtt/tsv/json land in the temp workdir and are cleaned up —
# only txt and srt get moved to the output folder.
# condition-on-previous-text False: whisper's default (True) can fall into
# repetition-loop hallucination on long single-speaker recordings — the
# 2026-08-22 Brian Tracy ingest lost ~39 min to "Thank you." loops until
# re-run with this flag. Costs nothing on clean recordings.
# The backends spell the same flags differently: mlx-whisper follows the
# hyphenated MLX style, whisper-ctranslate2 the underscored openai-whisper one.
TRANSCRIBE_START=$(date +%s)
if [ "$WHISPER_BACKEND" = mlx ]; then
  uvx --from mlx-whisper mlx_whisper "$WORKDIR/transcript.wav" \
    --model "$BACKEND_MODEL" "${LANG_ARGS[@]}" \
    --condition-on-previous-text False \
    --output-format all \
    --output-name transcript --output-dir "$WORKDIR" --verbose False
else
  # compute_type int8 is the fast path on CPU; without it CTranslate2 falls
  # back to float32 for these float16 weights.
  uvx --from whisper-ctranslate2 whisper-ctranslate2 "$WORKDIR/transcript.wav" \
    --model "$BACKEND_MODEL" "${LANG_ARGS[@]}" \
    --condition_on_previous_text False \
    --compute_type int8 \
    --output_format all \
    --output_dir "$WORKDIR" --verbose False
fi

TRANSCRIBE_SECS=$(( $(date +%s) - TRANSCRIBE_START ))
echo "Transcription took ${TRANSCRIBE_SECS}s for ${DURATION}s of audio (model load included)"

if [ ! -f "$WORKDIR/transcript.txt" ]; then
  echo "!! Transcript not produced. Nothing filed; temp dir will be cleaned up."
  exit 1
fi

echo "Reflowing transcript into paragraphs..."
# Decimal-number safe reflow (same logic validated in lecture-processing):
#   1. Collapse "0. 5" artifacts back into "0.5"
#   2. Protect real decimal points from the sentence splitter
perl -0777 -ne '
  my $text = $_;
  $text =~ s/\s+/ /g;
  $text =~ s/^\s+|\s+$//g;
  $text =~ s/(\d)\.\s+(\d)/$1.$2/g;
  $text =~ s/(\d)\.(\d)/$1\x01$2/g;
  my @sentences = $text =~ /([^.!?]+[.!?]+)/g;
  my $count = 0;
  my $out = "";
  for my $s (@sentences) {
    $s =~ s/^\s+//;
    $out .= $s . " ";
    $count++;
    if ($count % '"$PARAGRAPH_EVERY"' == 0) { $out .= "\n\n"; }
  }
  $out =~ s/\x01/./g;
  print $out;
' "$WORKDIR/transcript.txt" > "$WORKDIR/transcript.reflowed"
mv "$WORKDIR/transcript.reflowed" "$WORKDIR/transcript.txt"

echo "Writing metadata.json..."
T_TITLE="$TITLE" T_ID="$VIDEO_ID" T_UPLOADER="$UPLOADER" T_DURATION="$DURATION" \
T_DATE="$UPLOAD_DATE" T_URL="$WEBPAGE_URL" T_MODEL="$BACKEND_MODEL" \
T_BACKEND="$WHISPER_BACKEND" \
python3 -c '
import json, os
print(json.dumps({
    "id": os.environ["T_ID"],
    "title": os.environ["T_TITLE"],
    "uploader": os.environ["T_UPLOADER"],
    "duration_seconds": int(os.environ["T_DURATION"] or 0),
    "upload_date": os.environ["T_DATE"],
    "url": os.environ["T_URL"],
    "whisper_model": os.environ["T_MODEL"],
    "whisper_backend": os.environ["T_BACKEND"],
}, indent=2))
' > "$WORKDIR/metadata.json"

# Only finished artifacts land in the output folder.
mv "$WORKDIR/audio.mp3" "$OUT_DIR/audio.mp3"
mv "$WORKDIR/transcript.txt" "$OUT_DIR/transcript.txt"
mv "$WORKDIR/transcript.srt" "$OUT_DIR/transcript.srt"
mv "$WORKDIR/metadata.json" "$OUT_DIR/metadata.json"

echo ""
echo "Done -> $OUT_DIR"
echo "  audio.mp3, transcript.txt, transcript.srt, metadata.json"
echo "Next: have the assistant write summary.md from the transcript."
