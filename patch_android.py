#!/usr/bin/env python3
"""Patch the Flutter-generated AndroidManifest.xml for Ronghor AI (safe to run twice).

Adds: INTERNET + RECORD_AUDIO permissions, speech/TTS package-visibility queries,
the app label, and (only with --cleartext) permission for plain http:// backends.
Fails loudly if the result is not well-formed XML.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PERMISSIONS = ["android.permission.INTERNET", "android.permission.RECORD_AUDIO"]
QUERY_ACTIONS = ["android.speech.RecognitionService", "android.intent.action.TTS_SERVICE"]
DEFAULT_PATH = "android/app/src/main/AndroidManifest.xml"


def patch(text: str, cleartext: bool = False) -> str:
    app_match = re.search(r"^([ \t]*)<application\b", text, re.MULTILINE)
    if not app_match:
        raise SystemExit("Could not find <application> in the manifest.")

    # 1) permissions, inserted on their own lines just above <application>
    indent = app_match.group(1) or "    "
    missing = [p for p in PERMISSIONS if f'android:name="{p}"' not in text]
    if missing:
        block = "".join(f'{indent}<uses-permission android:name="{p}"/>\n' for p in missing)
        text = text[: app_match.start()] + block + text[app_match.start():]

    # 2) package-visibility queries so speech recognition and text-to-speech work on Android 11+
    new_intents = "".join(
        f'{indent}    <intent>\n{indent}        <action android:name="{a}"/>\n{indent}    </intent>\n'
        for a in QUERY_ACTIONS
        if f'android:name="{a}"' not in text
    )
    if new_intents:
        if "</queries>" in text:
            text = text.replace("</queries>", new_intents + f"{indent}</queries>", 1)
        else:
            text = text.replace("</manifest>", f"{indent}<queries>\n{new_intents}{indent}</queries>\n</manifest>", 1)

    # 3) friendly app name on the home screen
    text = text.replace('android:label="ronghor_ai"', 'android:label="Ronghor AI"')

    # 4) optional: allow plain http:// (LAN / local testing only)
    if cleartext and "usesCleartextTraffic" not in text:
        text = re.sub(r"<application\b", '<application android:usesCleartextTraffic="true"', text, count=1)

    ET.fromstring(text)  # raises ParseError if we broke the XML
    return text


def main(argv):
    cleartext = "--cleartext" in argv
    paths = [a for a in argv if not a.startswith("--")]
    path = Path(paths[0] if paths else DEFAULT_PATH)
    path.write_text(patch(path.read_text(encoding="utf-8"), cleartext), encoding="utf-8")
    print(f"Patched {path} (cleartext={'on' if cleartext else 'off'})")


if __name__ == "__main__":
    main(sys.argv[1:])
