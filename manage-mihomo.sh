#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"
BIN_DIR="${WORKSPACE_DIR}/bin"
CONFIG_DIR="${WORKSPACE_DIR}/config"
DATA_DIR="${WORKSPACE_DIR}/data"
LOG_DIR="${WORKSPACE_DIR}/log"
RUN_DIR="${WORKSPACE_DIR}/run"
MIHOMO_BIN="${BIN_DIR}/mihomo"
UI_DIR="${DATA_DIR}/ui"
SUB_FILE="${CONFIG_DIR}/subscription.url"
LOG_FILE="${LOG_DIR}/mihomo.log"
PID_FILE="${RUN_DIR}/mihomo.pid"
PKG_MGR=""
APT_UPDATED=0
RESOURCE_DIR="${SCRIPT_DIR}/resource"

print_line() {
  printf '%s\n' "----------------------------------------"
}

print_title() {
  print_line
  printf '%s\n' "Mihomo 一键管理脚本"
  print_line
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "请使用 root 运行本脚本，例如: sudo $0"
    exit 1
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    PKG_MGR=""
  fi
}

ensure_pkg() {
  if [ "$#" -lt 1 ]; then
    return 0
  fi
  if [ -z "$PKG_MGR" ]; then
    return 0
  fi
  case "$PKG_MGR" in
    apt-get)
      if [ "$APT_UPDATED" -eq 0 ]; then
        APT_UPDATED=1
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf install -y "$@" >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y "$@" >/dev/null 2>&1 || true
      ;;
    pacman)
      pacman -Sy --noconfirm "$@" >/dev/null 2>&1 || true
      ;;
    apk)
      apk add --no-cache "$@" >/dev/null 2>&1 || true
      ;;
    zypper)
      zypper --non-interactive install -y "$@" >/dev/null 2>&1 || true
      ;;
  esac
}

detect_arch() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)
      printf '%s\n' "amd64"
      ;;
    aarch64|arm64)
      printf '%s\n' "arm64"
      ;;
    armv7l|armv7*)
      printf '%s\n' "armv7"
      ;;
    armv6l|armv6*)
      printf '%s\n' "armv6"
      ;;
    i386|i686)
      printf '%s\n' "386"
      ;;
    *)
      printf '%s\n' "$m"
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "$WORKSPACE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$UI_DIR"
}

get_mixed_port() {
  if [ -f "${CONFIG_DIR}/config.yaml" ]; then
    local p
    p=$(grep -E '^[[:space:]]*mixed-port:' "${CONFIG_DIR}/config.yaml" 2>/dev/null | head -n1 | sed 's/[^0-9]*\([0-9]\+\).*/\1/' || true)
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  printf '%s\n' "7890"
}

get_socks_port() {
  if [ -f "${CONFIG_DIR}/config.yaml" ]; then
    local p
    p=$(grep -E '^[[:space:]]*socks-port:' "${CONFIG_DIR}/config.yaml" 2>/dev/null | head -n1 | sed 's/[^0-9]*\(\[0-9]\+\).*/\1/' || true)
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  printf '%s\n' "7891"
}

test_proxy_connectivity() {
  detect_pkg_mgr
  ensure_pkg curl ca-certificates
  local mixed_port socks_port
  mixed_port=$(get_mixed_port)
  socks_port=$(get_socks_port)
  print_line
  printf '%s\n' "启动后通过 HTTP 代理测试连通性"
  printf '使用代理: http://127.0.0.1:%s\n' "$mixed_port"
  local host
  for host in google.com github.com api.github.com; do
    printf '测试 https://%s ... ' "$host"
    if curl -x "http://127.0.0.1:${mixed_port}" -I -s --max-time 8 "https://${host}" >/dev/null 2>&1; then
      printf '%s\n' "成功"
    else
      printf '%s\n' "失败"
    fi
  done
  print_line
  printf '%s\n' "可在当前 Shell 中临时使用的环境变量示例:"
  printf '  export http_proxy=http://127.0.0.1:%s\n' "$mixed_port"
  printf '  export https_proxy=http://127.0.0.1:%s\n' "$mixed_port"
  printf '  export all_proxy=socks5://127.0.0.1:%s\n' "$socks_port"
}

