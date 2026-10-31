#!/usr/bin/env python3
"""Validate every shipped catalog, including ABI error keys and printf types."""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'native/Resources'


def load(path):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def placeholders(value):
    # This project deliberately uses only %d and %@; translated fields must keep
    # their types and order so a translation can never reinterpret an argument.
    return re.findall(r'%(?:\d+\$)?[@diu]', value.replace('%%', ''))


english = load(RESOURCES / 'en.lproj/Localizable.strings')
source = (ROOT / 'native/Localization.swift').read_text()
expected = set(re.findall(r'\.init\(id: "([^"]+)"', source))
actual = {p.stem for p in RESOURCES.glob('*.lproj')}
assert actual == expected, ('Language registry mismatch', actual ^ expected)
for language in sorted(actual):
    directory = RESOURCES / f'{language}.lproj'
    strings = load(directory / 'Localizable.strings')
    assert strings.keys() == english.keys(), (language, 'Missing/unknown keys', strings.keys() ^ english.keys())
    for key, value in strings.items():
        assert value.strip(), (language, key, 'Empty translation')
        assert placeholders(value) == placeholders(english[key]), (language, key, 'Unsafe format placeholders')
    permissions = load(directory / 'InfoPlist.strings')
    assert permissions == {
        'NSMicrophoneUsageDescription': strings['permission.microphone_reason'],
        'NSScreenCaptureUsageDescription': strings['permission.screen_reason'],
    }, (language, 'Permission text mismatch')
    for filename in ['Localizable.strings', 'InfoPlist.strings']:
        entries = re.findall(r'^"([^"]+)"\s*=', (directory / filename).read_text(), re.MULTILINE)
        assert len(entries) == len(set(entries)), (language, filename, 'Duplicate keys')

# Catch missing resources referenced from Swift as well as Rust's FFI errors.
for path in list((ROOT / 'native').glob('*.swift')) + [ROOT / 'src/lib.rs']:
    text = path.read_text()
    keys = re.findall(r'\bL(?:F)?\("([^"]+)"', text)
    keys += re.findall(r'"(error\.[a-z_]+)(?:"|\\t)', text)
    for key in keys:
        assert key in english, (path.name, key, 'Missing localization')
print(f'Localization validation passed: {len(actual)} languages, {len(english)} keys each, permission text, and format placeholders.')
