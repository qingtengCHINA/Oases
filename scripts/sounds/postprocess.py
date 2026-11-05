"""Trims, normalises and converts the offline renders to the shipped .caf cues.

    python3 -I scripts/sounds/postprocess.py <render-dir>   # reads <render-dir>/raw/*.f32

Leading silence is cut at -50 dBFS, the tail at -55 dBFS plus a 20 ms fade, and every file
gets the same gain so the loudest peak lands at -3 dBFS (the cues keep their relative levels).
Writes <render-dir>/wav/ui_*.wav and <render-dir>/caf/ui_*.caf (16-bit 44.1 kHz mono).
"""
import os
import subprocess
import sys
import wave

import numpy as np

NAMES = ["send", "reply_done", "task_done", "error", "attention", "rec_start", "rec_stop",
         "toggle", "trash", "copy"]
SR = 44100


def main(base: str) -> None:
    clips = {}
    for n in NAMES:
        x = np.fromfile(os.path.join(base, "raw", n + ".f32"), dtype="<f4").astype(np.float64)
        a = np.abs(x)
        head = np.where(a > 10 ** (-50 / 20))[0]
        tail = np.where(a > 10 ** (-55 / 20))[0]
        y = x[(head[0] if len(head) else 0):(tail[-1] + 1 if len(tail) else len(x))].copy()
        fade = int(0.02 * SR)
        if len(y) > fade:
            y[-fade:] *= np.linspace(1, 0, fade)
        clips[n] = y
    gain = 10 ** (-3 / 20) / max(np.max(np.abs(y)) for y in clips.values())
    os.makedirs(os.path.join(base, "wav"), exist_ok=True)
    os.makedirs(os.path.join(base, "caf"), exist_ok=True)
    for n, y in clips.items():
        pcm = (np.clip(y * gain, -1, 1) * 32767).astype("<i2")
        wav = os.path.join(base, "wav", f"ui_{n}.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@44100", "-c", "1", wav,
                        os.path.join(base, "caf", f"ui_{n}.caf")], check=True)
        print(f"{n:11s} {len(y) / SR * 1000:5.0f} ms")


if __name__ == "__main__":
    main(sys.argv[1])
