#!/usr/bin/env bash
# zju-ssh.sh — ZJU SSH 助手（macOS / Linux CLI v1.1）
# 子命令：init / doctor / up / down / connect <host> <port>（供 ProxyCommand 调用）
#         install-task / uninstall-task（开机自启：macOS=LaunchAgent，Linux=systemd --user）/ version
# 机制：SOCKS5 模式（无需 root）——zju-connect 监听 127.0.0.1:1080，
#       ssh 配置写入 ProxyCommand 指向本脚本 connect（校内直连 / 校外走隧道）。
# 依赖：curl、unzip、ssh、nc（openbsd 版，支持 -X 5；macOS 自带）、python3（可选，配置解析更稳）。
# TUN 模式（需要 root）见 README，本脚本默认 SOCKS。

set -u
TOOL_VERSION="1.3.4"
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$TOOL_DIR/bin"
CFG_LOCAL="$HOME/.config/zju-ssh/config.json"
SSH_CONFIG="$HOME/.ssh/config"
M_BEGIN="# >>> zju-ssh >>>"
M_END="# <<< zju-ssh <<<"
ZJ_HOST="rvpn.zju.edu.cn"
ZJ_PORT=443
SSH_HOST=""
SSH_PORT=22
ALIAS="zju"
PLIST="$HOME/Library/LaunchAgents/com.zju-ssh.tunnel.plist"
UNIT="$HOME/.config/systemd/user/zju-ssh-tunnel.service"

ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

# ---- 配置读取：优先 python3，退化到 grep ----
json_get() { # $1=字段名
  python3 - "$1" "$CFG_LOCAL" <<'PY' 2>/dev/null && return
import json, sys
try:
    v = json.load(open(sys.argv[2])).get(sys.argv[1], "")
    if v is not None: print(v)
except Exception:
    pass
PY
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CFG_LOCAL" 2>/dev/null | head -1 | sed 's/.*: *"//;s/"$//'
}

load_targets() {
  [ -f "$CFG_LOCAL" ] || return 0
  SSH_HOST=$(json_get sshHost); SSH_PORT=$(json_get sshPort); ALIAS=$(json_get hostAlias)
  [ -n "$SSH_HOST" ] || die "未配置工作站地址（先 init 填写）"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "" ;;
  esac
}

require_config() { [ -f "$CFG_LOCAL" ] || die "未初始化：先运行 $0 init"; }

