#!/usr/bin/env python3

import argparse
import json
import wave

import mlx_whisper
import numpy as np


def load_recording(path: str) -> np.ndarray:
    with wave.open(path, "rb") as recording:
        channels = recording.getnchannels()
        sample_width = recording.getsampwidth()
        sample_rate = recording.getframerate()
        frames = recording.readframes(recording.getnframes())

    if channels != 1 or sample_width != 2 or sample_rate != 16_000:
        raise ValueError(
            "Expected 16 kHz mono 16-bit PCM WAV, "
            f"got {sample_rate} Hz, {channels} channel(s), {sample_width * 8}-bit"
        )

    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", required=True)
    args = parser.parse_args()

    audio = load_recording(args.audio)
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=args.model,
        language=args.language,
        task="transcribe",
        verbose=None,
        condition_on_previous_text=False,
    )
    print(json.dumps({"text": result["text"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
