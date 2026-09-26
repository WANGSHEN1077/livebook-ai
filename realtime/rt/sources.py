"""事件源：把音频/视频统一成 (t, 数据块) 时间戳流。

- ReplayAudioSource：16k 单声道 WAV 分块（P2 回放验证用，无需 BlackHole）
- LiveAudioSource：sounddevice + BlackHole 实时捕获（P2 实时模式，需装 BlackHole）
- ReplayFrameSource：PyAV 按间隔抽视频帧 → PNG（P3 回放 OCR）
- ScreenSource：screencapture 抓屏 → PNG（P3 实时 OCR）
"""
from __future__ import annotations

import os
import subprocess
import time
import wave
from typing import Iterator, Optional, Tuple

import numpy as np

CHUNK_SECONDS = 0.5

# 画面区域（归一化坐标，Vision 原点左下）
DANMAKU_REGION = (0.72, 0.0, 1.0, 1.0)    # 右侧弹幕栏
COVER_REGION = (0.12, 0.28, 0.88, 0.78)   # 中央封面区


class ReplayAudioSource:
    """16k 单声道 16-bit WAV → 0.5s 分块，带音频时间戳。"""

    def __init__(self, wav_path: str, chunk_seconds: float = CHUNK_SECONDS,
                 start: float = 0.0, end: Optional[float] = None):
        self._path = wav_path
        self._chunk = int(chunk_seconds * 16000)
        self._start = start
        self._end = end

    def __iter__(self) -> Iterator[Tuple[float, np.ndarray]]:
        with wave.open(self._path, "rb") as w:
            assert w.getnchannels() == 1, w.getnchannels()
            assert w.getsampwidth() == 2, w.getsampwidth()
            rate = w.getframerate()
            assert rate == 16000, rate
            total = w.getnframes()
            w.setpos(int(self._start * rate))
            end_frame = int(self._end * rate) if self._end else total
            t = self._start
            while w.tell() < end_frame:
                raw = w.readframes(min(self._chunk, end_frame - w.tell()))
                samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                yield (t, samples)
                t += len(samples) / rate   # 秒，不是采样数


class LiveAudioSource:
    """BlackHole 虚拟声卡实时捕获（sounddevice）。

    前提：
      1. brew install blackhole-2ch（并把直播窗口的声音输出路由到 BlackHole）
      2. 终端/App 授予麦克风权限
    用法：
      src = LiveAudioSource()
      for t, samples in src:   # 阻塞式无限流
          ...
    """

    def __init__(self, chunk_seconds: float = CHUNK_SECONDS):
        import sounddevice as sd
        self._sd = sd
        self._chunk = int(chunk_seconds * 16000)
        self._device = None
        # 找到 BlackHole 输入设备
        for i, d in enumerate(sd.query_devices()):
            name = d["name"].lower()
            if "blackhole" in name and d["max_input_channels"] > 0:
                self._device = i
                break
        if self._device is None:
            raise RuntimeError(
                "未找到 BlackHole 输入设备。请先: brew install blackhole-2ch，"
                "并把直播窗口的声音输出路由到 BlackHole。"
            )

    def __iter__(self) -> Iterator[Tuple[float, np.ndarray]]:
        import queue
        q: queue.Queue = queue.Queue()
        frames = 0

        def callback(indata, _frames, _time_info, status):
            q.put(indata.copy())

        with self._sd.InputStream(device=self._device, samplerate=16000,
                                  channels=1, dtype="float32",
                                  blocksize=self._chunk, callback=callback):
            while True:
                data = q.get()
                t = frames * self._chunk / 16000.0
                frames += len(data)
                yield (t, data[:, 0])


class ReplayFrameSource:
    """PyAV 从视频按间隔抽帧，存 PNG，yield (t, png_path)。"""

    def __init__(self, video_path: str, interval: float = 2.0,
                 out_dir: str = "/tmp/rt_frames", max_frames: Optional[int] = None,
                 start: float = 0.0):
        self._video = video_path
        self._interval = interval
        self._out_dir = out_dir
        self._max_frames = max_frames
        self._start = start

    def __iter__(self) -> Iterator[Tuple[float, str]]:
        import av
        os.makedirs(self._out_dir, exist_ok=True)
        container = av.open(self._video)
        stream = container.streams.video[0]
        target = self._start
        count = 0
        try:
            for frame in container.decode(stream):
                t = float(frame.time)
                if t < target:
                    continue
                if self._max_frames is not None and count >= self._max_frames:
                    break
                img = frame.to_image()  # PIL Image
                path = os.path.join(self._out_dir, f"f_{int(t * 10):08d}.png")
                img.save(path)
                yield (t, path)
                target += self._interval
                count += 1
        finally:
            container.close()


class ScreenSource:
    """screencapture 按间隔抓屏 → PNG，yield (t, png_path)。

    region: 像素 (x, y, w, h)；None = 全屏。需要屏幕录制权限。
    """

    def __init__(self, region: Optional[Tuple[int, int, int, int]] = None,
                 interval: float = 2.0, out_dir: str = "/tmp/rt_screen"):
        self._region = region
        self._interval = interval
        self._out_dir = out_dir

    def __iter__(self) -> Iterator[Tuple[float, str]]:
        os.makedirs(self._out_dir, exist_ok=True)
        while True:
            start = time.time()
            path = os.path.join(self._out_dir, f"s_{int(start * 10):08d}.png")
            cmd = ["screencapture", "-x"]
            if self._region:
                x, y, w, h = self._region
                cmd += ["-R", f"{x},{y},{w},{h}"]
            cmd.append(path)
            subprocess.run(cmd, check=True)
            yield (start, path)
            elapsed = time.time() - start
            if self._interval - elapsed > 0:
                time.sleep(self._interval - elapsed)