sanitize_config_geoip() {
  if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    return 0
  fi
  sed -i '/^[[:space:]]*- GEOIP,CN,DIRECT/d' "${CONFIG_DIR}/config.yaml" 2>/dev/null || true
  sed -i '/^[[:space:]]*- GEOIP,LAN,DIRECT/d' "${CONFIG_DIR}/config.yaml" 2>/dev/null || true
}

prompt_default() {
  local prompt default answer
  prompt=$1
  default=$2
  printf "%s [%s]: " "$prompt" "$default"
  read -r answer || answer=""
  if [ -z "${answer:-}" ]; then
    answer="$default"
  fi
  printf '%s\n' "$answer"
}

ask_yes_no() {
  local prompt default answer
  prompt=$1
  default=$2
  while true; do
    printf "%s [%s]: " "$prompt" "$default"
    read -r answer || answer=""
    answer=${answer:-$default}
    case "$answer" in
      y|Y|yes|YES)
        printf '%s\n' "yes"
        return 0
        ;;
      n|N|no|NO)
        printf '%s\n' "no"
        return 0
        ;;
      *)
        printf '%s\n' "请输入 y 或 n"
        ;;
    esac
  done
}

download_mihomo_binary() {
  ensure_dirs
  detect_pkg_mgr
  ensure_pkg curl ca-certificates
  local arch api_json url tmp_file local_file
  arch=$(detect_arch)
  print_line
  printf '检测到架构: %s\n' "$arch"
  if [ -d "$RESOURCE_DIR" ]; then
    local_file=$(ls "$RESOURCE_DIR"/mihomo-linux-"$arch"* 2>/dev/null | head -n1 || true)
    if [ -n "$local_file" ]; then
      print_line
      printf '使用本地 mihomo 二进制: %s\n' "$local_file"
      mkdir -p "$(dirname "$MIHOMO_BIN")"
      case "$local_file" in
        *.gz)
          gunzip -c "$local_file" >"$MIHOMO_BIN"
          ;;
        *)
          cp "$local_file" "$MIHOMO_BIN"
          ;;
      esac
      chmod +x "$MIHOMO_BIN"
      print_line
      "$MIHOMO_BIN" -v || true
      return 0
    fi
  fi
  api_json=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest || true)
  if [ -z "$api_json" ]; then
    printf '%s\n' "获取 mihomo 版本信息失败"
    return 1
  fi
  url=$(printf '%s\n' "$api_json" | grep -oE '"browser_download_url": *"[^"]+"' | grep "linux-$arch" | grep -E '\.gz"|"$' | head -n1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
  if [ -z "$url" ]; then
    printf '%s\n' "未找到适合架构的二进制下载地址"
    return 1
  fi
  print_line
  printf '下载 mihomo: %s\n' "$url"
  tmp_file=$(mktemp)
  curl -fSL "$url" -o "$tmp_file"
  mkdir -p "$(dirname "$MIHOMO_BIN")"
  case "$url" in
    *.gz)
      gunzip -c "$tmp_file" >"$MIHOMO_BIN"
      ;;
    *)
      mv "$tmp_file" "$MIHOMO_BIN"
      tmp_file=""
      ;;
  esac
  if [ -n "${tmp_file:-}" ] && [ -f "$tmp_file" ]; then
    rm -f "$tmp_file"
  fi
  chmod +x "$MIHOMO_BIN"
  print_line
  "$MIHOMO_BIN" -v || true
}

