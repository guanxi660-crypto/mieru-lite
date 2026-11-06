#!/bin/bash
#=============================================================================
# mieru-lite —— mieru (mita) 服务端一键管理脚本
# 交互风格与 mihomo-lite / singbox-lite 一致
#
# 特点：
#   - 不需要域名、不需要 TLS 证书、不需要 Argo 隧道，一个端口就是全部
#   - 无 TLS 指纹：随机 padding + 重放攻击检测，抗主动探测
#   - 多用户共用一个服务端，每个用户一条独立链接与独立配额
#   - 支持 TCP / UDP / TCP+UDP 同号绑定
# 支持: Debian/Ubuntu(systemd) / Alpine(OpenRC) / 无 init 直跑模式
# 需 root 权限运行
#=============================================================================
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_VERSION="1.2.2"
APP_DIR="/etc/mieru-lite"
CONFIG_JSON="${APP_DIR}/server.json"
METADATA_FILE="${APP_DIR}/metadata.json"
SUB_DIR="${APP_DIR}/sub"
RUNTIME_DIR="/run/mieru-lite"
UDS_PATH="${RUNTIME_DIR}/mita.sock"
MITA_BIN="/usr/local/bin/mita"
# 端口跳跃: 服务端要为段内每个端口各开一个监听, 实测约 11-14KB 内存/端口, fd 也是一口一个
MAX_HOP_PORTS="${MAX_HOP_PORTS:-2000}"
SERVICE_NAME="mieru-lite"
CORE_LOG="/var/log/mieru-core.log"
GITHUB_RAW_URL="https://raw.githubusercontent.com/guanxi660-crypto/mieru-lite/main/mieru-lite.sh"
SELF_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
# 内核版本固定, 避免上游改动打乱字段; 想要最新版用 MIERU_VERSION=latest mr
MIERU_VERSION="${MIERU_VERSION:-v3.39.0}"

# mita 的 CLI 和守护进程必须说同一种"方言"：同一份配置文件、同一个 socket
export MITA_CONFIG_JSON_FILE="$CONFIG_JSON"
export MITA_UDS_PATH="$UDS_PATH"
export MITA_INSECURE_UDS=1

# ---------------- 基础输出 ----------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_info()    { echo -e "${CYAN}[信息] $1${NC}"; }
_success() { echo -e "${GREEN}[成功] $1${NC}"; }
_warn()    { echo -e "${YELLOW}[注意] $1${NC}"; }
_error()   { echo -e "${RED}[错误] $1${NC}" >&2; }

_check_root() {
  [[ $EUID -ne 0 ]] && { _error "此脚本必须以 root 权限运行。"; exit 1; }
}

# ---------------- 依赖 ----------------
_install_dependencies() {
  local missing="" c
  for c in curl jq ss ip pgrep shuf timeout tee; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -d /etc/ssl/certs ] || missing="$missing ca-certificates"
  [ -z "$missing" ] && return 0
  _info "检测到缺少必要组件:$missing，正在安装..."
  if command -v apt >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y --no-install-recommends curl jq iproute2 procps coreutils ca-certificates >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl jq iproute2 procps coreutils ca-certificates 2>/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq iproute procps-ng coreutils ca-certificates >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq iproute procps-ng coreutils ca-certificates >/dev/null 2>&1
  else
    _error "无法识别的包管理器，请手动安装:$missing"; return 1
  fi
  missing=""
  for c in curl jq ss ip pgrep shuf timeout tee; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    _error "组件安装后仍缺失:$missing，请手动安装后重试。"; return 1
  fi
  _success "必要组件就绪。"
}

# ---------------- 工具 ----------------
_gen_uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; }
_gen_hex()     { openssl rand -hex "$1" 2>/dev/null || (head -c "$(( $1 * 2 ))" /dev/urandom | od -An -tx1 | tr -d ' \n'); }
_url_encode()  { printf '%s' "$1" | jq -sRr @uri; }
_clean_input() { printf '%s' "${1%$'\r'}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

_is_ipv4() { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
_is_ipv6() { printf '%s' "$1" | grep -qE '^[0-9a-fA-F:]+:[0-9a-fA-F:]*$'; }

# 注意: 有些机器/器(或走了代理/NAT64)对 curl -4 会返回一个 IPv6 地址,
# 或者 -6 返回 IPv4。所以拿到结果必须按格式校验, 不能信 -4/-6 参数。
_get_ip4() {
  local ip u
  for u in https://icanhazip.com https://ipinfo.io/ip https://api.ipify.org; do
    ip=$(timeout 5 curl -4fsS --max-time 4 "$u" 2>/dev/null)
    ip="${ip//[$'\r\n ']/}"
    _is_ipv4 "$ip" && { printf '%s' "$ip"; return; }
  done
  printf ''
}

_get_ip6() {
  local ip u
  for u in https://icanhazip.com https://ipinfo.io/ip https://api64.ipify.org; do
    ip=$(timeout 5 curl -6fsS --max-time 4 "$u" 2>/dev/null)
    ip="${ip//[$'\r\n ']/}"
    _is_ipv6 "$ip" && { printf '%s' "$ip"; return; }
  done
  # -6 失败时退一步: 直接取任意出口地址, 只要它确实是 IPv6
  ip=$(timeout 5 curl -fsS --max-time 4 https://api64.ipify.org 2>/dev/null)
  ip="${ip//[$'\r\n ']/}"
  if _is_ipv6 "$ip" && ! _is_ipv4 "$ip"; then printf '%s' "$ip"; return; fi
  printf ''
}

# 按 metadata 的 ip_ver 解析链接用地址; 该栈不可用时回退另一栈
_resolve_node_ip() {
  local ver="$1" v4 v6
  case "$ver" in
    v6)
      v6=$(_get_ip6)
      if [ -n "$v6" ]; then printf '%s' "$v6"; return; fi
      _warn "服务端指定了 IPv6，但未探测到可用 IPv6，已回退 IPv4。" >&2
      _get_ip4
      ;;
    *)
      v4=$(_get_ip4)
      if [ -n "$v4" ]; then printf '%s' "$v4"; return; fi
      _get_ip6
      ;;
  esac
}

# 链接里的 IPv6 必须加方括号
_link_host() {
  local ip="$1"
  case "$ip" in
    *:*) printf '[%s]' "$ip" ;;
    *)   printf '%s' "$ip" ;;
  esac
}

