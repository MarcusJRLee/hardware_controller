#!/bin/zsh

# Benchmarks one transcribe.cpp model through the production ASR bridge.
# Options: --model PATH, --speech-model PATH|-, --manifest PATH, --passes N,
# --no-speech-detection, --cpu. Without --manifest, a synthetic corpus of
# short to long dictation is generated locally with `say`.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

xcframework="$(scripts/fetch_asr_runtime.sh)"
assets=("${(@f)$(scripts/fetch_asr_test_assets.sh)}")
model="${assets[1]}"
speech_model="${assets[3]}"
manifest=""
passes=7
detect_speech=1
use_gpu=1
while (( $# > 0 )); do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    --speech-model) speech_model="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    --passes) passes="$2"; shift 2 ;;
    --no-speech-detection) detect_speech=0; shift ;;
    --cpu) use_gpu=0; shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
[[ "$speech_model" != "-" || "$detect_speech" == "0" ]] || {
  print -u2 "Speech detection requires --speech-model."
  exit 2
}

if [[ -z "$manifest" ]]; then
  corpus="$repo_root/.build/asr_corpus_synthetic"
  manifest="$corpus/manifest.tsv"
  if [[ ! -f "$manifest" ]]; then
    command -v say >/dev/null || {
      print -u2 "say is required to generate the synthetic corpus; pass --manifest."
      exit 1
    }
    mkdir -p "$corpus"
    partial="$manifest.partial"
    cp "${assets[2]}" "$corpus/jfk.wav"
    print -r -- $'jfk\tjfk.wav\tAnd so my fellow Americans ask not what your country can do for you ask what you can do for your country' >"$partial"
    sentences=(
      "Send the draft to Alex before lunch."
      "The release candidate passed every check, so we can merge it once the review threads are resolved and the documentation matches the behavior."
      "Hold the center pedal to dictate, then release it to insert the text. Toggle mode starts on one press and finishes on the next. Both modes keep the audio on this Mac, and the transcript appears in History beside the recording so that a failed insertion can be copied or delivered again later without recording a second time."
    )
    for index in 1 2 3; do
      say -o "$corpus/synthetic_$index.wav" --file-format=WAVE \
        --data-format=LEI16@16000 --channels=1 -- "${sentences[$index]}"
      print -r -- "synthetic_$index"$'\t'"synthetic_$index.wav"$'\t'"${sentences[$index]}" >>"$partial"
    done
    long_text="${(j: :)sentences} ${(j: :)sentences} ${(j: :)sentences}"
    say -o "$corpus/synthetic_long.wav" --file-format=WAVE \
      --data-format=LEI16@16000 --channels=1 -- "$long_text"
    print -r -- "synthetic_long"$'\t'"synthetic_long.wav"$'\t'"$long_text" >>"$partial"
    mv "$partial" "$manifest"
  fi
fi

output_root="$repo_root/.build/voice_asr_benchmark"
mkdir -p "$output_root"
clang -std=c11 -O2 -Wall -Wextra -Werror \
  -I "$repo_root/Sources/voice_asr_bridge/include" \
  -F "$xcframework/macos-arm64_x86_64" \
  -framework CTranscribe \
  -Wl,-rpath,"$xcframework/macos-arm64_x86_64" \
  "$repo_root/Sources/voice_asr_bridge/voice_asr_bridge.c" \
  "$repo_root/Tests/voice_asr_bridge_tests/asr_test_support.c" \
  "$repo_root/Tests/voice_asr_bridge_tests/voice_asr_benchmark.c" \
  -o "$output_root/voice_asr_benchmark"
"$output_root/voice_asr_benchmark" "$model" "$speech_model" "$manifest" \
  "$passes" "$detect_speech" "$use_gpu"
