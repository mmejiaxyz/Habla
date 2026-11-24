"""Long-running Kokoro worker for Habla Studio (Mac).

Protocol (JSON lines):
  stdout on start: {"ready": true, "voices": [...]}
  stdin request:   {"text": str, "voice": str, "speed": float, "lang": str, "out": path}
  stdout reply:    {"ok": true, "sample_rate": int, "samples": int}  (raw float32 mono written to `out`)
                   {"ok": false, "error": str}
The model is loaded once, so rendering a whole book costs one load.
"""
import argparse, json, sys

proto = sys.stdout
sys.stdout = sys.stderr  # keep library logging off the protocol channel


def send(obj):
    proto.write(json.dumps(obj) + "\n")
    proto.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--voices", required=True)
    args = ap.parse_args()

    import numpy as np
    from kokoro_onnx import Kokoro

    kokoro = Kokoro(args.model, args.voices)
    send({"ready": True, "voices": sorted(kokoro.get_voices())})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            samples, sr = kokoro.create(
                req["text"], voice=req.get("voice", "af_heart"),
                speed=float(req.get("speed", 1.0)), lang=req.get("lang", "en-us"))
            np.asarray(samples, dtype=np.float32).tofile(req["out"])
            send({"ok": True, "sample_rate": int(sr), "samples": int(len(samples))})
        except Exception as e:  # report and keep serving
            send({"ok": False, "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
