"""The chat exam: a frozen set of questions about a made-up account (tests/exam_fixture.py)
with answers worked out from its rows, run on every change. Don't edit the questions or
answers to make a change pass; fix the chat, or add a new exam version.

Stop rule: no wrong number or yes/no, and at most 3% of questions off target (not
answered, answered when chat should say it can't, a month/category/merchant asked about
left out, no yes or no, or handed to the model)."""

import json
import re
import unittest
from pathlib import Path

import exam_fixture

from ai.chat_service import ChatService

EXAM = json.loads((Path(__file__).parent / "data" / "chat_exam_v1.json").read_text())
MAX_OFF_TARGET = 0.03

_YES_NO_RE = re.compile(r'^(?:I read this as "[^"]*" )?(Yes|No)\b')
_SAYS_CANT_RE = re.compile(
    r"^(I can't|I'm not sure|I don't see|Chat (only|doesn't|has)|Please clarify|"
    r"I answer questions about|\S+ isn't among)|can't answer that|can't (add|split|tell|total)|"
    r"hasn't happened yet",
    re.IGNORECASE,
)


def _amounts(reply):
    return [float(x.replace(",", "")) for x in re.findall(r"\$(\d[\d,]*(?:\.\d+)?)", reply)]


def grade(item, response):
    """("ok" | "off_target" | "wrong", why) for one answer."""
    reply = str(response.get("reply") or "")
    said_cant = bool(_SAYS_CANT_RE.search(reply))
    if item.get("refuse"):
        return ("ok", "") if said_cant else ("off_target", "answered; should say it can't")
    if response.get("answer_source") != "deterministic":
        return "off_target", f"answer_source {response.get('answer_source')}"
    if said_cant:
        return "off_target", "said it can't answer"
    if item.get("yes_no"):
        given = _YES_NO_RE.search(reply)
        if given and given.group(1) != item["yes_no"]:
            return "wrong", f"said {given.group(1)}, should be {item['yes_no']}"
    shown = _amounts(reply)
    for expected in item.get("numbers", []):
        value = float(expected.strip("$").replace(",", ""))
        if not any(abs(value - amount) <= 1 for amount in shown):
            return "wrong", f"no {expected} in the reply"
    if item.get("yes_no") and not _YES_NO_RE.search(reply):
        return "off_target", "no yes or no"
    for word in item.get("mentions", []):
        if word.lower() not in reply.lower():
            return "off_target", f"doesn't mention {word}"
    return "ok", ""


class ChatExamTests(unittest.TestCase):
    def setUp(self):
        exam_fixture.pin_today(self)

    def test_exam(self):
        summary = exam_fixture.summary()
        service = ChatService(
            # The exam measures the rules: the model is never reached.
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )
        results = []
        for item in EXAM["items"]:
            response = service.handle_chat(
                {"prompt": item["q"], "history": [], "spending_summary": summary},
                user_id="exam",
            )
            verdict, why = grade(item, response)
            results.append((item, verdict, why, str(response.get("reply") or "")))
        wrong = [r for r in results if r[1] == "wrong"]
        off = [r for r in results if r[1] == "off_target"]
        report = "\n".join(
            f"  #{item['id']} [{verdict}] {item['q']} -- {why}\n      {reply[:200]}"
            for item, verdict, why, reply in wrong + off
        )
        limit = int(MAX_OFF_TARGET * len(results))
        summary_line = (
            f"{len(results)} questions: {len(wrong)} wrong, {len(off)} off target (allowed {limit})"
        )
        self.assertFalse(wrong or len(off) > limit, f"{summary_line}\n{report}")


if __name__ == "__main__":
    unittest.main()
