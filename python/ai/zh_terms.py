"""Turn common Chinese finance questions into the English wording the routing rules read.

"我这个月花了多少钱？" becomes roughly "i this month how much did i spend ?", which the
English rules already answer. Answers stay in English like the rest of the app. Longer
phrases come first so "上个月" is not read as "上" + "个月".
"""

import re

_CN_DIGITS = {
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
    "十": 10,
    "十一": 11,
    "十二": 12,
}
_MONTH_NAMES = [
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
]

_PHRASES = [
    # Small talk and app words
    (r"^(你好|您好|嗨|哈喽)[！!。.]*$", " hi "),
    (r"^(谢谢|多谢|感谢|谢了)[！!。.]*$", " thanks "),
    (r"净资产", " net worth "),
    (r"交易笔数|多少笔|几笔", " how many transactions "),
    (r"收入的百分之多少|百分之多少", " what percent of my income do i spend "),
    (r"每天平均|平均每天|日均", " per day "),
    (r"预算设成|预算设为|设置预算|设预算", " set a budget "),
    (r"为什么是负的|为什么为负|为什么是负数", " why is my net worth negative "),
    (r"最大的开销|最大开销|最大的支出|最大支出|开销最大|花得最多的是什么", " top category "),
    (r"前一个月|上上个月", " 2 months ago "),
    (r"大概存多少|每个月存多少|每月存多少|平均存多少", " average net cash flow per month "),
    (r"最近(?!的交易|交易|几笔|30天|7天|一周|一个月|买)", " lately "),
    (r"总结|概况|汇总", " summary "),
    (r"奶茶", " bubble tea "),
    (r"咖啡", " coffee "),
    (r"不买|不喝|不点", " don t buy "),
    (r"要多久|需要多久|多长时间|多久", " how long would it take to "),
    (r"存(\d+)", r" save \1 "),
    (r"平时|通常|一般", " usually "),
    (r"一共|总共|合计", " total "),
    # Time
    (r"这个月|本月|这月", " this month "),
    (r"上个月|上月", " last month "),
    (r"今年", " this year "),
    (r"去年", " last year "),
    (r"昨天", " yesterday "),
    (r"今天", " today "),
    (r"上周|上星期|最近一周|过去一周|最近7天|近7天", " last 7 days "),
    (r"最近30天|过去30天|近30天|最近一个月", " last 30 days "),
    (r"下个月|下月", " next month "),
    # Questions about amounts
    (r"花了多少钱|花了多少|花多少钱|花多少|消费了多少|支出多少|开销多少", " how much did i spend "),
    (r"赚了多少|挣了多少|收入多少|进账多少", " how much income "),
    (r"净收入|结余|净现金流|存了多少|存下多少", " net cash flow "),
    (r"有多少钱|余额|存款", " my balance "),
    (
        r"哪一类花得最多|哪类花得最多|哪个类别花得最多|最大的支出类别|哪类最多|哪一类最多",
        " top category ",
    ),
    (r"哪个月", " which month "),
    (r"花得最多|花最多", " spent the most "),
    (r"花得最少|花最少", " spent the least "),
    (
        r"是在增加还是减少|在增加还是减少|是增加还是减少|增加还是减少|变多还是变少",
        " going up or down ",
    ),
    (r"越来越高|越来越多|越来越贵", " been increasing "),
    (r"越来越低|越来越少", " been decreasing "),
    (r"在增加|在变多", " been increasing "),
    (r"在减少|在变少", " been decreasing "),
    (r"分析一下|分析", " overview "),
    (r"每周|每星期|每个星期", " every week "),
    (r"每天", " every day "),
    (r"一年", " a year "),
    (r"能省多少|可以省多少|省下多少|能省|可以省", " how much save "),
    (r"少花(\d+)", r" \1 less "),
    (r"块钱|块|元|美元|刀", " "),
    (r"最近的交易|最近交易|最近几笔|交易记录|消费记录", " recent transactions "),
    (r"买了什么|买了啥|买了哪些", " what did i buy "),
    (r"平均每个月|每个月平均|平均每月|月均", " average per month "),
    (r"赚的比花的多|收入比支出多|赚得比花得多", " earn more than i spent "),
    (r"钱都花在哪|钱花在哪|浪费", " where does my money go "),
    (r"最大的一笔|最贵的一笔", " biggest purchase "),
    (r"怎么样|情况如何|表现如何|过得怎么样", " how am i doing "),
    (r"会花多少|大概花多少|预计花多少", " how much will i spend "),
    (r"花太多|花得太多|花多了|太多", " spend too much "),
    # Categories
    (r"吃饭|餐饮|饮食|外卖|吃喝|吃的|食物|伙食", " food "),
    (r"交通|打车|出行|通勤", " transport "),
    (r"购物|买东西|网购", " shopping "),
    (r"订阅", " subscriptions "),
    (r"娱乐", " entertainment "),
    (r"房租|住房|租金", " rent "),
    (r"医疗|看病", " health "),
    (r"水电|账单", " bills "),
    # Actions and logic
    (r"为什么|为啥", " why "),
    (r"怎么省钱|如何省钱|怎样省钱", " how can i save money "),
    (r"怎么|如何|怎样", " how can i "),
    (r"省钱|存钱", " save money "),
    (r"建议", " advice "),
    (r"如果|假如|要是", " what if "),
    (r"减少|降低|砍掉|砍|少花", " cut "),
    (r"取消", " cancel "),
    (r"比较|对比", " compare "),
    (r"相比|比", " than "),
    (r"和|跟|与|以及", " and "),
    (r"不算|除了|不包括|排除", " not counting "),
    (r"支出|开销|消费|花费|花销", " spending "),
    (r"收入", " income "),
    (r"预算", " budget "),
    (r"多少", " how much "),
    (r"我的|我", " i "),
]
_COMPILED = [(re.compile(pattern), repl) for pattern, repl in _PHRASES]
_HAN_RE = re.compile(r"[一-鿿]")


def _month_word(match):
    raw = match.group(1)
    num = int(raw) if raw.isdigit() else _CN_DIGITS.get(raw, 0)
    if 1 <= num <= 12:
        return f" {_MONTH_NAMES[num - 1]} "
    return match.group(0)


def _months_ago(match):
    raw = match.group(1)
    num = int(raw) if raw.isdigit() else _CN_DIGITS.get(raw, 0)
    return f" {num} months ago " if num else match.group(0)


def translate_chinese(text):
    """English routing words for Chinese text; text without Chinese is returned unchanged."""
    if not isinstance(text, str) or not _HAN_RE.search(text):
        return text
    out = re.sub(r"(\d{1,2}|十[一二]?|[一二两三四五六七八九])个月前", _months_ago, text)
    out = re.sub(r"(\d{1,2}|十[一二]|十|[一二三四五六七八九])月份?", _month_word, out)
    out = re.sub(r"百分之(\d{1,3})", r" by \1 ", out)
    out = re.sub(r"(\d{1,3})\s*[%％]", r" by \1 ", out)
    for pattern, repl in _COMPILED:
        out = pattern.sub(repl, out)
    out = _HAN_RE.sub(" ", out)
    return re.sub(r"\s+", " ", out).strip()