_ask_ip_ver() {
  local v4 v6 iv
  v4=$(_get_ip4); v6=$(_get_ip6)
  if [ -n "$v4" ] && [ -n "$v6" ]; then
    echo "本机双栈可用: IPv4=${v4}  IPv6=${v6}"
    read -rp "对外 IP 版本 (4/6) [4]: " iv || iv=""
    iv=$(_clean_input "$iv")
    case "$iv" in
      6|v6|V6) IP_VER="v6" ;;
      4|v4|V4|"") IP_VER="v4" ;;
      *) _warn "输入 '${iv}' 无法识别，按 IPv4 处理。"; IP_VER="v4" ;;
    esac
  elif [ -n "$v6" ]; then
    IP_VER="v6"; _info "检测到仅 IPv6，服务端使用 IPv6 地址。"
  else
    IP_VER="v4"
  fi
  _info "对外 IP 版本: ${IP_VER}"
}

_detect_arch() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7)  ARCH="armv7" ;;
    riscv64)       ARCH="riscv64" ;;
    *) _error "不支持的架构: $m"; return 1 ;;
  esac
}

_detect_init_system() {
  if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  else
    INIT_SYSTEM="direct"
  fi
}

# 默认 mihomo 节点前缀: 国家-运营商（ip-api.com 单次请求，缓存 24h）
_geo_name() {
  local cc="" isp="" ts now raw
  now=$(date +%s)
  if [ -s "$METADATA_FILE" ]; then
    ts=$(jq -r '.geo.ts // 0' "$METADATA_FILE" 2>/dev/null)
    if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null && [ $((now - ts)) -lt 86400 ]; then
      cc=$(jq -r '.geo.cc // ""' "$METADATA_FILE" 2>/dev/null)
      isp=$(jq -r '.geo.isp // ""' "$METADATA_FILE" 2>/dev/null)
    fi
  fi
  if [ -z "$cc" ] || [ -z "$isp" ]; then
    raw=$(timeout 6 curl -fsS --max-time 5 "http://ip-api.com/json/?fields=status,countryCode,org" 2>/dev/null)
    if [ -n "$raw" ]; then
      cc=$(printf '%s' "$raw" | jq -r '.countryCode // ""' 2>/dev/null)
      isp=$(printf '%s' "$raw" | jq -r '.org // ""' 2>/dev/null)
    fi
    [ -z "$cc" ] && cc="XX"
    [ -z "$isp" ] && isp="ISP"
    if [ -s "$METADATA_FILE" ]; then
      local tmp; tmp=$(mktemp)
      jq --arg cc "$cc" --arg isp "$isp" --argjson ts "$now" \
         '.geo = {cc:$cc, isp:$isp, ts:$ts}' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
    fi
  fi
  [ -z "$cc" ] && cc="XX"
  if [ -z "$isp" ]; then
    isp="ISP"
  else
    isp="${isp%%(*}"                                                   # 砍掉括号补充说明
    isp="${isp%% *}"                                                   # 空格后截断: 只保留第一个词
    isp=$(printf '%s' "$isp" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    # 按字符(非字节)截断到 16，避免把中文运营商名切半产生非法 UTF-8
    local cut
    cut=$(printf '%s' "$isp" | jq -Rr '.[0:16]' 2>/dev/null)
    [ -n "$cut" ] && isp="$cut"
    [ -z "$isp" ] && isp="ISP"
  fi
  # 节点名: CC.ISP.Mieru（传输层由 _build_clash_yaml 按 .TCP/.UDP 追加）
  printf '%s.%s.Mieru' "$cc" "$isp"
}

# ---------------- 网络下载 ----------------
_fetch() { curl -LfsS --connect-timeout 15 --max-time 300 -o "$2" "$1"; }

_fetch_gh() {
  local url="$1" out="$2" mirror="${GH_PROXY:-}"
  rm -f "$out"
  if [ -n "$mirror" ]; then
    _fetch "${mirror%/}/${url}" "$out" && return 0
  fi
  _fetch "$url" "$out" && return 0
  _fetch "https://gh-proxy.com/${url}" "$out" && return 0
  _fetch "https://ghfast.top/${url}" "$out" && return 0
  return 1
}

# ---------------- 服务管理 ----------------
_create_service() {
  case "$INIT_SYSTEM" in
    systemd)
      cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=mieru-lite server (mita)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
Environment=MITA_CONFIG_JSON_FILE=${CONFIG_JSON}
Environment=MITA_UDS_PATH=${UDS_PATH}
Environment=MITA_INSECURE_UDS=1
Environment=MITA_LOG_NO_TIMESTAMP=1
RuntimeDirectory=mieru-lite
RuntimeDirectoryMode=0755
ExecStart=${MITA_BIN} run
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
      ;;
    openrc)
      cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="mieru-lite server"
command="${MITA_BIN}"
command_args="run"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
output_log="${CORE_LOG}"
error_log="${CORE_LOG}"
export MITA_CONFIG_JSON_FILE="${CONFIG_JSON}"
export MITA_UDS_PATH="${UDS_PATH}"
export MITA_INSECURE_UDS=1
export MITA_LOG_NO_TIMESTAMP=1
depend() { need net; }
EOF
      chmod +x "/etc/init.d/${SERVICE_NAME}"
      rc-update add ${SERVICE_NAME} default >/dev/null 2>&1
      ;;
    direct)
      mkdir -p "$RUNTIME_DIR"
      cat > "${APP_DIR}/run-core.sh" <<EOF
#!/bin/bash
export MITA_CONFIG_JSON_FILE="${CONFIG_JSON}"
export MITA_UDS_PATH="${UDS_PATH}"
export MITA_INSECURE_UDS=1
export MITA_LOG_NO_TIMESTAMP=1
exec ${MITA_BIN} run >> "${CORE_LOG}" 2>&1
EOF
      chmod +x "${APP_DIR}/run-core.sh"
      ;;
  esac
}

_service_active() {
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet ${SERVICE_NAME} ;;
    openrc)  rc-service ${SERVICE_NAME} status >/dev/null 2>&1 ;;
    direct)  [ -f "${RUNTIME_DIR}/core.pid" ] && kill -0 "$(cat "${RUNTIME_DIR}/core.pid")" 2>/dev/null ;;
  esac
}

