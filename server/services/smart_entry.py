"""智能记账:自然语言解析(本地规则,无 LLM)。
"昨天午饭花了35.5" → {date:昨天, payee:午饭, category:食物, amount:35.5}
规则:金额正则 + 类别关键词词典 + 日期相对词 + 剩余文本作事项。"""
import re
from datetime import date, timedelta

# 类别词典(按现有 ledger_categories;命中优先级从上到下)
CAT_KEYWORDS = {
    "投资": ["荐股", "会员群", "股票账户", "基金", "理财", "定投"],
    "人情": ["随礼", "红包", "礼金", "份子", "送礼", "请客", "请同事", "请朋友", "请同学",
             "转账", "买酒", "茶叶", "代付"],
    "医疗": ["买药", "药", "口罩", "医院", "挂号", "看病", "体检", "牙", "眼镜", "检查"],
    "住宿": ["酒店", "民宿", "住宿", "旅馆", "房费"],
    "交通": ["打车", "滴滴", "出租", "公交", "地铁", "高铁", "火车", "机票", "船票", "车票",
             "加油", "停车", "单车", "车费", "交通"],
    "娱乐": ["电影", "游戏", "门票", "景点", "ktv", "麻将", "抖音", "游玩", "演唱会"],
    "购物": ["衣服", "T恤", "裤", "鞋", "手机", "电脑", "耳机", "数码", "家电", "日用",
             "洗漱", "理发", "剪头发", "家居", "书"],
    "食物": ["吃", "饭", "早餐", "午餐", "午饭", "晚餐", "晚饭", "宵夜", "咖啡", "奶茶",
             "外卖", "水果", "零食", "饮料", "买菜", "食堂", "超市", "矿泉水"],
    "房屋": ["房租", "房贷", "水费", "电费", "燃气", "物业", "宽带", "网费"],
}

# 动词/杂项词(帮助定位事项,不参与归类)
NOISE = ["花了", "花费", "支出", "消费", "付了", "买了", "用了", "一共", "总共", "块钱", "元", "¥", "￥"]



def cn2num(s: str) -> int:
    """中文数字→整数(万内):十五=15 一百零五=105 两千三=2300 两万五=25000。"""
    d = {"零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
         "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
    unit = {"十": 10, "百": 100, "千": 1000}
    total = section = num = 0
    last_unit = 1
    saw_ling = False
    for ch in s:
        if ch in d:
            num = d[ch]
            if ch == "零":
                saw_ling = True
        elif ch == "万":
            section = (section + num) * 10000
            total += section
            section = num = 0
            last_unit = 10000
        elif ch in unit:
            section += (num or 1) * unit[ch]
            last_unit = unit[ch]
            num = 0
            saw_ling = False
    total += section
    # 节尾单数字按上一单位/10:「两千三」=2300(不是2003);
    # 但「零」之后是零头不加位:「一百零五」=105(不是150)
    if num and last_unit >= 100 and not saw_ling:
        num *= last_unit // 10
    return total + num

def _parse_amount(text: str):
    # 口语金额规整:「2块5/2块5毛/2元5」→ 2.5(否则"2块5"会被截成 2)
    text = re.sub(r"(\d+)\s*[块元]\s*(\d)(?:\s*[毛角])?(?!\d)", r"\1.\2", text)
    # 先找带单位(块/元/¥)的数字;没有单位时取末位数字(口语金额通常垫尾:「奶茶3杯 72」)
    m = re.search(r"(\d+(?:\.\d{1,2})?)\s*(?:块|元|块钱|¥|￥)", text)
    if not m:
        cands = list(re.finditer(r"(\d+(?:\.\d{1,2})?)", text))
        m = cands[-1] if cands else None
    if not m:
        # 中文数字金额:「十五/三十块/一百零五元/十五块五(毛)」
        mc = re.search(r"([零一二两三四五六七八九十百千万]{1,8})"
                       r"\s*[块元](?:\s*([零一二三四五六七八九])(?:\s*[毛角])?)?(?![零一二两三四五六七八九十百千万])", text)
        if mc:
            v = cn2num(mc.group(1))
            if v > 0:
                if mc.group(2):
                    v += {"零":0,"一":1,"二":2,"两":2,"三":3,"四":4,
                          "五":5,"六":6,"七":7,"八":8,"九":9}[mc.group(2)] * 0.1
                return float(v), text[:mc.start()] + text[mc.end():]
        # 裸中文数字(无单位):「打车花了十五」
        mc2 = re.search(r"(?:花了|花费|消费|支出|付了?|充了?)\s*([零一二两三四五六七八九十百千万]{1,8})", text)
        if mc2:
            v = cn2num(mc2.group(1))
            if v > 0:
                return float(v), text[:mc2.start()] + text[mc2.end():]
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