cmd_init() {
  mkdir -p "$BIN" "$HOME/.config/zju-ssh" "$TOOL_DIR/logs" "$HOME/Library/LaunchAgents" "$HOME/.config/systemd/user"
  ARCH=$(detect_arch); [ -n "$ARCH" ] || die "无法识别架构"
  OS_TAG=$([ "$(uname)" = "Darwin" ] && echo "darwin" || echo "linux")
  if [ ! -x "$BIN/zju-connect" ]; then
    echo "[init] 下载 zju-connect $OS_TAG $ARCH ..."
    TAG=$(curl -fsSL --max-time 30 "https://api.github.com/repos/${ZJU_REPO:-Mythologyli/zju-connect}/releases/latest" |
          grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v/v/;s/"//')
    [ -n "$TAG" ] || die "无法获取最新版本号（网络？）；可手动下载放入 bin/"
    URL="https://github.com/Mythologyli/zju-connect/releases/download/$TAG/zju-connect-$OS_TAG-$ARCH.zip"
    curl -fL --max-time 600 -o /tmp/zjc.zip "$URL" || die "下载失败，可手动下载 $URL"
    unzip -oq /tmp/zjc.zip -d /tmp/zjc-extract
    find /tmp/zjc-extract -name 'zju-connect*' -type f -exec cp {} "$BIN/zju-connect" \;
    chmod +x "$BIN/zju-connect" && rm -rf /tmp/zjc-extract /tmp/zjc.zip
    ok "已下载 $TAG"
  else
    ok "zju-connect 已存在"
  fi
  printf '%s' "工作站地址（必填，工作站的内网 IP 或主机名）: "; read -r IN_SSH_HOST
  [ -n "$IN_SSH_HOST" ] || die "工作站地址不能为空"; SSH_HOST="$IN_SSH_HOST"
  printf '%s' "ssh 别名（回车=默认 zju）: "; read -r IN_ALIAS; ALIAS="${IN_ALIAS:-zju}"
  printf '%s' "工作站上的 SSH 账户名: "; read -r SSH_USER
  [ -n "$SSH_USER" ] || die "SSH 账户名不能为空"
  printf '%s' "本人上网账号（回车=跳过校外隧道）: "; read -r VPN_USER
  VPN_PASS=""
  if [ -n "$VPN_USER" ]; then printf '%s' "上网密码: "; read -r VPN_PASS; fi
  printf '{\n  "schemaVersion": 1,\n  "server": "%s",\n  "port": "%s",\n  "vpnUser": "%s",\n  "vpnPassword": "%s",\n  "sshHost": "%s",\n  "sshPort": "%s",\n  "hostAlias": "%s",\n  "sshUser": "%s"\n}\n' \
    "$ZJ_HOST" "$ZJ_PORT" "$VPN_USER" "$VPN_PASS" "$SSH_HOST" "$SSH_PORT" "$ALIAS" "$SSH_USER" > "$CFG_LOCAL"
  chmod 600 "$CFG_LOCAL"
  ok "配置已保存（明文，权限 600）: $CFG_LOCAL"
  # 写 ssh 配置（标记块幂等替换）
  touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
  awk -v b="$M_BEGIN" -v e="$M_END" 'index($0,b)==1{inb=1;next} inb&&index($0,e)==1{inb=0;next} inb==0{print}' \
    "$SSH_CONFIG" > "$SSH_CONFIG.tmp"
  { echo "$M_BEGIN"; echo "Host $ALIAS"; echo "    HostName $SSH_HOST"; echo "    Port $SSH_PORT"; echo "    User $SSH_USER"
    echo "    IdentityFile ~/.ssh/id_ed25519"
    echo "    ProxyCommand \"$TOOL_DIR/zju-ssh.sh\" connect %h %p"
    echo "    ServerAliveInterval 60"; echo "    ServerAliveCountMax 3"; echo "$M_END"; } >> "$SSH_CONFIG.tmp"
  mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  ok "已写入 $SSH_CONFIG"
  echo "接下来: ssh-keygen -t ed25519 -C \"名字@$ALIAS\"（若未有），公钥发给管理员；之后任何网络 ssh $ALIAS"
}

ensure_tunnel() {
  pgrep -f "$BIN/zju-connect" >/dev/null 2>&1 && return 0
  VPN_USER=$(json_get vpnUser); VPN_PASS=$(json_get vpnPassword)
  [ -n "$VPN_USER" ] || die "未配置上网账号（先 init）；若在校内请直接 ssh $ALIAS"
  [ -x "$BIN/zju-connect" ] || die "缺少 $BIN/zju-connect（先 init）"
  echo "[connect] 校外网络，启动隧道（10-30 秒）..."
  mkdir -p "$TOOL_DIR/logs"
  nohup "$BIN/zju-connect" -protocol atrust -server "$ZJ_HOST" -port "$ZJ_PORT" \
    -username "$VPN_USER" -password "$VPN_PASS" \
    -client-data-file "$BIN/client_data.json" > "$TOOL_DIR/logs/zju.log" 2>&1 &
  for _ in $(seq 1 30); do
    nc -z 127.0.0.1 1080 2>/dev/null && { echo "[connect] 隧道就绪"; return 0; }
    sleep 1
  done
  die "隧道启动超时，查看 $TOOL_DIR/logs/zju.log"
}

cmd_connect() { # ProxyCommand 入口：校内直连，校外走 SOCKS
  load_targets
  H="$1"; P="$2"
  if nc -z -w 1 "$H" "$P" 2>/dev/null; then exec nc "$H" "$P"; fi   # 校内直连
  ensure_tunnel
  exec nc -X 5 -x 127.0.0.1:1080 "$H" "$P"                          # 校外隧道
}

cmd_up()    { load_targets; ensure_tunnel; }
cmd_down()  { pkill -f "$BIN/zju-connect" 2>/dev/null && ok "已停止" || warn "未在运行"; }

cmd_doctor() {
  echo "=== zju-ssh doctor v$TOOL_VERSION ==="
  [ -f "$CFG_LOCAL" ] && ok "配置: $CFG_LOCAL" || warn "未初始化（先 init）"
  [ -x "$BIN/zju-connect" ] && ok "zju-connect 就绪" || warn "缺 zju-connect（先 init）"
  nc -z 127.0.0.1 1080 2>/dev/null && ok "SOCKS5 运行中" || warn "SOCKS5 未运行（校外时自动拉起）"
  load_targets 2>/dev/null || true
  if [ -n "$SSH_HOST" ]; then
    nc -z -w 2 "$SSH_HOST" "$SSH_PORT" 2>/dev/null && ok "直连 $SSH_HOST:$SSH_PORT（校内）" || warn "无直连 $SSH_HOST:$SSH_PORT（校外或断网）"
  else
    warn "未配置工作站地址（先 init）"
  fi
  grep -q "$M_BEGIN" "$SSH_CONFIG" 2>/dev/null && ok "ssh 配置块存在" || warn "ssh 配置块缺失（先 init）"
  command -v nc >/dev/null && ok "nc 可用" || warn "缺少 nc（connect 依赖）"
  echo "端到端自测: ssh $ALIAS \"whoami\""
}

# ---- 开机自启：macOS=LaunchAgent / Linux=systemd --user（均无需 root，SOCKS 模式）----
cmd_install_task() {
  require_config
  VPN_USER=$(json_get vpnUser); VPN_PASS=$(json_get vpnPassword)
  [ -n "$VPN_USER" ] || die "先 init 配置上网账号"
  if [ "$(uname)" = "Darwin" ]; then
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.zju-ssh.tunnel</string>
  <key>ProgramArguments</key><array>
    <string>$BIN/zju-connect</string>
    <string>-protocol</string><string>atrust</string>
    <string>-server</string><string>$ZJ_HOST</string>
    <string>-port</string><string>$ZJ_PORT</string>
    <string>-username</string><string>$VPN_USER</string>
    <string>-password</string><string>$VPN_PASS</string>
    <string>-client-data-file</string><string>$BIN/client_data.json</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
    chmod 600 "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null
    launchctl load "$PLIST" && ok "LaunchAgent 已加载（登录自动建立隧道）" || die "launchctl load 失败"
  else
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$UNIT" <<UNIT
[Unit]
Description=zju-ssh tunnel (zju-connect SOCKS)
[Service]
ExecStart=$BIN/zju-connect -protocol atrust -server $ZJ_HOST -port $ZJ_PORT -username $VPN_USER -password $VPN_PASS -client-data-file $BIN/client_data.json
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now zju-ssh-tunnel.service && ok "systemd 用户服务已启用" || die "systemctl 启用失败"
  fi
}

cmd_uninstall_task() {
  if [ "$(uname)" = "Darwin" ]; then
    launchctl unload "$PLIST" 2>/dev/null; rm -f "$PLIST"; ok "LaunchAgent 已移除"
  else
    systemctl --user disable --now zju-ssh-tunnel.service 2>/dev/null; rm -f "$UNIT"; ok "systemd 服务已移除"
  fi
}

cmd_version() { echo "zju-ssh.sh v$TOOL_VERSION"; }

case "${1:-doctor}" in
  init)            cmd_init ;;
  doctor)          cmd_doctor ;;
  up)              load_targets; ensure_tunnel ;;
  down)            cmd_down ;;
  connect)         [ $# -ge 3 ] || die "connect 需要 <host> <port>"; shift; cmd_connect "$@" ;;
  install-task)    cmd_install_task ;;
  uninstall-task)  cmd_uninstall_task ;;
  version)         cmd_version ;;
  *) echo "用法: zju-ssh.sh init|doctor|up|down|connect <host> <port>|install-task|uninstall-task|version"; exit 2 ;;
esac
