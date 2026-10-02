#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本仓库的回环测试执行器（模拟 nc 监听端）。

用法示例:
  python3 tests/harness.py --name nim-linux \
      --cmd "./dist/reverse-linux-nim 127.0.0.1 {PORT}" --tty --interrupt

检查项:
  connect    受控端能在超时内连上来（默认必查）
  exec       命令执行正常（unix: echo RS_MARKER_$((40+2))；windows: set /a 40+2）
  tty        （--tty）shell 拿到真 PTY（tty 输出 /dev/pts/N）
  interrupt  （--interrupt）Ctrl-C 能打断前台命令，证明 PTY 信号链路正常
  reconnect  （--reconnect）杀掉第一条连接后能自动重连，且第 2 次会话可用

退出码 0 = 全部通过；1 = 有失败项。
"""

import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import time

ARTIFACTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts")


class Check:
    def __init__(self, name):
        self.name = name
        self.passed = False
        self.detail = ""


def recv_until(sock, patterns, timeout):
    """读 socket 直到任一 bytes pattern 命中或超时；返回 (data, matched)。"""
    deadline = time.time() + timeout
    data = b""
    while time.time() < deadline:
        remain = max(0.1, deadline - time.time())
        sock.settimeout(remain)
        try:
            chunk = sock.recv(8192)
        except socket.timeout:
            break
        except OSError:
            break
        if not chunk:
            break
        data += chunk
        for p in patterns:
            if re.search(p, data):
                return data, True
    return data, False


def drain(sock, timeout):
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        sock.settimeout(max(0.1, deadline - time.time()))
        try:
            chunk = sock.recv(8192)
        except socket.timeout:
            break
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--cmd", required=True, help="payload 启动命令，{PORT}/{HOST} 会被替换")
    ap.add_argument("--host", default="127.0.0.1", help="替换 {HOST} 的值（受控端要连的地址）")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--crlf", action="store_true", help="windows 受控端：命令用 \\r\\n 结尾")
    ap.add_argument("--tty", action="store_true")
    ap.add_argument("--interrupt", action="store_true")
    ap.add_argument("--interrupt-cmd", default="sleep 30",
                    help="interrupt 检查用的长命令（windows 用 ping -n 30 127.0.0.1）")
    ap.add_argument("--reconnect", action="store_true")
    ap.add_argument("--banner", default=None, help="期望的开场输出正则")
    ap.add_argument("--sessions", type=int, default=None, help="RS_SESSIONS 值")
    ap.add_argument("--interval", default="1", help="RS_INTERVAL 值（测试里默认 1 秒）")
    ap.add_argument("--accept-timeout", type=float, default=25.0)
    ap.add_argument("--exec-timeout", type=float, default=12.0)
    ap.add_argument("--banner-timeout", type=float, default=5.0)
    ap.add_argument("--env", action="append", default=[], help="额外环境变量 K=V，可多次")
    ap.add_argument("--killcmd", default=None, help="收尾时执行的清理命令（如 taskkill）")
    ap.add_argument("--shell", default="/bin/bash", help="用什么解释执行 --cmd")
    args = ap.parse_args()

    os.makedirs(ARTIFACTS, exist_ok=True)
    stderr_path = os.path.join(ARTIFACTS, f"{args.name}.stderr.log")
    stderr_file = open(stderr_path, "wb")

    checks = [Check("connect"), Check("exec")]
    if args.tty:
        checks.append(Check("tty"))
    if args.interrupt:
        checks.append(Check("interrupt"))
    if args.reconnect:
        checks.append(Check("reconnect"))

    # 监听
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.bind, 0))
    listener.listen(4)
    port = listener.getsockname()[1]

    sessions = args.sessions
    if sessions is None:
        sessions = 2 if args.reconnect else 1

    cmd = args.cmd.replace("{PORT}", str(port)).replace("{HOST}", args.host)
    env = dict(os.environ)
    env["RS_INTERVAL"] = args.interval
    env["RS_SESSIONS"] = str(sessions)
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v

    proc = subprocess.Popen(
        [args.shell, "-c", cmd],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=stderr_file,
        start_new_session=True,
    )

    def fail_all_remaining(reason):
        for c in checks:
            if not c.passed and not c.detail:
                c.detail = reason

    try:
        # ---------- connect ----------
        listener.settimeout(args.accept_timeout)
        try:
            conn, _ = listener.accept()
        except socket.timeout:
            checks[0].detail = f"{args.accept_timeout}s 内没有连接（查看 {stderr_path}）"
            return report(checks)
        checks[0].passed = True
        checks[0].detail = f"port {port}"

        # ---------- banner（可选） ----------
        if args.banner:
            data, ok = recv_until(conn, [args.banner.encode()], args.banner_timeout)
            if not ok:
                fail_all_remaining(f"未匹配 banner /{args.banner}/: {data[:200]!r}")

        # ---------- exec ----------
        if args.crlf:
            marker_cmd = b"set /a 40+2\r\n"
            marker_pat = re.compile(rb"(?m)^\s*42\s*$")
        else:
            marker_cmd = b"echo RS_MARKER_$((40+2))\n"
            marker_pat = re.compile(rb"RS_MARKER_42")
        conn.sendall(marker_cmd)
        deadline = time.time() + args.exec_timeout
        data = b""
        ok = False
        while time.time() < deadline:
            conn.settimeout(max(0.1, deadline - time.time()))
            try:
                chunk = conn.recv(8192)
            except socket.timeout:
                break
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            if marker_pat.search(data):
                ok = True
                break
        checks[1].passed = ok
        checks[1].detail = "" if ok else f"未看到标记输出: {data[:300]!r}"

        # ---------- tty ----------
        if args.tty and not checks[1].detail:
            conn.sendall(b"tty\n")
            data, _ = recv_until(conn, [rb"/dev/pts/\d+"], 5.0)
            ok = re.search(rb"/dev/pts/\d+", data) is not None
            checks[2].passed = ok
            checks[2].detail = "" if ok else f"tty 输出不是 pts: {data[:200]!r}"

        # ---------- interrupt ----------
        if args.interrupt and checks[1].passed:
            ci = checks[2] if not args.tty else checks[3]
            eol = b"\r\n" if args.crlf else b"\n"
            conn.sendall(args.interrupt_cmd.encode() + eol)
            time.sleep(1.0)
            drain(conn, 0.3)
            conn.sendall(b"\x03")  # Ctrl-C
            time.sleep(0.5)
            conn.sendall(marker_cmd)   # 中断后还能继续执行才算通过
            data, ok = recv_until(conn, [marker_pat], 8.0)
            ci.passed = ok
            ci.detail = "" if ok else f"Ctrl-C 后无法继续执行: {data[:200]!r}"

        # ---------- reconnect ----------
        if args.reconnect and checks[1].passed:
            cr = [c for c in checks if c.name == "reconnect"][0]
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
            listener.settimeout(args.accept_timeout)
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                cr.detail = "断开后没有重连"
                return report(checks)
            conn.sendall(marker_cmd)
            data, ok = recv_until(conn, [marker_pat], args.exec_timeout)
            cr.passed = ok
            cr.detail = "" if ok else f"重连后会话不可用: {data[:200]!r}"

        # ---------- 收尾 ----------
        try:
            conn.sendall(b"exit\r\n" if args.crlf else b"exit\n")
        except OSError:
            pass
        time.sleep(0.5)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            pass
        try:
            conn.close()
        except OSError:
            pass
        return report(checks)

    finally:
        # 清场：payload 进程组 + 外部清理命令
        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if args.killcmd:
            subprocess.run(["/bin/bash", "-c", args.killcmd],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        listener.close()
        stderr_file.close()


def report(checks):
    failed = 0
    for c in checks:
        if c.passed:
            print(f"[PASS] {c.name} {c.detail}")
        else:
            failed += 1
            print(f"[FAIL] {c.name} {c.detail or '未执行'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