download_geo_data() {
  ensure_dirs
  detect_pkg_mgr
  ensure_pkg curl ca-certificates
  local geoip_url geosite_url
  if [ -d "$RESOURCE_DIR" ] && [ -f "${RESOURCE_DIR}/geoip.dat" ] && [ -f "${RESOURCE_DIR}/geosite.dat" ]; then
    print_line
    printf '%s\n' "使用本地 geo 数据文件"
    cp "${RESOURCE_DIR}/geoip.dat" "${CONFIG_DIR}/geoip.dat"
    cp "${RESOURCE_DIR}/geosite.dat" "${CONFIG_DIR}/geosite.dat"
    return 0
  fi
  geoip_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
  geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
  print_line
  printf '%s\n' "下载 geo 数据文件"
  curl -fSL "$geoip_url" -o "${CONFIG_DIR}/geoip.dat"
  curl -fSL "$geosite_url" -o "${CONFIG_DIR}/geosite.dat"
}

install_ui_assets() {
  ensure_dirs
  if [ -d "${RESOURCE_DIR}/metacubexd-ui" ]; then
    print_line
    printf '%s\n' "使用本地 metacubexd UI 资源"
    rm -rf "$UI_DIR"
    mkdir -p "$UI_DIR"
    if cp -a "${RESOURCE_DIR}/metacubexd-ui/." "$UI_DIR" 2>/dev/null; then
      :
    else
      cp -r "${RESOURCE_DIR}/metacubexd-ui/." "$UI_DIR"
    fi
    return 0
  fi
  detect_pkg_mgr
  ensure_pkg git
  if [ ! -d "$UI_DIR/.git" ]; then
    rm -rf "$UI_DIR"
    mkdir -p "$(dirname "$UI_DIR")"
    print_line
    printf '%s\n' "克隆 metacubexd 仪表盘"
    git clone https://github.com/MetaCubeX/metacubexd.git -b gh-pages "$UI_DIR"
  else
    print_line
    printf '%s\n' "更新 metacubexd 仪表盘"
    git -C "$UI_DIR" pull -r || true
  fi
}

generate_config() {
  ensure_dirs
  local sub_url out
  printf "%s: " "Clash 订阅链接(仅保存为文本，可留空)"
  read -r sub_url || sub_url=""
  printf '%s\n' "$sub_url" >"$SUB_FILE"
  print_line
  printf '已保存订阅到: %s\n' "$SUB_FILE"
  if [ -n "$sub_url" ]; then
    detect_pkg_mgr
    ensure_pkg curl ca-certificates
    out="${CONFIG_DIR}/subscription.yaml"
    print_line
    printf '%s\n' "正在拉取订阅内容..."
    if curl -fSL "$sub_url" -o "$out"; then
      printf '订阅内容已保存到: %s\n' "$out"
    else
      printf '%s\n' "拉取订阅失败，请检查链接或网络"
    fi
  fi
}

start_mihomo() {
  ensure_dirs
  if [ -f "$PID_FILE" ]; then
    if kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
      printf '%s\n' "mihomo 已在运行"
      return 0
    else
      rm -f "$PID_FILE"
    fi
  fi
  if [ ! -x "$MIHOMO_BIN" ]; then
    printf '%s\n' "未找到 mihomo 可执行文件，请先安装"
    return 1
  fi
  if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    if [ -f "${CONFIG_DIR}/subscription.yaml" ]; then
      print_line
      printf '%s\n' "未找到配置文件，将使用订阅内容生成配置"
      cp "${CONFIG_DIR}/subscription.yaml" "${CONFIG_DIR}/config.yaml"
      sanitize_config_geoip
      printf '已生成配置文件: %s\n' "${CONFIG_DIR}/config.yaml"
    else
      printf '%s\n' "未找到配置文件: ${CONFIG_DIR}/config.yaml"
      printf '%s\n' "请先通过菜单 2 配置订阅，或手动下发配置后再启动 mihomo"
      return 1
    fi
  fi
  print_line
  printf '%s\n' "启动 mihomo"
  nohup "$MIHOMO_BIN" -d "$CONFIG_DIR" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 1
  if kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    printf '%s\n' "mihomo 已启动"
    test_proxy_connectivity
  else
    printf '%s\n' "mihomo 启动失败，请查看日志"
  fi
}

