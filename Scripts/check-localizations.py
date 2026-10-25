#!/usr/bin/env python3
"""Check resource parity and printf placeholders without third-party packages."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
def load(language):
    text = (ROOT / "Resources" / (language + ".lproj") / "Localizable.strings").read_text()
    values = {}
    for key, value in re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', text):
        key, value = json.loads(key), json.loads(value)
        assert key not in values, f"Duplicate key: {key}"
        values[key] = value
    return values

en, zh = load("en"), load("zh-Hans")
assert en.keys() == zh.keys(), "English and Chinese resource keys differ"
for key in en:
    placeholders = lambda text: sorted(re.findall(r"%\d+\$@", text))
    assert placeholders(en[key]) == placeholders(zh[key]) == placeholders(key), f"Placeholder mismatch: {key}"
source_keys = set()
for path in (ROOT / "Sources").glob("*.swift"):
    for key in re.findall(r'\bL\(("(?:\\.|[^"\\])*")', path.read_text()):
        source_keys.add(json.loads(key))
assert source_keys <= en.keys(), f"Missing localization keys: {source_keys - en.keys()}"
print(f"PASS: {len(en)} bilingual strings; key parity, positional placeholders and source coverage.")