_start_service() {
  case "$INIT_SYSTEM" in
    systemd) systemctl start ${SERVICE_NAME} ;;
    openrc)  rc-service ${SERVICE_NAME} start ;;
    direct)
      mkdir -p "$RUNTIME_DIR"
      _service_active && return 0
      nohup "${APP_DIR}/run-core.sh" >/dev/null 2>&1 &
      echo $! > "${RUNTIME_DIR}/core.pid"
      ;;
  esac
}

_stop_service() {
  case "$INIT_SYSTEM" in
    systemd) systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 ;;
    openrc)  rc-service ${SERVICE_NAME} stop >/dev/null 2>&1 ;;
    direct)
      if [ -f "${RUNTIME_DIR}/core.pid" ]; then
        kill "$(cat "${RUNTIME_DIR}/core.pid")" 2>/dev/null
        rm -f "${RUNTIME_DIR}/core.pid"
      fi
      pkill -f "${MITA_BIN} run" 2>/dev/null
      ;;
  esac
}

_restart_service() {
  case "$INIT_SYSTEM" in
    systemd) systemctl restart ${SERVICE_NAME} ;;
    openrc)  rc-service ${SERVICE_NAME} restart ;;
    direct)  _stop_service; sleep 1; _start_service ;;
  esac
}

# 等端口真正开始监听, 避免"重启成功但还没起来"的假象
_wait_listen() {
  local port="$1" i
  for i in $(seq 1 30); do
    ss -lnt 2>/dev/null | grep -q ":${port} " && return 0
    sleep 0.3
  done
  return 1
}

# ---------------- 内核安装 ----------------
_resolve_version() {
  local v="${MIERU_VERSION}"
  if [ "$v" = "latest" ]; then
    v=$(timeout 8 curl -fsS --max-time 8 https://api.github.com/repos/enfein/mieru/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null)
    [ -z "$v" ] && { _error "查询最新版本失败，回退到默认 ${MIERU_VERSION}。"; v="v3.39.0"; }
  fi
  printf '%s' "$v"
}

install_core() {
  _detect_arch || return 1
  local tag ver tmpdir tarball url
  tag=$(_resolve_version)
  ver="${tag#v}"
  tmpdir=$(mktemp -d)
  tarball="mita_${ver}_linux_${ARCH}.tar.gz"
  url="https://github.com/enfein/mieru/releases/download/${tag}/${tarball}"
  _info "下载 mita ${tag} (${ARCH})"
  if ! _fetch_gh "$url" "${tmpdir}/${tarball}"; then
    _error "内核下载失败: ${url}"
    _warn "可尝试: GH_PROXY=https://ghfast.top/ mr 后再装，或手动下载解压到 ${MITA_BIN}"
    rm -rf "$tmpdir"; return 1
  fi
  if ! tar xzf "${tmpdir}/${tarball}" -C "$tmpdir" 2>/dev/null; then
    _error "解压失败，文件可能不完整。"
    rm -rf "$tmpdir"; return 1
  fi
  local bin
  bin=$(find "$tmpdir" -maxdepth 2 -type f -name mita -perm -u+x 2>/dev/null | head -n1)
  [ -z "$bin" ] && bin=$(find "$tmpdir" -maxdepth 2 -type f -name mita 2>/dev/null | head -n1)
  if [ -z "$bin" ]; then
    _error "压缩包里没找到 mita 可执行文件。"; rm -rf "$tmpdir"; return 1
  fi
  install -m 755 "$bin" "$MITA_BIN"
  rm -rf "$tmpdir"
  mkdir -p "$APP_DIR" "$SUB_DIR" "$RUNTIME_DIR" /var/lib/mita
  _create_service
  _success "内核已安装: $($MITA_BIN version 2>/dev/null | head -n1)"
  _success "服务已注册: ${SERVICE_NAME} (init: ${INIT_SYSTEM})"
}

# ---------------- 元数据 ----------------
_init_metadata() {
  mkdir -p "$APP_DIR" "$SUB_DIR" "$RUNTIME_DIR"
  if [ ! -s "$METADATA_FILE" ]; then
    jq -n '{version:1, ports:[], mtu:1400, multiplexing:"MULTIPLEXING_LOW", ip_ver:"v4", users:[], geo:{ts:0,cc:"",isp:""}}' > "$METADATA_FILE"
  fi
  [ -s "$METADATA_FILE" ] || { _error "元数据文件损坏: $METADATA_FILE"; return 1; }
}

_meta_get() { jq -r "$1" "$METADATA_FILE" 2>/dev/null; }

_meta_set() {  # $1 = jq 表达式, $2 = 值(字符串)
  local tmp; tmp=$(mktemp)
  jq --arg v "$2" "$1 = \$v" "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
}

_meta_set_ports() {  # $1 = JSON 数组字符串
  local tmp; tmp=$(mktemp)
  jq --argjson p "$1" '.ports = $p' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
}

_port_in_use() {
  ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1$"
}

# 这个端口是不是本项目自己正在用的（切换协议/改配置时不能把自己判成"被占用"）
# 注意: 端口跳跃时配置里存的是 portRange，端口号只是落在段内，也必须算"自己的"
_port_owned_by_us() {
  local p="$1" a b
  [ -s "$METADATA_FILE" ] || return 1
  if jq -r '.ports[]? | (.port // empty)' "$METADATA_FILE" 2>/dev/null | grep -qx "$p"; then
    return 0
  fi
  while IFS='-' read -r a b; do
    [ -z "$b" ] && continue
    if [ "$p" -ge "$a" ] 2>/dev/null && [ "$p" -le "$b" ] 2>/dev/null; then
      return 0
    fi
  done < <(jq -r '.ports[]? | (.portRange // empty)' "$METADATA_FILE" 2>/dev/null)
  return 1
}

# 没有用户时 mita 不会启动监听（配置校验不过），此时不该判"端口没起来"为失败
_has_users() {
  [ -s "$METADATA_FILE" ] && [ "$(jq '.users | length' "$METADATA_FILE" 2>/dev/null)" -gt 0 ]
}

_pick_port() {
  local p i
  for i in $(seq 1 50); do
    p=$(shuf -i 10000-65535 -n 1)
    _port_in_use "$p" || { printf '%s' "$p"; return; }
  done
  printf '10000'
}

# ---------------- 配置生成 / 应用 ----------------
_regen_config() {
  local tmp
  tmp=$(mktemp)
  jq --arg ds "PREFER_IPv4" \
     '{portBindings: .ports, users: [.users[] | {name: .name, password: .password}],
       loggingLevel: "INFO", mtu: .mtu,
       dns: {dualStack: $ds}}' "$METADATA_FILE" > "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    _error "生成配置失败（metadata 不完整）。"
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$CONFIG_JSON"
}

