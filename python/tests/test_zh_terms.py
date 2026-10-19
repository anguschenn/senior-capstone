import unittest

from ai.zh_terms import translate_chinese


class ChineseQuestionTests(unittest.TestCase):
    def test_common_questions_become_routing_words(self):
        cases = {
            "我这个月花了多少钱？": "this month how much did i spend",
            "上个月收入多少": "last month how much income",
            "十月餐饮花了多少": "october food how much did i spend",
            "两个月前花了多少": "2 months ago how much did i spend",
            "如果我把餐饮减少20%能省多少": "what if i food cut by 20",
        }
        for chinese, expected in cases.items():
            with self.subTest(chinese=chinese):
                self.assertIn(expected, translate_chinese(chinese))

    def test_english_text_is_unchanged(self):
        self.assertEqual(translate_chinese("How much did I spend?"), "How much did I spend?")
