"""Remembered model rewrites of chat wordings the rules didn't recognise (migration 014).

The first time someone asks "how cooked am I on food", ChatService pays for one model call
to restate it; the restatement is stored here, so the same wording from anyone afterwards
is answered by the rules with no model call. The answer itself is never stored: the
numbers are recomputed from each user's own data every time.

Only wordings with nothing to mask (no amounts, emails or long numbers, see
question_log.mask_question) are stored, so no one's figures are kept or shared. Every
method swallows errors: a missing table just means no caching.
"""

import datetime as dt
import threading
from collections import OrderedDict

from .question_log import mask_question

_MAX_MEMORY = 500


def question_key(message):
    """Normalized wording, or "" when the message holds anything that would be masked."""
    collapsed = " ".join(str(message or "").split())
    if not collapsed or len(collapsed) > 300 or mask_question(collapsed) != collapsed:
        return ""
    return collapsed.lower()


class SupabaseRewriteCache:
    def __init__(self, client=None):
        self._client = client
        self._memory = OrderedDict()
        self._lock = threading.Lock()

    def _table(self):
        if self._client is None:
            from supabase_repo import supabase

            self._client = supabase
        return self._client.table("chat_rewrite_cache")

    def _remember(self, key, rewritten):
        with self._lock:
            self._memory[key] = rewritten
            self._memory.move_to_end(key)
            while len(self._memory) > _MAX_MEMORY:
                self._memory.popitem(last=False)

    def get(self, message):
        """The stored rewrite, or None."""
        key = question_key(message)
        if not key:
            return None
        with self._lock:
            if key in self._memory:
                self._memory.move_to_end(key)
                return self._memory[key]
        try:
            rows = (
                self._table().select("rewritten,hits").eq("question_key", key).limit(1).execute()
            ).data or []
        except Exception as error:
            print(f"rewrite cache read skipped: {type(error).__name__}")
            return None
        if not rows or not rows[0].get("rewritten"):
            return None
        rewritten = str(rows[0]["rewritten"])
        self._remember(key, rewritten)
        try:
            self._table().update(
                {
                    "hits": int(rows[0].get("hits") or 0) + 1,
                    "last_used_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                }
            ).eq("question_key", key).execute()
        except Exception:
            pass
        return rewritten

    def put(self, message, rewritten):
        key = question_key(message)
        rewritten = str(rewritten or "").strip()[:160]
        if not key or not rewritten:
            return
        self._remember(key, rewritten)
        try:
            self._table().upsert(
                {"question_key": key, "rewritten": rewritten}, on_conflict="question_key"
            ).execute()
        except Exception as error:
            print(f"rewrite cache write skipped: {type(error).__name__}")
