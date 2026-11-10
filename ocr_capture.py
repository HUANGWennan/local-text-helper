#!/usr/bin/env python3
"""Local screenshot-to-text and LaTeX using the existing Qwen3.5 vision model."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from ollama_runtime import chat

PROMPT = """Transcribe EVERY visible word and mathematical formula from this image exactly. This is OCR, NOT a math solution.
Output text in original reading order, retaining headings, line breaks and Chinese/English wording.
Represent each mathematical expression in Microsoft Word compatible LaTeX, with inline equations in $...$ and separate equations in $$...$$. Matrices: use \\begin{bmatrix} ... \\end{bmatrix}; derivatives, subscripts, fractions, inequalities, Greek symbols must be accurate.
Do not calculate, correct, interpret or explain any formula. Do not invent text obscured or absent. For unreadable sections use [无法辨认]. No commentary, no markdown code fence."""
def recognize(image_path: Path):
    if not image_path.is_file() or image_path.stat().st_size == 0:
        raise ValueError("截图文件不存在或为空。")
    encoded = base64.b64encode(image_path.read_bytes()).decode("ascii")
    response = chat({
        "model": "qwen3.5:4b",
        "stream": False, "think": False,
        "messages": [{"role":"user", "content":PROMPT,
                      "images":[encoded]}],
        "options":{"temperature":0, "num_ctx":8192, "num_predict":2600},
    }, timeout=180)
    if response.get("done_reason") == "length":
        raise ValueError("识别结果过长，截图区域请缩小后重试。")
    result = response.get("message",{}).get("content","").strip()
    if not result:
        raise ValueError("模型未返回文字。")
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=Path)
    parser.add_argument("--capture", action="store_true")
    args = parser.parse_args()
    if not args.capture and args.file is None:
        parser.error("provide --capture or --file PATH")
    temporary = None
    try:
        if args.capture:
            with tempfile.NamedTemporaryFile(suffix=".png", prefix="local-text-helper-ocr-", delete=False) as file:
                temporary = Path(file.name)
            temporary.unlink()
            process = subprocess.run(["/usr/sbin/screencapture", "-i", "-x", str(temporary)], timeout=180)
            if process.returncode != 0 or not temporary.exists():
                print(json.dumps({"cancelled":True}, ensure_ascii=False))
                return
            file = temporary
        else:
            file = args.file
        result = recognize(file)
        print(json.dumps({"text":result},ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"error":str(exc)},ensure_ascii=False))
        sys.exit(1)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
if __name__=="__main__":
    main()
