"""智能记账:自然语言解析(本地规则,无 LLM)。
"昨天午饭花了35.5" → {date:昨天, payee:午饭, category:食物, amount:35.5}
规则:金额正则 + 类别关键词词典 + 日期相对词 + 剩余文本作事项。"""
import re
from datetime import date, timedelta

# 类别词典(按现有 ledger_categories;命中优先级从上到下)
CAT_KEYWORDS = {
    "食物": ["吃", "饭", "早餐", "午饭", "晚餐", "宵夜", "咖啡", "奶茶", "外卖", "水果", "零食", "饮料", "买菜", "超市"],
    "人情": ["随礼", "红包", "礼金", "份子", "送礼", "请客", "朋友", "同事结婚"],
    "娱乐旅游": ["电影", "游戏", "充值", "会员", "视频", "ktv", "门票", "旅游", "景点", "酒店", "机票", "火车"],
    "旅行": ["出差", "旅行", "度假", "民宿"],
    "房屋": ["房租", "房贷", "水费", "电费", "燃气", "物业", "宽带", "网费"],
    "医疗": ["药", "医院", "挂号", "看病", "体检", "牙", "眼镜"],
    "个人物品": ["衣服", "鞋", "手机", "电脑", "数码", "理发", "洗漱", "日用品", "书", "充电"],
}
# 动词/杂项词(帮助定位事项,不参与归类)
NOISE = ["花了", "花费", "支出", "消费", "付了", "买了", "用了", "一共", "总共", "块钱", "元", "¥", "￥"]


def _parse_amount(text: str):
    m = re.search(r"(\d+(?:\.\d{1,2})?)\s*(?:块|元|块钱|¥|￥)?", text)
    if not m:
        return None, text
    return float(m.group(1)), text[:m.start()] + text[m.end():]


def _parse_date(text: str):
    """返回 (iso_date, 清理后文本)。默认今天。"""
    today = date.today()
    if "前天" in text:
        d = today - timedelta(days=2)
    elif "昨天" in text:
        d = today - timedelta(days=1)
    elif "今天" in text or "刚" in text:
        d = today
    else:
        m = re.search(r"(\d{1,2})月(\d{1,2})[日号]", text)
        if m:
            try:
                d = date(today.year, int(m.group(1)), int(m.group(2)))
                if d > today:
                    d = d.replace(year=today.year - 1)
            except ValueError:
                d = today
        else:
            return today.isoformat(), text
    text = re.sub(r"(前天|昨天|今天|刚|\d{1,2}月\d{1,2}[日号])", "", text)
    return d.isoformat(), text


def _parse_category(text: str):
    for cat, kws in CAT_KEYWORDS.items():
        for kw in kws:
            if kw in text:
                return cat, text
    return "其他", text


def _parse_payee(text: str):
    for n in NOISE:
        text = text.replace(n, " ")
    text = re.sub(r"[,，。!!.、\s]+", " ", text).strip()
    return text[:30] or None


def parse_entry(text: str) -> dict:
    """主入口:自然语言 → 记账字段。解析不了金额抛 ValueError。"""
    # 先剥日期(防止『9月28号买菜86』把日期的 9 当成金额)
    d, rest = _parse_date(text)
    amount, rest = _parse_amount(rest)
    if amount is None or amount <= 0:
        amount, rest = _parse_amount(text)   # 回退全文再试一次
        if amount is None or amount <= 0:
            raise ValueError("没识别到金额,试试『午饭花了35』")
    cat, _ = _parse_category(text)   # 归类看全文(关键词可能被金额切断)
    payee = _parse_payee(rest) or cat
    return {"date": d, "payee": payee, "category": cat, "amount": amount,
            "note": text.strip()}