# 应用配置: 守护进程在线就走 replace config(RPC 会做完整校验), 离线直接落盘
_apply_config() {
  _regen_config || return 1
  if _service_active && "$MITA_BIN" status >/dev/null 2>&1; then
    local out
    out=$("$MITA_BIN" replace config "$CONFIG_JSON" 2>&1)
    if [ $? -ne 0 ]; then
      _error "配置校验失败，服务未重启："
      echo "$out" | sed 's/^/        /'
      return 1
    fi
  fi
  return 0
}

# 端口/MTU 变化必须重启进程; 仅用户变化 reload 就够, 但重启更可预期
_probe_ports() {
  local out="" p proto
  out=$(jq -r '.ports[] | "\(.port // .portRange)/\(.protocol)"' "$METADATA_FILE" 2>/dev/null | paste -sd, -)
  printf '%s' "$out"
}

# ---------------- 用户 ----------------
# 交互入口: 端口还没定的话先问端口, 再建用户
_add_user() {
  _init_metadata || return 1
  local ports
  ports=$(_probe_ports)
  if [ -z "$ports" ]; then
    echo "服务端还没有监听端口（节点还没定），先定一个 —— 所有用户共用，单端口或端口段都行。"
    _ask_ip_ver
    _modify_ports_from_add || return 1
  fi
  _user_create
}

# 纯执行层: 不提任何问题, 交互菜单和 CLI 快捷命令共用
_user_create() {
  _init_metadata || return 1
  if [ -z "$(_probe_ports)" ]; then
    _error "还没有监听端口，请先设置端口（菜单 3 或 mr setport）。"
    return 1
  fi
  local uname pass tmp
  uname="u$(_gen_hex 6)"
  pass=$(_gen_hex 16)
  _info "生成用户: ${uname}"
  tmp=$(mktemp)
  jq --arg n "$uname" --arg p "$pass" \
     '.users += [{name:$n, password:$p, created: (now|floor)}]' "$METADATA_FILE" > "$tmp" \
     && mv -f "$tmp" "$METADATA_FILE"

  if ! _apply_config; then
    _error "配置写入失败，已回滚该用户。"
    _delete_user_silent "$uname"
    return 1
  fi

  if _service_active; then
    _restart_service
  else
    _start_service
  fi
  sleep 1
  if _service_active; then
    _success "用户已添加并已生效。"
  else
    _warn "服务未处于运行状态，请查看菜单 8 日志。"
  fi
  _show_user_link "$uname"
}

_delete_user_silent() {
  local tmp; tmp=$(mktemp)
  jq --arg n "$1" 'del(.users[] | select(.name == $n))' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
}

_delete_user_menu() {
  _init_metadata || return 1
  local n; n=$(jq '.users | length' "$METADATA_FILE")
  if [ "$n" -eq 0 ]; then _warn "当前没有用户。"; return; fi
  echo "现有用户:"
  jq -r '.users | to_entries[] | "  \(.key + 1)) \(.value.name)"' "$METADATA_FILE"
  local idx name
  read -rp "要删除第几个? [0 取消]: " idx || idx=""
  idx=$(_clean_input "$idx")
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { _warn "已取消。"; return; }
  name=$(jq -r --argjson i $((idx - 1)) '.users[$i].name' "$METADATA_FILE")
  read -rp "确认删除用户 ${name} ? [y/N]: " c || c=""
  [[ "$c" =~ ^[Yy]$ ]] || { _warn "已取消。"; return; }
  _delete_user_silent "$name"
  _apply_config && { _restart_service; _success "已删除 ${name}。"; }
}

# ---------------- 端口 / 参数 ----------------
_modify_ports_from_add() {
  local p proto_choice p_in proto ports desc
  p=$(_pick_port)
  echo "监听协议: 1) 仅 TCP（最稳，推荐）  2) TCP + UDP（同号，UDP 更抗丢包）"
  read -rp "选择 [1]: " proto_choice || proto_choice=""
  proto_choice=$(_clean_input "$proto_choice")
  case "$proto_choice" in
    2|u|U|udp|UDP) proto="both"; desc="TCP + UDP 同号" ;;
    *)             proto="tcp";  desc="仅 TCP" ;;
  esac
  echo "端口填单个数字（如 25443），或填一段范围（如 30000-30999，客户端每条连接随机挑）——两者只能选一种。"
  read -rp "监听端口 [${p}]: " p_in || p_in=""
  p_in=$(_clean_input "$p_in")
  [ -n "$p_in" ] && p="$p_in"
  _check_spec_free "$p" || return 1
  ports=$(_port_spec_to_ports "$p" "$proto") || return 1
  _meta_set_ports "$ports"
  # E1: 首次建用户时选的 v4/v6 必须落盘, 否则链接与配置一直按默认 v4 生成
  [ -n "${IP_VER:-}" ] && _meta_set '.ip_ver' "$IP_VER"
  PENDING_PORT="$p"
  _info "监听: ${p}（${desc}）"
  return 0
}

