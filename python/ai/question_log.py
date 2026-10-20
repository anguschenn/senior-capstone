"""Record what people ask the chat, so new wordings it can't answer can be found and fixed.

Only the question's wording is kept: dollar amounts and long numbers are masked, and no
user id, account, or reply amount is stored. Rows go to a local JSON-lines file
(CHAT_QUESTION_LOG_PATH, default python/logs/chat_questions.jsonl, git-ignored); on Render
that disk is wiped on every deploy. Writing never raises.

store_question() is what the app uses: it writes the same row to the chat_question_log
table (migration 014) on a background thread, so it survives deploys, and falls back to the
file when the insert fails.
"""

import datetime as dt
import json
import os
import re
import threading
from concurrent.futures import ThreadPoolExecutor

from config import CHAT_QUESTION_LOG_PATH

LOG_PATH = CHAT_QUESTION_LOG_PATH
_WRITE_LOCK = threading.Lock()
# One thread: rows are tiny, and order doesn't matter. Keeps the insert off the request.
_DB_WRITER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="question-log")

_MAX_LEN = 300
_EMAIL_RE = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b")
_MONEY_RE = re.compile(r"[$€£]\s?\d[\d,]*(\.\d+)?|\b\d[\d,]*(\.\d+)?\s?(dollars|bucks|usd)\b", re.I)
_LONG_NUMBER_RE = re.compile(r"\b\d{5,}\b|\b\d[\d,]{4,}(\.\d+)?\b")
_COVERAGE_NOTE_RE = re.compile(r"Note: this answer doesn't cover (.+?)\. If that's what you meant")
_UNCLEAR_RE = re.compile(r"didn't understand|please clarify|which time period", re.I)


def mask_question(text):
    """The question with amounts, long numbers and emails replaced by placeholders."""
    text = " ".join(str(text or "").split())[:_MAX_LEN]
    text = _EMAIL_RE.sub("[email]", text)
    text = _MONEY_RE.sub("[amount]", text)
    return _LONG_NUMBER_RE.sub("[number]", text)


def classify(response):
    """(outcome, missing) for a chat response.

    outcome: answered, rewritten (rules didn't know the wording; the model restated it),
    partial (the reply says what it left out), unclear (asked the user to rephrase), error.
    """
    reply = str(response.get("reply") or "")
    note = _COVERAGE_NOTE_RE.search(reply)
    if response.get("context_source") == "rule_fallback":
        return "error", ""
    if response.get("answer_source") == "clarification" or _UNCLEAR_RE.search(reply):
        return "unclear", ""
    if note:
        return "partial", note.group(1)
    if reply.startswith("I read this as"):
        return "rewritten", ""
    return "answered", ""


def question_row(prompt, response):
    outcome, missing = classify(response or {})
    return {
        "question": mask_question(prompt),
        "intent": str((response or {}).get("intent") or "")[:40],
        "answer_source": str((response or {}).get("answer_source") or "")[:40],
        "outcome": outcome,
        "missing": missing[:200],
    }


def record_question(prompt, response):
    """Append the masked question and how it went to the log file. Never raises."""
    try:
        row = question_row(prompt, response)
        if not row["question"]:
            return
        row = {"asked_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), **row}
        with _WRITE_LOCK:
            os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
            with open(LOG_PATH, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(row) + "\n")
    except Exception as error:
        print(f"chat question log skipped: {type(error).__name__}")


def _insert_row(prompt, response):
    try:
        row = question_row(prompt, response)
        if not row["question"]:
            return
        from supabase_repo import supabase

        supabase.table("chat_question_log").insert(row).execute()
    except Exception as error:
        print(f"chat question log table write failed: {type(error).__name__}; using file")
        record_question(prompt, response)


def store_question(prompt, response):
    """Queue the masked question for the chat_question_log table. Never raises."""
    try:
        _DB_WRITER.submit(_insert_row, prompt, response)
    except Exception as error:
        print(f"chat question log skipped: {type(error).__name__}")
