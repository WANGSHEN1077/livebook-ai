"""集中配置：所有路径默认基于用户主目录，且都可被环境变量覆盖。

公开仓库里不出现任何个人绝对路径；本机使用时无需任何配置即可工作
（只要项目放在 ~/Documents/livebook-ai、ASR 资产在 ~/speech2text）。
"""
from __future__ import annotations

import os

HOME = os.path.expanduser("~")
_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # realtime/


def _env(name: str, default: str) -> str:
    return os.environ.get(name) or default


# —— 项目与开发素材 ——
PROJECT_ROOT = _env("LIVEBOOK_ROOT", os.path.join(HOME, "Documents", "livebook-ai"))
# 回放视频（开发/校准用，不入仓库）
REPLAY_VIDEO = _env(
    "LIVEBOOK_REPLAY",
    os.path.join(PROJECT_ROOT, "mac-app", "LiveBookAI", "media", "直播回放-08月13日.mp4"))
# 从回放抽出的 16k 单声道 WAV（afconvert 生成）
REPLAY_WAV = _env("LIVEBOOK_REPLAY_WAV", "/tmp/lb0813_16k.wav")

# —— ASR 资产（sherpa-onnx 模型，不入仓库）——
SPEECH2TEXT_ROOT = _env("SPEECH2TEXT_ROOT", os.path.join(HOME, "speech2text"))
ASR_MODEL_DIR = _env(
    "LIVEBOOK_ASR_MODEL",
    os.path.join(SPEECH2TEXT_ROOT, "models",
                 "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"))

# —— 历史数据（校准/验证脚本用，不入仓库）——
TRANSCRIPT_0813 = _env("LIVEBOOK_TRANSCRIPT_0813", "/tmp/0813_transcript.json")
SALES_0813 = _env("LIVEBOOK_SALES_0813", "/tmp/sales_0813_timed.json")
DANMU_0816 = _env("LIVEBOOK_DANMU_0816", os.path.join(SPEECH2TEXT_ROOT, "danmu_0816.json"))
DANMU_0816_RECORDS = _env("LIVEBOOK_DANMU_0816_RECORDS",
                          os.path.join(SPEECH2TEXT_ROOT, "danmu_0816_records.json"))

# —— 买家名单（真实名单不入仓库）——
# 默认读 realtime/buyers.json（gitignored）；不存在则退回 buyers.example.json（虚构示例）
BUYERS_FILE = _env("LIVEBOOK_BUYERS", os.path.join(_HERE, "buyers.json"))
BUYERS_EXAMPLE_FILE = os.path.join(_HERE, "buyers.example.json")

# —— 会话导出目录 ——
SESSION_ROOT = _env("LIVEBOOK_SESSIONS", "/tmp/live_sessions")