_modify_ports_menu() {
  _init_metadata || return 1
  echo "当前端口: $(_probe_ports)"
  echo "当前 MTU: $(_meta_get '.mtu')"
  echo "当前多路复用: $(_meta_get '.multiplexing')"
  _ask_ip_ver
  local tmp; tmp=$(mktemp)
  jq --arg v "$IP_VER" '.ip_ver = $v' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"

  local p
  _modify_ports_from_add || return 1
  p="$PENDING_PORT"

  local mtu; mtu=$(_meta_get '.mtu')
  read -rp "MTU [${mtu}]（1280-1400，默认 1400）: " m || m=""
  m=$(_clean_input "$m")
  if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge 1280 ] && [ "$m" -le 1400 ]; then
    tmp=$(mktemp); jq --argjson m "$m" '.mtu = $m' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
  fi

  echo "多路复用: 1) LOW(默认)  2) MIDDLE  3) HIGH  4) OFF"
  local mp; read -rp "选择 [1]: " mp || mp=""
  mp=$(_clean_input "$mp")
  case "$mp" in
    2) _meta_set_mux "MULTIPLEXING_MIDDLE" ;;
    3) _meta_set_mux "MULTIPLEXING_HIGH" ;;
    4) _meta_set_mux "MULTIPLEXING_OFF" ;;
    *) _meta_set_mux "MULTIPLEXING_LOW" ;;
  esac

  _apply_config || return 1
  _restart_service
  if ! _has_users; then
    _info "端口已切到 ${p}，添加用户后开始监听。"
  elif _wait_spec_listen "$p"; then
    _success "端口已切换到 ${p}，监听正常。"
  else
    _warn "端口 ${p} 30 秒内未监听，请看菜单 8 日志。"
  fi
  _show_links
}

_meta_set_mux() {
  local tmp; tmp=$(mktemp)
  jq --arg m "$1" '.multiplexing = $m' "$METADATA_FILE" > "$tmp" && mv -f "$tmp" "$METADATA_FILE"
}

# ---------------- 链接 ----------------
_build_user_link() {
  local uname="$1" ip="$2" host qs
  local pass; pass=$(jq -r --arg n "$uname" '.users[] | select(.name == $n) | .password' "$METADATA_FILE")
  host=$(_link_host "$ip")
  qs="profile=$(_url_encode "$uname")"
  while IFS='/' read -r port proto; do
    [ -z "$port" ] && continue
    qs="${qs}&port=${port}&protocol=${proto}"
  done < <(jq -r '.ports[] | "\(.port // .portRange)/\(.protocol)"' "$METADATA_FILE")
  qs="${qs}&mtu=$(_meta_get '.mtu')&multiplexing=$(_meta_get '.multiplexing')&handshake-mode=HANDSHAKE_STANDARD"
  printf 'mierus://%s:%s@%s?%s' "$(_url_encode "$uname")" "$(_url_encode "$pass")" "$host" "$qs"
}

_show_user_link() {
  local uname="$1" ip ver
  ver=$(_meta_get '.ip_ver'); [ -z "$ver" ] && ver="v4"
  ip=$(_resolve_node_ip "$ver")
  if [ -z "$ip" ]; then _error "无法探测本机公网 IP，链接未生成。"; return 1; fi
  echo ""
  echo -e "${GREEN}用户: ${uname}${NC}"
  echo "地址: $(_link_host "$ip")   端口: $(_probe_ports)"
  echo "复用: $(_meta_get '.multiplexing')   MTU: $(_meta_get '.mtu')"
  echo ""
  echo -e "${CYAN}--- mieru 客户端链接 ---${NC}"
  _build_user_link "$uname" "$ip"
  echo ""
  echo -e "${CYAN}--- mihomo / Clash Meta 配置 ---${NC}"
  _build_clash_yaml "$ip" "$uname" | sed 's/^/  /'
  echo ""
}

_build_clash_yaml() {  # $1 = IP, $2 = 只导出该用户(留空=全部)
  local ip="$1" only="${2:-}" ver
  ver=$(_meta_get '.ip_ver'); [ -z "$ver" ] && ver="v4"
  [ -z "$ip" ] && ip=$(_resolve_node_ip "$ver")
  # YAML 里绝不能给 IPv6 加方括号 —— `server: [2602:...]` 会被解析成数组
  local geo; geo=$(_geo_name)
  local -a tags=()
  local uidx=0
  echo "proxies:"
  while IFS= read -r row; do
    local uname pass usuf=""
    uname=$(printf '%s' "$row" | cut -d'|' -f1)
    pass=$(printf '%s' "$row" | cut -d'|' -f2)
    # 多用户时第 2 个起加 .2/.3 后缀，否则 mihomo 里会重名
    [ "$uidx" -gt 0 ] && usuf=".$((uidx + 1))"
    while IFS='|' read -r spec proto; do
      [ -z "$spec" ] && continue
      local tag="${geo}.${proto}${usuf}"
      tags+=("$tag")
      echo "  - name: \"${tag}\""
      echo "    type: mieru"
      echo "    server: \"${ip}\""
      if [[ "$spec" == *-* ]]; then
        echo "    port-range: \"${spec}\""
      else
        echo "    port: ${spec}"
      fi
      echo "    username: \"${uname}\""
      echo "    password: \"${pass}\""
      echo "    transport: ${proto}"
      echo "    udp: true"
      echo "    multiplexing: $(_meta_get '.multiplexing')"
      echo "    handshake-mode: HANDSHAKE_STANDARD"
    done < <(jq -r '.ports[] | "\(.port // .portRange)|\(.protocol)"' "$METADATA_FILE")
    uidx=$((uidx + 1))
  done < <(jq -r --arg only "$only" '.users[] | select($only == "" or .name == $only) | "\(.name)|\(.password)"' "$METADATA_FILE")
  local names
  names=$(printf '%s\n' "${tags[@]}" | paste -sd, - | sed 's/,/, /g')
  echo "proxy-groups:"
  echo "  - name: \"PROXY\""
  echo "    type: select"
  echo "    proxies: [${names}]"
}

_show_links() {
  _init_metadata || return 1
  local ver ip n
  ver=$(_meta_get '.ip_ver'); [ -z "$ver" ] && ver="v4"
  ip=$(_resolve_node_ip "$ver")
  n=$(jq '.users | length' "$METADATA_FILE")
  if [ "$n" -eq 0 ]; then _warn "还没有用户，请先【1 添加用户】。"; return; fi
  if [ -z "$ip" ]; then _error "无法探测公网 IP，请检查网络。"; return; fi
  _info "监听: $(_probe_ports)   对外地址: $(_link_host "$ip")   MTU: $(_meta_get '.mtu')"
  echo ""
  echo -e "${CYAN}=========== mieru 客户端链接 ===========${NC}"
  while IFS= read -r u; do
    echo "$(_build_user_link "$u" "$ip")"
  done < <(jq -r '.users[].name' "$METADATA_FILE")
  echo ""
  echo -e "${CYAN}=========== mihomo / Clash Meta ===========${NC}"
  _build_clash_yaml "$ip"

  # 落盘: 明文 links / clash.yaml / base64 list.txt
  mkdir -p "$SUB_DIR"
  while IFS= read -r u; do _build_user_link "$u" "$ip"; echo ""; done < <(jq -r '.users[].name' "$METADATA_FILE") > "${SUB_DIR}/links.txt"
  _build_clash_yaml "$ip" > "${SUB_DIR}/clash.yaml"
  { cat "${SUB_DIR}/clash.yaml"; echo ""; cat "${SUB_DIR}/links.txt"; } | base64 | tr -d '\n' > "${SUB_DIR}/list.txt"
  echo ""
  _success "已写入 ${SUB_DIR}/links.txt、clash.yaml、list.txt(base64)"
}

