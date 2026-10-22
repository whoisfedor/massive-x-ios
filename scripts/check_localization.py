#!/usr/bin/env python3
"""Validate native catalog coverage without calling a translation service."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
languages = {"en", "fr", "ru", "es", "zh-Hans", "de"}
count = 0
for path in (root / 'MassiveX/Localization').glob('*.xcstrings'):
    catalog = json.loads(path.read_text())
    assert catalog['sourceLanguage'] == 'en'
    for key, entry in catalog['strings'].items():
        assert set(entry['localizations']) == languages, key
        for language, value in entry['localizations'].items():
            assert value['stringUnit']['state'] == 'translated', (key, language)
            assert value['stringUnit']['value'].strip(), (key, language)
        count += 1
print(f'PASS: {count} catalog entries, six languages, no missing translations.')
