"""The PC program's texts (tray menu, pairing window, messages, the overlay) in the app's language.

tools/i18n/pc.json: English text -> {language code: translation}, codes as the game's (Fr_Fr). The language is
the one the phone last sent (POST /tracker "lang", kept in config.json), else Windows' display language.
`{name}` marks where values go, as in the app (docs/i18n.md).
"""
import json
import locale

from paths import RES

lang = None
_table = {}

# Windows' language (ll_CC) -> the game's code
_WIN = {"de": "De_De", "fr": "Fr_Fr", "es": "Es_Es", "it": "It_It", "pt": "Pt_Br", "pl": "Pl_Pl", "ru": "Ru_Ru",
        "uk": "Uk_Ua", "tr": "Tr_Tr", "ja": "Ja_Jp", "ko": "Ko_Kr", "th": "Th_Th"}
CODES = {"En_Us", *_WIN.values(), "Zh_Cn", "Zh_Tw"}


def windows_lang():
    try:
        import ctypes

        name = locale.windows_locale.get(ctypes.windll.kernel32.GetUserDefaultUILanguage(), "")
    except (AttributeError, OSError):
        return "En_Us"
    ll, _, cc = name.partition("_")
    if ll == "zh":
        return "Zh_Tw" if cc in ("TW", "HK", "MO") else "Zh_Cn"
    return _WIN.get(ll, "En_Us")


def load(code=None):
    """Use [code] (None: Windows' language)."""
    global lang, _table
    lang = code if code in CODES else windows_lang()
    if not _table:
        try:
            _table = json.loads((RES / "tools" / "i18n" / "pc.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _table = {}


def t(en, **args):
    if lang is None:
        load()
    s = (_table.get(en) or {}).get(lang) or en
    return s.format(**args) if args else s
