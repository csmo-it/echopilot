#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="${1:-}"
MODEL="${WHISPER_MODEL:-turbo}"
LANGUAGE="${WHISPER_LANGUAGE:-de}"
WHISPER_DEVICE="${WHISPER_DEVICE:-auto}"
WHISPER_FP16="${WHISPER_FP16:-auto}"
UPDATE_DEPS="${ECHOPILOT_UPDATE_WHISPER_DEPS:-0}"

normalize_whisper_language() {
  local raw="${1:-}"
  local normalized
  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "$normalized" in
    ""|auto|detect|autodetect|auto-detect|none|default)
      printf ''
      ;;
    deutsch|german)
      printf 'de'
      ;;
    englisch|english)
      printf 'en'
      ;;
    *)
      printf '%s' "$normalized"
      ;;
  esac
}

NORMALIZED_LANGUAGE="$(normalize_whisper_language "$LANGUAGE")"

if [[ "${ECHOPILOT_TEST_LANGUAGE_ARGS:-0}" == "1" ]]; then
  printf 'raw_language=%s\n' "$LANGUAGE"
  if [[ -n "$NORMALIZED_LANGUAGE" ]]; then
    printf 'normalized_language=%s\n' "$NORMALIZED_LANGUAGE"
    printf 'language_args=--language %s\n' "$NORMALIZED_LANGUAGE"
  else
    printf 'normalized_language=auto\n'
    printf 'language_args=<omitted>\n'
  fi
  exit 0
fi

if [[ -z "$BUNDLE_DIR" ]]; then
  echo "Usage: scripts/transcribe-local-whisper.sh recordings/dual-test" >&2
  echo "Optional env:" >&2
  echo "  WHISPER_MODEL=tiny|base|small|medium|large|large-v2|large-v3|turbo" >&2
  echo "  WHISPER_LANGUAGE=de|en|auto" >&2
  echo "  WHISPER_DEVICE=auto|mps|cpu|cuda" >&2
  echo "  ECHOPILOT_UPDATE_WHISPER_DEPS=1  # force pip upgrade" >&2
  exit 2
fi

if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Bundle directory not found: $BUNDLE_DIR" >&2
  exit 2
fi

SYSTEM="$BUNDLE_DIR/system.m4a"
if [[ -f "$BUNDLE_DIR/mic.m4a" ]]; then
  MIC="$BUNDLE_DIR/mic.m4a"
else
  MIC="$BUNDLE_DIR/mic.caf"
fi
OUT="$BUNDLE_DIR/transcription-input"
VENV=".venv-transcribe"

for f in "$SYSTEM" "$MIC"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing audio file: $f" >&2
    exit 2
  fi
done

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required but was not found in the GUI app PATH." >&2
  echo "Checked PATH: $PATH" >&2
  echo "Install on macOS with:" >&2
  echo "  brew install ffmpeg" >&2
  echo "If already installed, verify one of these exists:" >&2
  echo "  /opt/homebrew/bin/ffmpeg" >&2
  echo "  /usr/local/bin/ffmpeg" >&2
  exit 2
fi

mkdir -p "$OUT"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi

needs_deps=0
if [[ ! -x "$VENV/bin/whisper" ]]; then
  needs_deps=1
elif ! "$VENV/bin/python" - <<'PY' >/dev/null 2>&1
import torch, whisper
PY
then
  needs_deps=1
fi

if [[ "$UPDATE_DEPS" == "1" || "$needs_deps" == "1" ]]; then
  echo "Installing/updating Whisper dependencies..."
  "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools >/dev/null
  if [[ "$UPDATE_DEPS" == "1" ]]; then
    "$VENV/bin/python" -m pip install --upgrade openai-whisper >/dev/null
  else
    "$VENV/bin/python" -m pip install openai-whisper >/dev/null
  fi
fi

if [[ "$WHISPER_DEVICE" == "auto" ]]; then
  WHISPER_DEVICE="$($VENV/bin/python - <<'PY'
