"""Habla's voice worker (Mac): Paradee, an 8M-parameter speech model distilled from Kokoro.

Long-running: the model loads once, then one JSON request per line on stdin:
    {"text": "...", "voice": "af_heart", "speed": 1.0, "out": "/path/to/file.f32"}
and one JSON reply per line on stdout:
    {"ok": true, "sample_rate": 24000, "samples": 12345}   or   {"ok": false, "error": "..."}
The audio is written to `out` as raw float32 mono samples. Nothing is downloaded at run time.
"""
import json, os, sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")


def main():
    proto = sys.stdout
    sys.stdout = sys.stderr            # libraries' prints must never corrupt the protocol
    import numpy as np
    from paradee import Paradee, SAMPLE_RATE

    tts = Paradee(threads=1)            # one thread per worker; Habla runs several workers
    proto.write(json.dumps({"ready": True, "voices": list(tts.voices)}) + "\n"); proto.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            voice = req.get("voice", "af_heart")
            if voice not in tts.voices:
                voice = "af_heart"
            audio = tts(req["text"], speed=float(req.get("speed", 1.0)), voice=voice)
            np.asarray(audio, dtype=np.float32).tofile(req["out"])
            proto.write(json.dumps({"ok": True, "sample_rate": SAMPLE_RATE, "samples": int(len(audio))}) + "\n")
        except Exception as e:  # report and keep serving
            proto.write(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}) + "\n")
        proto.flush()


if __name__ == "__main__":
    main()
