"""macOS Vision OCR 封装（pyobjc，零模型下载，Apple Silicon 快）。

ocr_png(path) -> [(text, confidence, box)]，box 为 Vision 归一化坐标
（原点左下，单位正方形）。
"""
from __future__ import annotations

from typing import List, Optional, Tuple

import Vision
import Foundation

LANGUAGES = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]


def crop(src: str, dst: str, x0: float, y0: float, x1: float, y1: float) -> None:
    """按归一化坐标裁剪 PNG（Vision 原点左下 → PIL 原点左上需翻转 y）。"""
    from PIL import Image
    im = Image.open(src)
    w, h = im.size
    left, right = int(x0 * w), int(x1 * w)
    top = int((1 - y1) * h)
    bottom = int((1 - y0) * h)
    im.crop((left, top, right, bottom)).save(dst)


class VisionOCR:
    def __init__(self, languages: Optional[List[str]] = None, accurate: bool = True):
        self._languages = languages or LANGUAGES
        self._accurate = accurate

    def recognize(self, image_path: str) -> List[Tuple[str, float, Tuple[float, float, float, float]]]:
        """识别一张 PNG/JPEG，返回 [(text, confidence, (x,y,w,h))]。
        box 为 Vision 归一化坐标（原点左下）。"""
        url = Foundation.NSURL.fileURLWithPath_(image_path)
        req = Vision.VNRecognizeTextRequest.alloc().init()
        req.setRecognitionLevel_(
            Vision.VNRequestTextRecognitionLevelAccurate if self._accurate
            else Vision.VNRequestTextRecognitionLevelFast)
        req.setUsesLanguageCorrection_(True)
        req.setRecognitionLanguages_(self._languages)

        handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, None)
        ok, err = handler.performRequests_error_([req], None)
        if not ok:
            return []
        out: List[Tuple[str, float, Tuple[float, float, float, float]]] = []
        for obs in (req.results() or []):
            cands = obs.topCandidates_(1)
            if not cands or len(cands) == 0:
                continue
            cand = cands[0]
            text = cand.string()
            if not text:
                continue
            b = obs.boundingBox()
            box = (b.origin.x, b.origin.y, b.size.width, b.size.height)
            out.append((text, float(cand.confidence()), box))
        return out

    def recognize_region(self, image_path: str, x0: float, y0: float,
                         x1: float, y1: float) -> List[Tuple[str, float, Tuple[float, float, float, float]]]:
        """只返回与区域相交的观察（归一化坐标，Vision 原点左下）。
        区域用 (x0,y0,x1,y1) 表示。"""
        results = self.recognize(image_path)
        filtered = []
        for text, conf, (bx, by, bw, bh) in results:
            midx, midy = bx + bw / 2, by + bh / 2
            if x0 <= midx <= x1 and y0 <= midy <= y1:
                filtered.append((text, conf, (bx, by, bw, bh)))
        return filtered