import torch
if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
    print("mps")
elif torch.cuda.is_available():
    print("cuda")
else:
    print("cpu")
PY
)"
fi

if [[ "$WHISPER_FP16" == "auto" ]]; then
  if [[ "$WHISPER_DEVICE" == "cpu" || "$WHISPER_DEVICE" == "mps" ]]; then
    WHISPER_FP16="False"
  else
    WHISPER_FP16="True"
  fi
fi

LANGUAGE_ARGS=()
if [[ -n "$NORMALIZED_LANGUAGE" ]]; then
  LANGUAGE_ARGS=(--language "$NORMALIZED_LANGUAGE")
fi

CURRENT_DEVICE="$WHISPER_DEVICE"
CURRENT_FP16="$WHISPER_FP16"

if [[ -z "$NORMALIZED_LANGUAGE" && "$CURRENT_DEVICE" == "mps" ]]; then
  echo "Auto language detection is more reliable on CPU; using CPU for this auto-language transcription run." >&2
  CURRENT_DEVICE="cpu"
  CURRENT_FP16="False"
fi

printf 'EchoPilot Whisper settings:\n'
printf '  model:  %s\n' "$MODEL"
if [[ -n "$NORMALIZED_LANGUAGE" ]]; then
  printf '  language: %s\n' "$NORMALIZED_LANGUAGE"
else
  printf '  language: auto-detect\n'
fi
printf '  device: %s\n' "$CURRENT_DEVICE"
printf '  fp16:   %s\n' "$CURRENT_FP16"
printf '  output: txt/vtt/srt/tsv/json\n'
printf '  tracks: system + mic are transcribed sequentially\n\n'

run_whisper() {
  local input="$1"
  local label="$2"
  printf 'Transcribing %s: %s\n' "$label" "$input"
  if "$VENV/bin/whisper" "$input" \
    --model "$MODEL" \
    "${LANGUAGE_ARGS[@]}" \
    --device "$CURRENT_DEVICE" \
    --fp16 "$CURRENT_FP16" \
    --task transcribe \
    --output_format all \
    --output_dir "$OUT" \
    --verbose False; then
    return 0
  fi

  if [[ "$CURRENT_DEVICE" == "mps" ]]; then
    echo "MPS acceleration was not stable for $label; switching this and remaining tracks to CPU fallback..." >&2
    CURRENT_DEVICE="cpu"
    CURRENT_FP16="False"
    "$VENV/bin/whisper" "$input" \
      --model "$MODEL" \
      "${LANGUAGE_ARGS[@]}" \
      --device "$CURRENT_DEVICE" \
      --fp16 "$CURRENT_FP16" \
      --task transcribe \
      --output_format all \
      --output_dir "$OUT" \
      --verbose False
    echo "CPU fallback completed for $label."
    return 0
  fi

  return 1
}

run_whisper "$SYSTEM" "system audio"
run_whisper "$MIC" "microphone"

# Normalize filenames expected by downstream scripts.
for ext in txt vtt srt tsv json; do
  if [[ -f "$OUT/system.$ext" ]]; then
    :
  elif [[ -f "$OUT/system.m4a.$ext" ]]; then
    mv "$OUT/system.m4a.$ext" "$OUT/system.$ext"
  fi

  if [[ -f "$OUT/mic.$ext" ]]; then
    :
  elif [[ -f "$OUT/mic.caf.$ext" ]]; then
    mv "$OUT/mic.caf.$ext" "$OUT/mic.$ext"
  elif [[ -f "$OUT/mic.m4a.$ext" ]]; then
    mv "$OUT/mic.m4a.$ext" "$OUT/mic.$ext"
  fi
done

printf '\nTranscripts written:\n'
printf '  %s\n' "$OUT/system.txt" "$OUT/mic.txt"
if [[ -f "$OUT/system.vtt" && -f "$OUT/mic.vtt" ]]; then
  printf '  %s\n' "$OUT/system.vtt" "$OUT/mic.vtt"
fi
