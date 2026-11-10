"""On-demand local Ollama, with a five-minute reusable cache and owned idle shutdown."""
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.request

SUPPORT = Path.home() / 'Library/Application Support/LocalTextHelperPublic'
STATE = SUPPORT / 'model-server.json'
LEASE = SUPPORT / 'model-server-lease'
LOCK = SUPPORT / 'model-request.lock'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))



def ready(base):
    try:
        with HTTP.open(base + '/api/version', timeout=0.4) as response:
            return response.status == 200
    except Exception:
        return False


def cached_server():
    try:
        state = json.loads(STATE.read_text())
        base = state['base']
        port = int(base.removeprefix('http://127.0.0.1:'))
        if base == f'http://127.0.0.1:{port}' and 0 < port < 65536 and ready(base):
            return base
    except Exception:
        pass
    return None


def stop_owned(server):
    try:
        os.killpg(server.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(server.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        server.wait(timeout=5)


def worker(port, idle_seconds):
    binary = next((p for p in ['/Applications/Ollama.app/Contents/Resources/ollama', '/usr/local/bin/ollama'] if Path(p).is_file()), None)
    if binary is None:
        return
    server = subprocess.Popen([binary, 'serve'], env=dict(os.environ, OLLAMA_HOST=f'127.0.0.1:{port}', OLLAMA_KEEP_ALIVE='5m'),
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    base = f'http://127.0.0.1:{port}'
    try:
        deadline = time.monotonic() + 20
        while not ready(base):
            if server.poll() is not None or time.monotonic() >= deadline:
                return
            time.sleep(0.15)
        temporary = STATE.with_suffix(f'.{os.getpid()}.tmp')
        temporary.write_text(json.dumps({'base': base, 'worker_pid': os.getpid()}))
        temporary.replace(STATE)
        while server.poll() is None:
            time.sleep(min(5, idle_seconds))
            with LOCK.open('a') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue  # A model request is in progress; never interrupt it.
                if time.time() - LEASE.stat().st_mtime >= idle_seconds:
                    # Keep the lock through teardown so the next request cannot reuse a dying server.
                    stop_owned(server)
                    return
    finally:
        stop_owned(server)
        with LOCK.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                if json.loads(STATE.read_text()).get('worker_pid') == os.getpid():
                    STATE.unlink()
            except (OSError, ValueError):
                pass


def chat(payload, timeout=150, _force_private=False, _idle_seconds=300):
    SUPPORT.mkdir(parents=True, exist_ok=True)
    with LOCK.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        base = cached_server()
        private = base is not None
        if base is None and not _force_private and ready('http://127.0.0.1:11434'):
            base = 'http://127.0.0.1:11434'
        if base is None:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            LEASE.touch()
            runner = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--worker', str(port), str(_idle_seconds)],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 22
            while not (base := cached_server()):
                if runner.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Ollama 自动启动失败，请打开 Ollama 后重试。')
                time.sleep(0.15)
            private = True
        if private:
            LEASE.touch()
        try:
            request = urllib.request.Request(base + '/api/chat', data=json.dumps(dict(payload, keep_alive='5m')).encode(),
                                             headers={'Content-Type': 'application/json'})
            with HTTP.open(request, timeout=timeout) as response:
                return json.load(response)
        finally:
            if private:
                LEASE.touch()  # Five minutes begins after completion, not at request start.


if __name__ == '__main__' and len(sys.argv) == 4 and sys.argv[1] == '--worker':
    worker(int(sys.argv[2]), float(sys.argv[3]))
