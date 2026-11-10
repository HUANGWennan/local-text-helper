"""Bridge reviewed task data to the optional Microsoft Graph integration."""
import argparse
from datetime import date
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys

from extract_todo import extract


def reviewed_events(payload):
    events = payload.get("events")
    if not isinstance(events, list) or not 1 <= len(events) <= 8:
        raise ValueError("请选择 1–8 项待办。")
    reviewed = []
    for event in events:
        title = event.get("title")
        due = event.get("due_date", "")
        if not isinstance(title, str) or not 0 < len(title.strip()) <= 255:
            raise ValueError("任务标题须为 1–255 个字符。")
        try:
            valid_due = isinstance(due, str) and (not due or date.fromisoformat(due).isoformat() == due)
        except ValueError:
            valid_due = False
        if not valid_due:
            raise ValueError("截止日期请用 YYYY-MM-DD，或留空。")
        reviewed.append({"title": " ".join(title.split()), "due_date": due})
    return reviewed


def graph(events):
    locations = [shutil.which("pwsh"), "/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh"]
    executable = next((path for path in locations if path and Path(path).is_file()), None)
    if executable is None:
        raise ValueError("请先安装 PowerShell，再按 README 连接 Microsoft To Do。")
    support = Path.home() / "Library/Application Support/LocalTextHelperPublic"
    if not (support / "todo-connection.json").is_file():
        raise ValueError("尚未连接 Microsoft To Do。请按 README 完成一次登录。")
    with (support / "todo-write.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("另一次任务提交正在进行，请稍后再试。") from error
        # If the graph call times out, the PowerShell pending marker remains.
        result = subprocess.run(
            [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
             str(Path(__file__).with_name("graph_todo.ps1"))],
            input=json.dumps({"events": events}), capture_output=True, text=True, timeout=120,
        )
    for line in reversed(result.stdout.splitlines()):
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        if isinstance(payload, dict) and ("results" in payload or "error" in payload):
            return payload
    raise RuntimeError("Microsoft To Do 未返回确认。请核对已有任务后重试。")


def preview(events):
    lines = []
    for event in events:
        due = event["due_date"] or "无"
        lines.append(f'{event["title"]} · 截止日期：{due}')
        lines.extend(f'  需核对：{issue}' for issue in event["issues"])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["extract", "create"])
    mode = parser.parse_args().mode
    try:
        payload = json.load(sys.stdin)
        if mode == "extract":
            text = payload.get("text")
            if not isinstance(text, str):
                raise ValueError("请先选中待办相关文字。")
            result = extract(text)
            result["text"] = preview(result["events"])
        else:
            result = graph(reviewed_events(payload))
        print(json.dumps(result, ensure_ascii=False))
        return int("error" in result)
    except Exception as error:
        message = "Microsoft To Do 提交未返回确认，请先在 To Do 中核对。" if isinstance(error, subprocess.TimeoutExpired) else str(error)
        print(json.dumps({"error": message}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
