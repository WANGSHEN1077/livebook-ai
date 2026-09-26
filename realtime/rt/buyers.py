"""买家目录 + 中文数字转换。

名单来源（按优先级）：
1. 环境变量 `LIVEBOOK_BUYERS` 指定的 JSON
2. `realtime/buyers.json`（真实名单，**不入仓库**）
3. `realtime/buyers.example.json`（虚构示例，随仓库分发）

JSON 结构见 `buyers.example.json`：`{"buyers": {规范名: [别名...]}, "hosts": [...], "system_keywords": [...]}`。
这样公开仓库里不含真实客户名单，本机使用真实名单即可。
"""
from __future__ import annotations

import json
import os

from . import config

# 规范名 -> 别名列表（弹幕精确用户名 + ASR 误识别）
BUYER_ALIASES: dict[str, list[str]] = {}
# 主播/平台账号标记（永不参与出价）
HOST_NAMES: set[str] = set()
# 非出价的系统/礼物行
SYSTEM_KEYWORDS: list[str] = []


def _catalog_path() -> str:
    """优先真实名单（buyers.json），缺失则用示例。"""
    if os.path.exists(config.BUYERS_FILE):
        return config.BUYERS_FILE
    return config.BUYERS_EXAMPLE_FILE


def reload_catalog(path: str | None = None) -> str:
    """（重新）载入名单，返回实际使用的文件路径。

    测试可用它切到固定 fixture，保证断言与真实名单无关。
    """
    global BUYER_ALIASES, HOST_NAMES, SYSTEM_KEYWORDS
    p = path or _catalog_path()
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
    BUYER_ALIASES = {k: list(v) for k, v in (data.get("buyers") or {}).items()}
    HOST_NAMES = set(data.get("hosts") or [])
    SYSTEM_KEYWORDS = list(data.get("system_keywords") or [])
    return p


reload_catalog()  # 导入时载入


def normalize(s: str) -> str:
    """去空白/标点，保留汉字/字母/数字。"""
    return "".join(ch for ch in s.lower() if ch.isalnum() or "\u4e00" <= ch <= "\u9fff")


def canonical_buyer(raw: str) -> str | None:
    n = normalize(raw)
    if not n:
        return None
    for canonical, aliases in BUYER_ALIASES.items():
        for a in aliases:
            if normalize(a) == n:
                return canonical
    for canonical, aliases in BUYER_ALIASES.items():
        for a in aliases:
            if len(a) >= 2 and len(n) >= 2:
                if n in a or a in n:
                    return canonical
    return None


def is_host(raw: str) -> bool:
    n = normalize(raw)
    return any(normalize(h) and (n in normalize(h) or normalize(h) in n) for h in HOST_NAMES)


def is_system_line(raw: str) -> bool:
    n = normalize(raw)
    return any(k in n for k in SYSTEM_KEYWORDS)


# —— 中文数字 → int（支持 十/百/千 与口语形式：一百五=150）——
_CJK_DIGITS = {"零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
               "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}


def cjk_number(s: str) -> int | None:
    total, current = 0, 0
    pending_hundred = False
    has_digit = has_any = False
    for ch in s:
        if ch in _CJK_DIGITS:
            current = _CJK_DIGITS[ch]
            has_digit = has_any = True
            if pending_hundred:      # "X百Y" → Y 是十位（一百五=150）
                total += current * 10
                current = 0
                pending_hundred = False
        elif ch == "十":
            total += (current or 1) * 10
            current = 0
            pending_hundred = False
            has_any = True
        elif ch == "百":
            total += (current or 1) * 100
            current = 0
            pending_hundred = True
            has_any = True
        elif ch == "千":
            total += (current or 1) * 1000
            current = 0
            pending_hundred = False
            has_any = True
        else:
            return None
    if not has_any:
        return None
    if has_digit:
        total += current
    return total
