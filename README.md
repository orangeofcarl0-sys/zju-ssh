# zju-ssh

> v1.5.1 · [MIT License](LICENSE) · Windows GUI+CLI / macOS+Linux CLI

**ZJU SSH 助手** —— 让"任何网络下 `ssh 浙大校园网工作站`"变成一条零配置的命令。
**整个工具围绕 [zju-connect](https://github.com/Mythologyli/zju-connect)（aTrust 协议开源客户端）构建，专为浙江大学校园网打造**：
默认面向 ZJU 的 aTrust/RVPN 通道（rvpn.zju.edu.cn），校外经隧道、校内直连，Windows 提供 GUI + CLI，macOS/Linux 提供 CLI。

> 英文简介：zju-ssh is a portable helper built around [zju-connect](https://github.com/Mythologyli/zju-connect) that makes `ssh <your-zju-workstation>` work identically on and off the ZJU campus network.
> It manages an aTrust tunnel (via zju-connect, SOCKS5 or TUN mode) and generates the matching SSH config for you.

## 它解决什么问题

校园工作站通常只有内网地址：校内能直连，校外必须先拨 VPN（aTrust/RVPN），而且 VPN 客户端对 SSH 这类协议不透明。本工具把这套流程压缩成"配置一次，走天下"：

- 校内：`ssh zju` 直连；
- 校外：还是 `ssh zju`——工具自动建立隧道（SOCKS5 模式按需拉起，TUN 模式开机常驻）， ssh 配置**永不改动**；
- 换网络、换热点、断线重连，都不需要碰任何配置。

## 特性

- **双模式**：TUN（虚拟网卡接管校园网路由，所有客户端通吃）/ SOCKS5（免管理员，智能垫片按需转发）
- **图形界面**（Windows）：状态实时探测、一键连接、配置表单、关闭窗口最小化到托盘常驻（托盘双击唤回、右键退出）、一键复制诊断信息
- **服务端连接日志**（可选部署在工作站上）：每次 SSH 连接的用户/来源/认证方式/时长入档
- **macOS/Linux CLI**：与 Windows 同源的完整命令行（含开机自启）
- 零依赖：Windows 使用系统自带 OpenSSH、csc、WPF；下载 zju-connect 后即用（TUN 模式首次连接会自动补装 `wintun.dll` 驱动）

## 下载安装（Releases 分发）

普通用户不需要 clone 仓库——到 [Releases](https://github.com/orangeofcarl0-sys/zju-ssh/releases) 页下载对应平台的 zip 即可：

| 文件 | 平台 | 内容 |
|---|---|---|
| `zju-ssh-vX.Y.Z-windows.zip` | Windows | GUI + CLI + 连接日志 monitor |
| `zju-ssh-vX.Y.Z-macos.zip` | macOS / Linux | CLI（zju-ssh.sh） |

下载后建议校验完整性（哈希见 release 资产 `SHA256SUMS.txt`）：

```powershell
# Windows
certutil -hashfile zju-ssh-v1.3.0-windows.zip SHA256
```
```bash
# macOS / Linux（与 SHA256SUMS.txt 对照，或 shasum -a 256 -c SHA256SUMS.txt）
shasum -a 256 zju-ssh-v1.3.0-macos.zip
```

标有 *Pre-release* 的版本供组内试用，验证通过后由维护者转正（Latest）。

## 快速开始（Windows）

### 前提

工作站管理员已为你开通账户并告知账户名；你与工作站都能访问互联网。

1. 解压本仓库到任意目录（建议避开含中文的路径）；
2. 双击 **`Start-GUI.bat`**，填写：
   - 工作站上的 SSH 账户名（管理员告知）
   - 工作站地址（如 192.0.2.10，管理员告知；本工具无默认地址，必须逐字填写）
   - 上网账号/密码（校外隧道用；只在校内用可留空）
3. 点 **生成/复制我的公钥**，把剪贴板里的公钥发给工作站管理员；
4. 管理员开通后：任何网络下 `ssh zju`（别名默认 `zju`，可在高级设置中修改）。

首次校外连接会自动下载 zju-connect 并建立隧道（10–30 秒）；`自检` 按钮随时一键诊断，结果自动复制方便求助。

### 命令行方式

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File zju-ssh.ps1 init
zju-ssh.ps1 doctor      # 自检
zju-ssh.ps1 up / down   # 手动启停隧道
```

### macOS / Linux

```bash
./zju-ssh.sh init            # 询问账户、工作站地址、上网账号，写入 ssh 配置
./zju-ssh.sh install-task    # 开机自动建立隧道（macOS=LaunchAgent / Linux=systemd --user，均无需 root）
./zju-ssh.sh doctor
ssh zju
```

## 工作站侧：连接日志（可选）

在工作站上以管理员运行 `monitor/ssh-log.ps1 install-watcher`，即注册一个 SYSTEM 自启任务：
每次 SSH 连接（用户/来源 IP/认证方式/时长）实时归档到 `C:\ProgramData\zju-ssh\connections.csv`，
并提供 `view / csv / active / ip-status` 等查询命令。`Auth=password` 的行在全面密钥认证后应绝迹——
它是配置是否被改动的哨兵。

## 配置项

| 字段 | 默认值 | 说明 |
|---|---|---|
| sshHost | —（必填） | 工作站地址（init 询问 / GUI 设置页填写） |
| sshPort | 22 | 工作站 SSH 端口 |
| hostAlias | zju | ssh 配置里的 Host 别名 |
| server / zjuPort | rvpn.zju.edu.cn / 443 | aTrust/RVPN 服务器（按学校修改） |
| zjuRepo | Mythologyli/zju-connect | 隧道内核的下载与版本检查仓库 |
| zjuChannel | nightly | 内核通道：nightly=上游持续构建，含 aTrust 二次认证（RADIUS 质询）等最新修复；stable=正式 release |
| mode | tun | tun / socks |
| sshUser / vpnUser / vpnPassword | — | 账户与凭据（密码 DPAPI 加密存储） |

**二次认证（图形码 / 动态口令 / 短信验证码）**：学校 aTrust 常要求两步认证，工具会自动引导：
1. **图形验证码**：内核会启动本地验证码网页并自动打开浏览器，界面同时显示「打开验证码网页」按钮与地址；按网页提示点选图片字符并提交。
2. **短信/令牌验证码**：通过后学校发短信到你的手机，界面会展开「验证码」输入框（内核提示同步显示在实时日志里），填入后点「提交验证码」（或按回车）。

命令行等价操作：`zju-ssh.ps1 code <验证码>`。认证期间 `up` 会保持等待（不按 90 秒表催），内核自身的图形码超时为 5 分钟。

CLI 通过 `init -SshHost -SshPort -HostAlias -Server -ZjuPort -ZjuRepo` 传参；旧配置缺字段自动回落默认值。

## 工作原理

```
校内：ssh ──直连──> 工作站:22
校外：
  TUN   模式：zju-connect 虚拟网卡接管校园网路由，操作系统把发往校园网的包送进隧道，所有程序无感知
  SOCKS 模式：ssh ─> sshpipe 垫片 ─> zju-connect(127.0.0.1:1080) ─> RVPN 隧道 ─> 工作站:22
```

- **TUN**：配置即纯 `Host` 块，无 ProxyCommand，所有客户端（Windows OpenSSH / Git Bash / VS Code / WinSCP）通吃；
- **SOCKS**：免管理员；`sshpipe` 垫片先试直连（校内 800ms 内成功、近零开销），失败才走隧道。

## 兼容性与已知限制

- **Windows 自带 ssh.exe 的 ProxyCommand 存在断流问题**（首包后数据不再送达代理 stdin，实测记录）：SOCKS 模式请使用 Git Bash 的 ssh 或 VS Code 指定 Git ssh；TUN 模式不受影响；
- 内核下载（Windows 与 macOS/Linux 同源）走 GitHub releases 直链 + 国内镜像回退，不查 API，避免共享出口 IP 的配额限制；`doctor` 对 nightly 通道比对资产日期提示更新；
- macOS/Linux 的 `connect` 依赖 openbsd 版 `nc -X 5`；
- 脚本为 UTF-8（带 BOM），用 PowerShell 5.1+ 运行；改动后请跑 `smoke-test.ps1` 并用 `tools/norm-bom.ps1` 规范 BOM；
- zju-connect 依赖学校 aTrust 协议现状，协议变更时回退学校官方客户端即可（校内直连路径不受影响）。

## 安全说明

- 上网密码使用 Windows DPAPI 加密存储（当前用户+本机可解），配置文件建议勿外传；
- SSH 登录推荐全面密钥认证：工作站侧禁用密码认证后，`Auth=password` 日志行应绝迹（monitor 可监控）；
- 请使用本人上网账号，勿共用（aTrust 有设备数限制且多数学校禁止共用）；
- 本工具仅用于访问自有/授权设备，请遵守所在学校的网络使用规范。

## 开发

```
zju-common.psm1   共享库（TCP 探测/连接状态/配置 DPAPI/统一输出/认证挑战识别）
zju-ssh.ps1       CLI（init/up/down/doctor/connect/code/install-task/uninstall-task）
zju-ssh-gui.ps1   WPF 图形界面（深色卡片式）
zju-runner.ps1    隧道监督进程（持有内核 stdin，转发二次认证口令）
zju-ssh.sh        macOS/Linux CLI v1.1（LaunchAgent/systemd 自启）
sshpipe.cs           SOCKS 智能垫片源码（init 时以系统自带 csc 编译）
monitor/ssh-log.ps1  工作站连接日志（含 IP 漂移巡检）
smoke-test.ps1       冒烟回归（改动后必跑）
tools/norm-bom.ps1   脚本 BOM 规范化
release/             发布三道门（release-gate.ps1）与打包（package.ps1）
RELEASE.md           发布流程：质量门 / 隐私门 / 监测门与 GitHub prerelease 步骤
.github/workflows/   CI 监测门：push/PR 自动复跑 release-gate；打 tag 自动出 prerelease
```

## 致谢

- [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect) —— aTrust 协议隧道内核
- [ZJU-Connect-for-Windows](https://github.com/Mythologyli/ZJU-Connect-for-Windows) —— 交互设计参考
- [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev) / [WireGuard](https://www.wireguard.com/) —— 界面与状态设计参考

## License

[MIT](LICENSE)