# ---------------- 状态 / 日志 ----------------
_menu_status() {
  echo -e "${CYAN}--- 运行状态 ---${NC}"
  echo "init: ${INIT_SYSTEM}"
  if [ -x "$MITA_BIN" ]; then
    echo "内核: $($MITA_BIN version 2>/dev/null | head -n1)"
  else
    echo "内核: 未安装"
  fi
  _service_active && _success "mieru 服务运行中" || _warn "mieru 服务未运行"
  if [ -s "$METADATA_FILE" ]; then
    echo "监听: $(_probe_ports || echo 未配置)   MTU: $(_meta_get '.mtu')   复用: $(_meta_get '.multiplexing')"
    echo "用户数量: $(jq '.users | length' "$METADATA_FILE" 2>/dev/null)"
  fi
  if [ -x "$MITA_BIN" ] && _service_active; then
    local st; st=$("$MITA_BIN" status 2>/dev/null)
    [ -n "$st" ] && echo "代理状态: ${st}"
  fi
}

_show_conns() {
  if ! _service_active; then _warn "服务未运行。"; return; fi
  _info "当前连接:"
  "$MITA_BIN" get connections 2>/dev/null | head -n 30 || _warn "取连接信息失败。"
  echo ""
  _info "用户列表:"
  "$MITA_BIN" get users 2>/dev/null | head -n 30 || true
}

_show_logs() {
  _info "按 Ctrl+C 退出日志跟踪"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    journalctl -u ${SERVICE_NAME} -n 60 -f --no-pager
  else
    tail -n 60 -f "$CORE_LOG"
  fi
}

