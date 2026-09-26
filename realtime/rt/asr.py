"""sherpa-onnx 流式 ASR 封装（复用 transcribe.py 验证过的配置）。

用法：
    asr = StreamingASR()
    stream = asr.create_stream()
    for samples in chunks:            # np.float32 [-1,1] @ 16k mono
        text = asr.feed(stream, samples)   # 累计文本
    text = asr.finish(stream)
"""
from __future__ import annotations

import os

import numpy as np
import sherpa_onnx

from . import config

# 模型目录：默认 ~/speech2text/models/...（可用 LIVEBOOK_ASR_MODEL 覆盖）
DEFAULT_MODEL_DIR = config.ASR_MODEL_DIR


class StreamingASR:
    def __init__(self, model_dir: str = DEFAULT_MODEL_DIR, num_threads: int = 4,
                 decoding_method: str = "greedy_search"):
        self._model_dir = model_dir
        self._recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=os.path.join(model_dir, "tokens.txt"),
            encoder=os.path.join(model_dir, "encoder-epoch-99-avg-1.onnx"),
            decoder=os.path.join(model_dir, "decoder-epoch-99-avg-1.onnx"),
            joiner=os.path.join(model_dir, "joiner-epoch-99-avg-1.onnx"),
            num_threads=num_threads,
            decoding_method=decoding_method,
            provider="cpu",
        )

    def create_stream(self):
        return self._recognizer.create_stream()

    def feed(self, stream, samples: np.ndarray) -> str:
        """喂一段 16k 单声道 float32（[-1,1]），返回累计文本。"""
        stream.accept_waveform(16000, samples.astype(np.float32))
        while self._recognizer.is_ready(stream):
            self._recognizer.decode_stream(stream)
        return self._recognizer.get_result(stream)

    def finish(self, stream) -> str:
        stream.input_finished()
        while self._recognizer.is_ready(stream):
            self._recognizer.decode_stream(stream)
        return self._recognizer.get_result(stream)