stop_mihomo() {
  if [ ! -f "$PID_FILE" ]; then
    printf '%s\n' "未找到 PID 文件，可能未运行"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" >/dev/null 2>&1; then
    print_line
    printf '停止 mihomo (PID %s)\n' "$pid"
    kill "$pid" || true
    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
      printf '%s\n' "进程仍在运行，尝试强制结束"
      kill -9 "$pid" || true
    fi
  else
    printf '%s\n' "进程不存在，清理 PID 文件"
  fi
  rm -f "$PID_FILE"
}

status_mihomo() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" >/dev/null 2>&1; then
      printf 'mihomo 正在运行，PID=%s\n' "$pid"
    else
      printf '%s\n' "PID 文件存在但进程不在运行"
    fi
  else
    local p
    p=$(pgrep -f "$MIHOMO_BIN" | head -n1 || true)
    if [ -n "$p" ]; then
      printf 'mihomo 可能正在运行，PID=%s\n' "$p"
    else
      printf '%s\n' "mihomo 未运行"
    fi
  fi
}

show_logs() {
  if [ ! -f "$LOG_FILE" ]; then
    printf '日志文件不存在: %s\n' "$LOG_FILE"
    return 0
  fi
  tail -n 100 -F "$LOG_FILE"
}

uninstall_mihomo() {
  local answer
  answer=$(ask_yes_no "确定要卸载 mihomo 并删除配置吗" "n")
  if [ "$answer" != "yes" ]; then
    return 0
  fi
  stop_mihomo || true
  print_line
  rm -f "$MIHOMO_BIN" "$PID_FILE"
  rm -rf "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"
  printf '%s\n' "已清理 workspace 内的 mihomo 可执行文件与数据"
  printf '如需彻底卸载，可直接删除目录: %s\n' "$WORKSPACE_DIR"
}

install_or_upgrade() {
  print_title
  download_mihomo_binary
  download_geo_data
  install_ui_assets
}

menu() {
  ensure_root
  while true; do
    print_title
    printf '%s\n' "1) 一键安装/升级 mihomo"
    printf '%s\n' "2) 配置订阅(仅保存订阅地址)"
    printf '%s\n' "3) 启动/重启 mihomo"
    printf '%s\n' "4) 停止 mihomo"
    printf '%s\n' "5) 查看状态"
    printf '%s\n' "6) 查看日志"
    printf '%s\n' "7) 仅安装/更新面板 UI"
    printf '%s\n' "8) 卸载 mihomo"
    printf '%s\n' "0) 退出"
    print_line
    printf "%s" "请选择操作: "
    local choice
    read -r choice || choice=""
    case "$choice" in
      1)
        install_or_upgrade
        ;;
      2)
        generate_config
        ;;
      3)
        stop_mihomo || true
        start_mihomo
        ;;
      4)
        stop_mihomo
        ;;
      5)
        status_mihomo
        ;;
      6)
        show_logs
        ;;
      7)
        install_ui_assets
        ;;
      8)
        uninstall_mihomo
        ;;
      0)
        exit 0
        ;;
      *)
        printf '%s\n' "无效选择，请重试"
        ;;
    esac
    printf '%s\n' ""
  done
}

main() {
  case "${1-}" in
    install)
      ensure_root
      install_or_upgrade
      ;;
    start)
      ensure_root
      start_mihomo
      ;;
    stop)
      ensure_root
      stop_mihomo
      ;;
    restart)
      ensure_root
      stop_mihomo || true
      start_mihomo
      ;;
    status)
      ensure_root
      status_mihomo
      ;;
    logs)
      ensure_root
      show_logs
      ;;
    config)
      ensure_root
      generate_config
      ;;
    ui)
      ensure_root
      install_ui_assets
      ;;
    uninstall)
      ensure_root
      uninstall_mihomo
      ;;
    ""*)
      menu
      ;;
    *)
      printf '%s\n' "用法: $0 [install|start|stop|restart|status|logs|config|ui|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
