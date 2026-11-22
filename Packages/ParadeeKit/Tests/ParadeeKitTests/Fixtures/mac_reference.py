"""The Mac's Paradee as the reference for ParadeeKit's English tests (run by EnglishBookTests).

Reads a JSON list of sentences on stdin; writes one JSON line per sentence: the phonemes Python
Paradee gives for af_heart (US) and bf_isabella (GB), and spaCy's tokens + tags (what misaki
tags with), so the test can tell the port's own errors from tagger differences.
"""
import json, sys

proto = sys.stdout
sys.stdout = sys.stderr            # libraries' prints must not mix with the replies
import spacy
from paradee import Paradee

nlp = spacy.load("en_core_web_sm", enable=["tok2vec", "tagger"])
tts = Paradee(threads=1)
for text in json.load(sys.stdin):
    tokens = [{"text": t.text, "tag": t.tag_, "ws": t.whitespace_} for t in nlp(text)]
    proto.write(json.dumps({"us": tts.phonemize(text, "af_heart"), "gb": tts.phonemize(text, "bf_isabella"),
                            "tokens": tokens}, ensure_ascii=False) + "\n")
proto.flush()
