"""Fix common misspellings in chat questions before routing.

Only words close to the routing vocabulary are changed ("spedn" -> "spend", "octobr" ->
"october"). Common English words are protected so "same" never turns into "save", and
merchant names ("spotify", "costco") have no close match, so they pass through untouched.
"""

import difflib
import re

from .zh_terms import translate_chinese

# Words the routing rules look for.
_VOCAB = set(
    """
    how much many what did spend spent spending expense expenses income earn earned earnings
    net cash flow money total average month months week weeks year years today yesterday
    last this transaction transactions list show recent latest category categories compare
    versus budget budgets subscription subscriptions save savings reduce food transport
    transportation shopping entertainment health housing rent utilities bills groceries
    dining restaurants travel fees transfers why increase decrease higher lower biggest
    largest highest lowest purchase purchases overview summary doing january february march
    april june july august september october november december
    """.split()
)

# Real words that sit close to the vocabulary and must stay as typed.
_PROTECTED = set(
    """
    same some sale more most made make done does have been were with from into when then
    than them they your mine need next past over each ever also just like want know tell
    give take back cost costs paid card bank shop shops lost list mouth worth work word
    spent send sent earns learn near year hear dear food good foot rest best test west weak
    week weekend today total totals noted tool expensive tips spends shows categorize
    recategorize export remind delete feels speed spelt moths mouths mounts toady tonal monte
    least sending foods
    """.split()
)

# Misspellings too short or too far off for fuzzy matching.
_EXPLICIT = {
    "hw": "how",
    "wat": "what",
    "wht": "what",
    "ddi": "did",
    "dd": "did",
    "fod": "food",
    "fodo": "food",
    "foood": "food",
    "aprl": "april",
    "mcuh": "much",
    "muhc": "much",
    "lst": "last",
    "mnth": "month",
    "mont": "month",
    "jly": "july",
    "juli": "july",
    "jully": "july",
    "febuary": "february",
    "februrary": "february",
    "septmber": "september",
    "octobr": "october",
    "novmber": "november",
    "decmber": "december",
    "mth": "month",
    "spnd": "spend",
    "incm": "income",
    "cashflow": "cash flow",
    "whats": "what is",
}

_WORD_RE = re.compile(r"[a-z]+")
_INFLECTIONS = ("ing", "ed", "er", "d", "y")


def _inflects_vocab(word):
    """True for "saved", "budgeted", "healthy", "showing": a vocabulary word plus a real
    ending, whose meaning the routing rules need ("how much have I saved")."""
    for ending in _INFLECTIONS:
        stem = word[: -len(ending)]
        if word.endswith(ending) and (stem in _VOCAB or stem + "e" in _VOCAB):
            return True
    return False


def _fix_word(word):
    if word in _EXPLICIT:
        return _EXPLICIT[word]
    # Short words are too ambiguous to guess ("may" is not "many", "tips" is not "this").
    if len(word) < 5 or word in _VOCAB or word in _PROTECTED or _inflects_vocab(word):
        return word
    candidates = difflib.get_close_matches(word, _VOCAB, n=3, cutoff=0.8)
    for candidate in candidates:
        # Typos keep the first letter and drop, add or swap about one character.
        if candidate[0] == word[0] and abs(len(candidate) - len(word)) <= 1:
            return candidate
    return word


def fix_typos(text):
    """Lowercase text with near-miss routing words corrected."""
    if not isinstance(text, str):
        return ""
    text = translate_chinese(text)
    return _WORD_RE.sub(lambda m: _fix_word(m.group(0)), text.lower())