# ---------------- BBR ----------------
_toggle_bbr() {
  local cur
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  echo "当前拥塞控制算法: ${cur:-未知}"
  if [ "$cur" = "bbr" ]; then
    _info "BBR 已启用。"
    return
  fi
  modprobe tcp_bbr 2>/dev/null
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    _error "当前内核不支持 BBR（内核版本过低）。"
    return 1
  fi
  cat > /etc/sysctl.d/99-mieru-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
  _success "BBR 已启用: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

# ---------------- 更新脚本 ----------------
_update_script() {
  local target="/usr/local/bin/mr"
  [ -x "$SELF_SCRIPT_PATH" ] && [[ "$SELF_SCRIPT_PATH" == /usr/local/bin/* ]] && target="$SELF_SCRIPT_PATH"
  local cur_ver="$SCRIPT_VERSION" bust url tmp
  bust="?t=$(date +%s)"
  url="${GITHUB_RAW_URL}${bust}"
  tmp="${APP_DIR}/mr.update"
  mkdir -p "$APP_DIR"
  rm -f "$tmp"
  _info "更新脚本: ${GITHUB_RAW_URL} → ${target} (当前 v${cur_ver})"
  _fetch_gh "$url" "$tmp" || { _error "脚本下载失败，未做任何更改。"; rm -f "$tmp"; return 1; }
  if ! { [ -s "$tmp" ] && head -n1 "$tmp" | grep -q "^#!/bin/bash" && bash -n "$tmp" 2>/dev/null; }; then
    _error "脚本校验失败，未做任何更改。"
    rm -f "$tmp"; return 1
  fi
  local new_ver
  new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
  chmod +x "$tmp"
  mv -f "$tmp" "$target"
  if [ -n "$new_ver" ] && [ "$new_ver" = "$cur_ver" ]; then
    _warn "远端仍是 v${new_ver}，已按最新内容覆盖（若刚发版请等 1-2 分钟重试）。"
  else
    _success "脚本已更新: v${cur_ver} → ${new_ver:-未知}，正在重载…"
    [ -x "$target" ] && exec "$target"
  fi
}

# ---------------- 卸载 ----------------
_uninstall() {
  read -rp "确认卸载 mieru-lite（内核/服务/配置全部删除）? [y/N]: " c || c=""
  [[ "$c" =~ ^[Yy]$ ]] || return
  _stop_service
  case "$INIT_SYSTEM" in
    systemd)
      systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      ;;
    openrc)
      rc-update del ${SERVICE_NAME} default >/dev/null 2>&1
      rm -f "/etc/init.d/${SERVICE_NAME}"
      ;;
  esac
  rm -f "$MITA_BIN" /usr/local/bin/mr /etc/sysctl.d/99-mieru-bbr.conf
  rm -rf "$APP_DIR" "$RUNTIME_DIR" /var/lib/mita
  _success "mieru-lite 已卸载。"
  exit 0
}

# ---------------- 端口跳跃 ----------------
# 服务端在整段端口上监听 (mita 原生 portRange, 段内每个口各一个 socket);
# 客户端 (mihomo / mieru 官方客户端) 每条连接随机挑一个口 —— 见 pkg/protocol/mux.go newUnderlay()

_count_listen_in_range() {  # $1=起始 $2=结束 $3=TCP|UDP
  local a="$1" b="$2" proto="${3:-TCP}"
  if [ "$proto" = "UDP" ]; then ss -lnu 2>/dev/null; else ss -tln 2>/dev/null; fi \
    | awk -v a="$a" -v b="$b" '{n=$4; sub(/.*:/, "", n); if (n+0>=a && n+0<=b) c++} END{print c+0}'
}

# 校验端口段, 结果放 HOP_A / HOP_B / HOP_N
_hop_range_valid() {
  local r="$1" a b n
  if ! [[ "$r" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    _error "格式错误: ${r}（应为 起-止，例如 30000-30999）"; return 1
  fi
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  if [ "$a" -lt 1025 ] || [ "$b" -gt 65535 ]; then _error "端口需在 1025-65535 之间。"; return 1; fi
  if [ "$a" -ge "$b" ]; then _error "起始端口必须小于结束端口（至少 2 个）。"; return 1; fi
  n=$((b - a + 1))
  if [ "$n" -gt "$MAX_HOP_PORTS" ]; then
    _error "范围 ${n} 个端口，超过上限 ${MAX_HOP_PORTS}。"
    _warn "mita 要给段内每个端口各开一个监听，实测约 12KB 内存/端口、fd 一对一，${n} 个约 $((n * 12 / 1024))MB。"
    _info "确实要这么大就用 MAX_HOP_PORTS=${n} 重新执行。"
    return 1
  fi
  HOP_A="$a"; HOP_B="$b"; HOP_N="$n"
  return 0
}

# ---------------- 端口规格（单端口 / 端口段，二选一） ----------------
# 一个节点只能用一种形态：写了 port 就不能有 port-range（mihomo 会直接报
# "port and port-range cannot be set at the same time"），反过来也一样。
# 所以 ports 数组一律从这里生成，绝不在同一份 metadata 里混写两种。

# $1 = 25443 或 30000-30999   $2 = tcp | udp | both
# 校验通过后打印 metadata.ports 的 JSON 数组
_port_spec_to_ports() {
  local spec="$1" proto="${2:-tcp}" a b
  if [[ "$spec" == *-* ]]; then
    _hop_range_valid "$spec" || return 1
    a=$HOP_A; b=$HOP_B
    case "$proto" in
      udp|tcp+udp|both) printf '[{"portRange":"%s-%s","protocol":"TCP"},{"portRange":"%s-%s","protocol":"UDP"}]' "$a" "$b" "$a" "$b" ;;
      *)                printf '[{"portRange":"%s-%s","protocol":"TCP"}]' "$a" "$b" ;;
    esac
    return 0
  fi
  if ! [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then
    _error "格式错误: ${spec}（写单个端口 25443，或一段 30000-30999）"; return 1
  fi
  a=$((10#$spec))
  if [ "$a" -lt 1025 ] || [ "$a" -gt 65535 ]; then
    _error "端口非法: ${a}（需 1025-65535）"; return 1
  fi
  case "$proto" in
    udp|tcp+udp|both) printf '[{"port":%s,"protocol":"TCP"},{"port":%s,"protocol":"UDP"}]' "$a" "$a" ;;
    *)                printf '[{"port":%s,"protocol":"TCP"}]' "$a" ;;
  esac
}

# 端口规格的占用检查（本项目自己正在用的不算占用；端口段逐口扫全段, 只看首尾会漏中间）
_check_spec_free() {
  local spec="$1" a b
  if [[ "$spec" == *-* ]]; then
    _hop_range_valid "$spec" || return 1
    a=$HOP_A; b=$HOP_B
    # E2: 段内任一端口被占, mieru 整段起不来; 只查首尾会漏中间
    local busy p offenders=""
    busy=$(ss -lntu 2>/dev/null | awk -v a="$a" -v b="$b" '{
        q=$5; sub(/.*[:.]/,"",q)
        if (q !~ /^[0-9]+$/) next
        v=q+0
        if (v >= a && v <= b) print v
      }' | sort -un)
    for p in $busy; do
      _port_owned_by_us "$p" && continue
      offenders="${offenders} ${p}"
    done
    if [ -n "$offenders" ]; then
      _error "端口段 ${a}-${b} 内已被占用:${offenders}"
      _error "mieru 段内任一端口被占会导致整段监听失败，换个段再试。"
      return 1
    fi
    return 0
  fi
  if ! [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then
    _error "格式错误: ${spec}（写单个端口 25443，或一段 30000-30999）"; return 1
  fi
  a=$((10#$spec))
  if [ "$a" -lt 1025 ] || [ "$a" -gt 65535 ]; then
    _error "端口非法: ${a}（需 1025-65535）"; return 1
  fi
  if ! _port_owned_by_us "$a"; then
    _port_in_use "$a" && { _error "端口 ${a} 已被其它程序占用。"; return 1; }
  fi
  return 0
}

# 等监听: 单端口看那个口，端口段看段内监听到的数量
_wait_spec_listen() {
  local spec="$1" i n=0
  if [[ "$spec" != *-* ]]; then
    _wait_listen "$spec"; return $?
  fi
  _hop_range_valid "$spec" || return 1
  for i in $(seq 1 20); do
    n=$(_count_listen_in_range "$HOP_A" "$HOP_B" TCP)
    [ "$n" -ge "$HOP_N" ] && return 0
    sleep 1
  done
  return 1
}

# 写入端口段并生效: $1=起-止  $2=tcp|udp|both
_set_hop_cli() {
  local range="$1" proto="${2:-tcp}" ports desc tcpc udpc
  _init_metadata || return 1
  # 传进来是单个端口就交给 setport, 形态永远只有一种
  case "$range" in
    *-*) : ;;
    *) _set_port_cli "$range" "$proto"; return ;;
  esac
  _check_spec_free "$range" || return 1
  ports=$(_port_spec_to_ports "$range" "$proto") || return 1
  case "$proto" in
    udp|tcp+udp|both) desc="TCP + UDP 同段" ;;
    *)                desc="仅 TCP" ;;
  esac
  _meta_set_ports "$ports"
  _info "端口跳跃: ${HOP_A}-${HOP_B}（${HOP_N} 个，${desc}）"
  _apply_config || return 1
  _restart_service
  if ! _has_users; then
    _info "端口段已写入，添加用户后开始监听（mita 无用户时不启监听）。"
    return 0
  fi
  local i tcpc=0 udpc=0
  for i in $(seq 1 20); do
    tcpc=$(_count_listen_in_range "$HOP_A" "$HOP_B" TCP)
    [ "$tcpc" -ge "$HOP_N" ] && break
    sleep 1
  done
  case "$proto" in
    udp|tcp+udp|both) udpc=$(_count_listen_in_range "$HOP_A" "$HOP_B" UDP) ;;
  esac
  if [ "$tcpc" -ge "$HOP_N" ]; then
    _success "TCP 段内 ${tcpc}/${HOP_N} 个端口已监听。"
    case "$proto" in
      udp|tcp+udp|both) [ "$udpc" -ge "$HOP_N" ] && _success "UDP 段内 ${udpc}/${HOP_N} 个端口已监听。" || _warn "UDP 只监听到 ${udpc}/${HOP_N}，请看菜单 8 日志。" ;;
    esac
  else
    _warn "TCP 只监听到 ${tcpc}/${HOP_N}，可能被 fd 上限卡住，请看菜单 8 日志。"
  fi
  _info "记得在防火墙 / 安全组放行 ${HOP_A}-${HOP_B}（TCP 和 UDP 分别放）。"
  _show_links
}

_menu_set_hop() {
  _init_metadata || return 1
  echo ""
  echo "端口跳跃：服务端在整段端口上监听，客户端每次连接随机挑一个。"
  echo "代价：段内每个端口各占一个监听，约 12KB 内存 + 1 个 fd，上限 ${MAX_HOP_PORTS} 个。"
  echo "建议范围 100-1000 个，例如 30000-30999；只填单个端口请用菜单 3 / mr setport。"
  local r p
  read -rp "端口段 [30000-30999]: " r || r=""
  r=$(_clean_input "$r"); [ -z "$r" ] && r="30000-30999"
  echo "  1) 仅 TCP（默认）"
  echo "  2) TCP + UDP 同段"
  read -rp "传输协议 [1]: " p || p=""
  p=$(_clean_input "$p")
  case "$p" in 2|u|U|udp|UDP) _set_hop_cli "$r" both ;; *) _set_hop_cli "$r" tcp ;; esac
}

# ---------------- 菜单 ----------------
_show_menu() {
  echo ""
  echo -e "${GREEN}======== mieru-lite 管理脚本 v${SCRIPT_VERSION} ========${NC}"
  echo " 1. 添加用户（共用服务端节点，每人一条链接）"
  echo " 2. 查看用户链接（mieru / mihomo）"
  echo " 3. 修改监听端口（或端口段）/ MTU / 多路复用 / IP 版本"
  echo " 4. 删除用户"
  echo " 5. 重启服务"
  echo " 6. 停止服务"
  echo " 7. 查看运行状态"
  echo " 8. 查看实时日志"
  echo " 9. 查看当前连接与用户列表"
  echo "10. 开启 BBR"
  echo "11. 安装 / 更新 mita 内核"
  echo "12. 更新脚本 (mr)"
  echo "13. 端口跳跃（只改端口段，客户端随机挑）"
  echo "14. 卸载"
  echo " 0. 退出"
}

_main_menu() {
  while true; do
    _menu_status
    _show_menu
    read -rp "请选择: " choice || { echo ""; _info "输入结束，退出。"; exit 0; }
    choice=$(_clean_input "$choice")
    case "$choice" in
      1)
        if [ ! -x "$MITA_BIN" ]; then
          _warn "检测到 mita 内核未安装。"
          read -rp "是否现在安装? [Y/n]: " ic || ic=""
          if [[ ! "$ic" =~ ^[Nn]$ ]]; then
            install_core || { _error "内核安装失败，请检查网络。"; continue; }
          else
            _warn "未安装内核，添加的用户无法运行。"
          fi
        fi
        _add_user
        ;;
      2) _show_links ;;
      3) _modify_ports_menu ;;
      4) _delete_user_menu ;;
      5)
        _restart_service
        local p; p=$(jq -r '.ports[0].port // empty' "$METADATA_FILE" 2>/dev/null)
        if [ -n "$p" ] && _wait_listen "$p"; then _success "已重启，端口 ${p} 监听正常。"; else _warn "重启完成，但端口未确认监听，请看日志。"; fi
        ;;
      6) _stop_service; _success "已停止。" ;;
      7) _menu_status ;;
      8) _show_logs ;;
      9) _show_conns ;;
      10) _toggle_bbr ;;
      11) install_core ;;
      12) _update_script ;;
      13) _menu_set_hop ;;
      14) _uninstall ;;
      0) exit 0 ;;
      *) _error "无效输入。" ;;
    esac
  done
}

# ---------------- 快捷命令（非交互，便于脚本化） ----------------
_set_port_cli() {  # $1=端口（或端口段） $2=tcp|udp|both
  local p="$1" proto="${2:-tcp}" ports desc
  # 传进来是范围就交给 hop, 形态永远只有一种
  case "$p" in
    *-*) _set_hop_cli "$p" "$proto"; return ;;
  esac
  _init_metadata || return 1
  _check_spec_free "$p" || return 1
  ports=$(_port_spec_to_ports "$p" "$proto") || return 1
  case "$proto" in
    udp|tcp+udp|both) desc="TCP + UDP 同号" ;;
    *)                desc="仅 TCP" ;;
  esac
  _meta_set_ports "$ports"
  _info "监听端口: ${p}（${desc}）"
  _apply_config || return 1
  _restart_service
  if ! _has_users; then
    _info "端口 ${p} 已写入，添加用户后开始监听（mita 无用户时不会启监听）。"
  elif _wait_spec_listen "$p"; then
    _success "端口 ${p} 监听正常。"
  else
    _warn "端口 ${p} 未确认监听，请看日志。"
  fi
}

main() {
  _check_root
  _install_dependencies || exit 1
  _detect_init_system
  _init_metadata
  if [ ! -x "$MITA_BIN" ]; then
    _warn "mita 内核未安装，请选择菜单【11】安装内核。"
  fi
  _main_menu
}

# 快捷命令
case "${1:-}" in
  links)   _check_root; _install_dependencies >/dev/null 2>&1; _init_metadata; _show_links; exit 0 ;;
  status)  _check_root; _init_metadata; _detect_init_system; _menu_status; exit 0 ;;
  install) _check_root; _install_dependencies || exit 1; _detect_init_system; _init_metadata; install_core; exit 0 ;;
  adduser) _check_root; _init_metadata; _detect_init_system; _user_create; exit 0 ;;
  setport) _check_root; _init_metadata; _detect_init_system; _set_port_cli "${2:-}" "${3:-tcp}"; exit 0 ;;
  hop)     _check_root; _init_metadata; _detect_init_system; _set_hop_cli "${2:-}" "${3:-tcp}"; exit 0 ;;
  version) echo "mieru-lite v${SCRIPT_VERSION}"; exit 0 ;;
esac

main
