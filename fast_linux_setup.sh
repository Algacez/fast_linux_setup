#!/usr/bin/env bash
# 功能：
#  - 安装基础包 (git, curl, python3, pip3, openssh-server, docker 等)
#  - 支持多发行版 (apt/dnf/yum/zypper/pacman)
#  - 可切换 APT/pip/Docker 镜像到国内镜像（cn）或自定义镜像
#  - 配置 SSH（端口、密码登录禁用、空闲超时 >=10 分钟）
#  - 更新/升级系统、autoremove
#  - 语言和时区配置
#  - 详细日志与备份，生成回滚脚本
#  - 交互式：运行时逐项提示（按回车使用默认）
set -Eeuo pipefail

# -------------------------
# 全局变量（运行时可由交互修改）
# -------------------------
TIMESTAMP="$(date +%F-%H%M%S)"
LOG_FILE_DEFAULT="/var/log/base-bootstrap-$TIMESTAMP.log"
BACKUP_DIR_DEFAULT="/var/backups/base-bootstrap-$TIMESTAMP"

# 默认值（会在交互中显示）
DEFAULT_MIRROR="default"         # default|cn|custom
DEFAULT_SSH_PORT="22"
DEFAULT_DISABLE_PWD="1"          # 1禁用,0不禁用
DEFAULT_LOCALE="zh_CN.UTF-8"
DEFAULT_TIMEZONE=""              # 空=不设置
DEFAULT_INSTALL_DOCKER="1"       # 1安装,0不安装
DEFAULT_PIP_MIRROR="auto"        # auto|none|cn|custom
DEFAULT_NON_INTERACTIVE="0"
DEFAULT_I_KNOW="0"
DEFAULT_DRYRUN="0"
DEFAULT_LOG_FILE="$LOG_FILE_DEFAULT"
DEFAULT_BACKUP_DIR="$BACKUP_DIR_DEFAULT"

# -------------------------
# 颜色与输出 (tty 时启用)
# -------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' RESET=''
fi
_info(){ printf "%b%s%b\n" "${BLUE}${BOLD}" "$*" "${RESET}"; }
_warn(){ printf "%b%s%b\n" "${YELLOW}${BOLD}" "$*" "${RESET}"; }
_err(){ printf "%b%s%b\n" "${RED}${BOLD}" "$*" "${RESET}"; }
_ok(){ printf "%b%s%b\n" "${GREEN}${BOLD}" "$*" "${RESET}"; }
_debug(){ printf "%b%s%b\n" "${MAGENTA}" "$*" "${RESET}" >&2; }

# -------------------------
# 解析脚本参数（仅少量，用于无人值守）
# -------------------------
NON_INTERACTIVE="$DEFAULT_NON_INTERACTIVE"
for arg in "$@"; do
  case "$arg" in
    -y|--non-interactive) NON_INTERACTIVE=1 ;;
    --dry-run) DEFAULT_DRYRUN=1 ;;
    --help|-h) echo "Usage: sudo $0 [-y|--non-interactive]"; exit 0 ;;
  esac
done

# -------------------------
# 必要权限检查（必须 root）
# -------------------------
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "非 root，尝试通过 sudo 重新执行..."
    exec sudo -E bash "$0" "$@"
  else
    _err "请以 root 身份运行本脚本。"; exit 1
  fi
fi

# -------------------------
# 交互帮助函数（默认值与非交互模式处理）
# -------------------------
ask() {
  # usage: ask varname "Prompt text" default
  local __var="$1"; shift
  local prompt="$1"; shift
  local default="$1"; shift || true
  local reply
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    reply="$default"
  else
    # prompt (show default)
    read -r -p "$prompt [$default] : " reply
    reply="${reply:-$default}"
  fi
  # assign to variable name passed
  printf -v "$__var" '%s' "$reply"
}

ask_yesno() {
  # usage: ask_yesno varname "Prompt" default(yes/no)
  local __var="$1"; shift
  local prompt="$1"; shift
  local default="$1"; shift
  local def_char
  if [[ "$default" =~ ^[Yy] ]]; then def_char="Y/n"; else def_char="y/N"; fi
  local reply
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    reply="$default"
  else
    read -r -p "$prompt ($def_char): " reply
    reply="${reply:-$default}"
  fi
  # normalize to 1/0
  if [[ "$reply" =~ ^(y|Y|yes|Yes)$ ]]; then
    printf -v "$__var" '%s' "1"
  else
    printf -v "$__var" '%s' "0"
  fi
}

validate_port() {
  local p="$1"
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p >=1 && p <=65535 )); then return 0; else return 1; fi
}

# -------------------------
# 交互：逐项请求用户输入（覆盖默认）
# -------------------------
_info "进入交互配置模式（按回车使用默认值）。若想跳过交互并使用默认请以 -y 启动。"

ask MIRROR "选择镜像源 (default|cn|custom)" "$DEFAULT_MIRROR"
# 如果 custom，则进一步询问
if [[ "$MIRROR" == "custom" ]]; then
  ask CUSTOM_APT_URL "输入自定义 APT/DEB 源主机（例如：https://mirrors.example.com 或留空跳过）" ""
fi

ask SSH_PORT "输入 SSH 端口" "$DEFAULT_SSH_PORT"
if ! validate_port "$SSH_PORT"; then
  _warn "无效端口: $SSH_PORT，回退到默认 $DEFAULT_SSH_PORT"
  SSH_PORT="$DEFAULT_SSH_PORT"
fi

ask_yesno DISABLE_PWD "是否禁用 SSH 密码登录？(确保已有 authorized_keys 或可带外访问)" "y"
# DISABLE_PWD 已为 1/0

ask LOCALE_TARGET "系统语言 (locale), 例如 zh_CN.UTF-8" "$DEFAULT_LOCALE"
ask TIMEZONE "时区 (例如 Asia/Shanghai，留空跳过)" "$DEFAULT_TIMEZONE"

ask_yesno INSTALL_DOCKER "是否安装 Docker ?" "y"
ask PIP_MIRROR "pip 镜像策略 (auto|none|cn|custom)" "$DEFAULT_PIP_MIRROR"
if [[ "$PIP_MIRROR" == "custom" ]]; then
  ask CUSTOM_PIP_URL "输入自定义 pip 镜像 index-url (例如 https://pypi.example/simple)" ""
fi

ask_yesno DO_UPDATE "是否立即更新/升级系统（apt/dnf 等）？" "y"
ask_yesno DO_AUTOREMOVE "更新后是否执行 autoremove/cleanup ?" "y"

ask LOG_FILE "指定日志文件路径（绝对路径）" "$DEFAULT_LOG_FILE"
ask BACKUP_DIR "指定备份目录" "$DEFAULT_BACKUP_DIR"

ask_yesno I_KNOW "如果未发现 authorized_keys，是否仍强制禁用密码登录？（强烈不推荐，除非你有控制台/带外访问）" "n"

ask_yesno DRYRUN "是否启用 dry-run（仅打印将执行的命令，不真正修改）？" "n"
# 将 DRYRUN 转换为 1/0
if [[ "$DRYRUN" =~ ^(y|Y|yes|Yes|1)$ ]]; then DRYRUN=1; else DRYRUN=0; fi

_info "配置摘要："
echo "  MIRROR=$MIRROR"
[[ -n "${CUSTOM_APT_URL:-}" ]] && echo "  CUSTOM_APT_URL=$CUSTOM_APT_URL"
echo "  SSH_PORT=$SSH_PORT"
echo "  DISABLE_PWD=$DISABLE_PWD"
echo "  LOCALE_TARGET=$LOCALE_TARGET"
echo "  TIMEZONE=$TIMEZONE"
echo "  INSTALL_DOCKER=$INSTALL_DOCKER"
echo "  PIP_MIRROR=$PIP_MIRROR"
[[ -n "${CUSTOM_PIP_URL:-}" ]] && echo "  CUSTOM_PIP_URL=$CUSTOM_PIP_URL"
echo "  DO_UPDATE=$DO_UPDATE"
echo "  DO_AUTOREMOVE=$DO_AUTOREMOVE"
echo "  LOG_FILE=$LOG_FILE"
echo "  BACKUP_DIR=$BACKUP_DIR"
echo "  I_KNOW=$I_KNOW"
echo "  DRYRUN=$DRYRUN"

# 若非非交互，再次确认（以防误操作）
if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
  ask_yesno CONFIRM "确认以上设置并继续执行脚本？" "y"
  if [[ "$CONFIRM" -ne 1 ]]; then
    _info "用户取消执行。"
    exit 0
  fi
fi

# -------------------------
# 准备日志与备份目录（并重定向输出）
# -------------------------
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
# 重定向 stdout/stderr 到日志，同时保留在终端（tee）
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'ret=$?; if [[ $ret -ne 0 ]]; then echo "[ERR] 行 $LINENO 失败，退出码 $ret"; fi' ERR
trap 'echo "[INFO] 脚本结束，日志：'"$LOG_FILE"'' EXIT

log() { echo "[$(date +'%F %T')] $*"; }
run_cmd() {
  # safe runner: prints command, respects dry-run
  log "+ $*"
  if [[ "$DRYRUN" -eq 0 ]]; then
    bash -c "$*"
  else
    log "(dry-run) $*"
  fi
}

# -------------------------
# 系统识别与包管理器识别
# -------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
else
  _err "/etc/os-release 不存在，无法识别系统"
  exit 1
fi
DIST_ID="${ID:-unknown}"; DIST_LIKE="${ID_LIKE:-}"; DIST_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
PM=""
if command -v apt-get >/dev/null 2>&1; then PM="apt"
elif command -v dnf >/dev/null 2>&1; then PM="dnf"
elif command -v yum >/dev/null 2>&1; then PM="yum"
elif command -v zypper >/dev/null 2>&1; then PM="zypper"
elif command -v pacman >/dev/null 2>&1; then PM="pacman"
else
  _err "未检测到支持的包管理器 (apt/dnf/yum/zypper/pacman)。"
  exit 1
fi

SSH_SERVICE="sshd"
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then SSH_SERVICE="ssh"; fi

_info "检测到系统: ID=$DIST_ID VERSION=$DIST_VER CODENAME=$CODENAME PM=$PM"

# -------------------------
# 备份工具
# -------------------------
backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR"
    local base
    base="$(basename "$src")"
    run_cmd "cp -a '$src' '$BACKUP_DIR/${base}.bak.$TIMESTAMP'"
    echo "$BACKUP_DIR/${base}.bak.$TIMESTAMP"
  fi
}

# -------------------------
# 包管理抽象
# -------------------------
pm_update_upgrade() {
  case "$PM" in
    apt)
      run_cmd "apt-get update -y"
      if [[ "$DO_UPDATE" -eq 1 ]]; then
        run_cmd "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
        if [[ "$DO_AUTOREMOVE" -eq 1 ]]; then run_cmd "apt-get autoremove -y"; fi
      fi
      ;;
    dnf)
      run_cmd "dnf makecache -y || true"
      if [[ "$DO_UPDATE" -eq 1 ]]; then
        run_cmd "dnf upgrade -y"
        [[ "$DO_AUTOREMOVE" -eq 1 ]] && run_cmd "dnf autoremove -y || true"
      fi
      ;;
    yum)
      run_cmd "yum makecache -y || true"
      [[ "$DO_UPDATE" -eq 1 ]] && run_cmd "yum update -y"
      ;;
    zypper)
      run_cmd "zypper --non-interactive refresh"
      [[ "$DO_UPDATE" -eq 1 ]] && run_cmd "zypper --non-interactive update"
      ;;
    pacman)
      [[ "$DO_UPDATE" -eq 1 ]] && run_cmd "pacman -Syu --noconfirm"
      ;;
  esac
}

pm_install() {
  case "$PM" in
    apt) run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $*" ;;
    dnf) run_cmd "dnf install -y $*" ;;
    yum) run_cmd "yum install -y $*" ;;
    zypper) run_cmd "zypper --non-interactive install -y $*" ;;
    pacman) run_cmd "pacman -S --needed --noconfirm $*" ;;
  esac
}

# -------------------------
# APT 源 设置（如果 MIRROR=cn 或 custom）
# -------------------------
setup_apt_mirrors_cn() {
  [[ "$PM" != "apt" ]] && return 0
  local backup
  backup="$(backup_file /etc/apt/sources.list || true)"
  _info "切换 APT 源到国内镜像（TUNA/阿里）。"
  if [[ "$DIST_ID" == "ubuntu" ]]; then
    local host="mirrors.tuna.tsinghua.edu.cn"
    local code="${CODENAME:-$(lsb_release -cs 2>/dev/null || echo "")}"
    if [[ -z "$code" ]]; then code="focal"; _warn "无法推断 CODENAME，使用回退：$code"; fi
    cat >/etc/apt/sources.list <<EOF
deb https://$host/ubuntu/ $code main restricted universe multiverse
deb https://$host/ubuntu/ $code-updates main restricted universe multiverse
deb https://$host/ubuntu/ $code-backports main restricted universe multiverse
deb https://$host/ubuntu/ $code-security main restricted universe multiverse
EOF
  else
    local host="mirrors.tuna.tsinghua.edu.cn"
    local code="${CODENAME:-stable}"
    cat >/etc/apt/sources.list <<EOF
deb https://$host/debian/ $code main contrib non-free non-free-firmware
deb https://$host/debian/ $code-updates main contrib non-free non-free-firmware
deb https://$host/debian-security $code-security main contrib non-free non-free-firmware
EOF
  fi
  run_cmd "apt-get update -y || true"
}

setup_apt_mirrors_custom() {
  [[ "$PM" != "apt" ]] && return 0
  if [[ -z "${CUSTOM_APT_URL:-}" ]]; then
    _warn "未提供自定义 APT 主机，跳过 APT 源替换。"
    return 0
  fi
  backup_file /etc/apt/sources.list || true
  _info "设置自定义 APT 源，使用主机: $CUSTOM_APT_URL"
  # 适配 Ubuntu 与 Debian 常见 layout（保守写法）
  if [[ "$DIST_ID" == "ubuntu" ]]; then
    local code="${CODENAME:-$(lsb_release -cs 2>/dev/null || echo focal)}"
    cat >/etc/apt/sources.list <<EOF
deb $CUSTOM_APT_URL/ubuntu/ $code main restricted universe multiverse
deb $CUSTOM_APT_URL/ubuntu/ $code-updates main restricted universe multiverse
deb $CUSTOM_APT_URL/ubuntu/ $code-backports main restricted universe multiverse
deb $CUSTOM_APT_URL/ubuntu/ $code-security main restricted universe multiverse
EOF
  else
    local code="${CODENAME:-stable}"
    cat >/etc/apt/sources.list <<EOF
deb $CUSTOM_APT_URL/debian/ $code main contrib non-free non-free-firmware
deb $CUSTOM_APT_URL/debian/ $code-updates main contrib non-free non-free-firmware
deb $CUSTOM_APT_URL/debian-security $code-security main contrib non-free non-free-firmware
EOF
  fi
  run_cmd "apt-get update -y || true"
}

# -------------------------
# pip 镜像配置
# -------------------------
setup_pip_mirror() {
  local mode="$1"
  if [[ "$mode" == "auto" ]]; then
    if [[ "$MIRROR" == "cn" ]]; then mode="cn"; else mode="none"; fi
  fi
  case "$mode" in
    cn)
      _info "配置系统 pip 使用清华镜像 (/etc/pip.conf)."
      backup_file /etc/pip.conf || true
      cat >/etc/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
timeout = 30
EOF
      ;;
    custom)
      if [[ -z "${CUSTOM_PIP_URL:-}" ]]; then _warn "未提供 CUSTOM_PIP_URL，跳过 pip 配置"; return 0; fi
      backup_file /etc/pip.conf || true
      cat >/etc/pip.conf <<EOF
[global]
index-url = $CUSTOM_PIP_URL
timeout = 30
EOF
      ;;
    none)
      _info "保持 pip 默认镜像（不修改 /etc/pip.conf）。"
      ;;
    *)
      _warn "未知 pip 模式: $mode，跳过"
      ;;
  esac
}

# -------------------------
# Docker 安装与镜像配置
# -------------------------
install_docker() {
  [[ "$INSTALL_DOCKER" -eq 0 ]] && { _info "跳过 Docker 安装"; return 0; }
  _info "安装 Docker"
  # 确保 curl 存在
  if ! command -v curl >/dev/null 2>&1; then
    pm_install curl || true
  fi
  # 官方脚本（若网络受限可替换）
  if run_echo_and_exec "curl -fsSL https://get.docker.com | sh"; then
    _info "Docker 安装（官方脚本）完成或已存在"
  else
    _warn "官方脚本安装失败，尝试发行版包安装。"
    case "$PM" in
      apt) pm_install docker.io ;;
      dnf) pm_install docker docker-compose-plugin || pm_install moby-engine docker-compose-plugin || true ;;
      yum) pm_install docker docker-compose-plugin || true ;;
      zypper) pm_install docker docker-compose || true ;;
      pacman) pm_install docker docker-compose || true ;;
    esac
  fi
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd "systemctl enable --now docker || true"
  fi
  if id -u "${SUDO_USER:-}" >/dev/null 2>&1; then
    run_cmd "usermod -aG docker ${SUDO_USER}"
  fi
}

# helper to both log and run (used by Docker install path above)
run_echo_and_exec() {
  # run but return success/failure
  log "+ $*"
  if [[ "$DRYRUN" -eq 1 ]]; then
    log "(dry-run) $*"
    return 0
  else
    bash -c "$@"
    return $?
  fi
}

setup_docker_mirror() {
  [[ "$INSTALL_DOCKER" -eq 0 ]] && { _info "未安装 Docker，跳过 Docker 镜像配置"; return 0; }
  local daemon="/etc/docker/daemon.json"
  mkdir -p /etc/docker
  if [[ "$MIRROR" == "cn" ]]; then
    local mirrors_cn='["https://docker.nju.edu.cn","https://hub-mirror.c.163.com"]'
    _info "设置 docker registry mirrors 为国内镜像"
    backup_file "$daemon" || true
    if [[ -s "$daemon" ]]; then
      if command -v jq >/dev/null 2>&1; then
        tmp="$(mktemp)"
        jq --argjson m "$mirrors_cn" '. + {"registry-mirrors": $m}' "$daemon" >"$tmp" && run_cmd "mv '$tmp' '$daemon'" || _warn "jq 合并失败"
      else
        # 保守文本合并：若已有 registry-mirrors 则替换，否则插入
        if grep -q '"registry-mirrors"' "$daemon" 2>/dev/null; then
          run_cmd "sed -i 's/\"registry-mirrors\"[[:space:]]*:[[:space:]]*\\[[^]]*\\]/\"registry-mirrors\": $mirrors_cn/' '$daemon' || true"
        else
          tmp="$(mktemp)"
          awk -v add="  \"registry-mirrors\": $mirrors_cn" 'NR==1{first=1} {lines[NR]=$0} END{for(i=1;i<=NR;i++){ if(i==NR && lines[i] ~ /}/){ sub(/^[[:space:]]*}/, "", lines[i]); print lines[i] "\n" add "\n} else print lines[i]}}' "$daemon" >"$tmp" && run_cmd "mv '$tmp' '$daemon'" || _warn "无法自动合并 daemon.json，请手动检查"
        fi
      fi
    else
      cat >"$daemon" <<EOF
{
  "registry-mirrors": $mirrors_cn
}
EOF
    fi
    run_cmd "systemctl daemon-reload || true"
    run_cmd "systemctl restart docker || true"
  elif [[ "$MIRROR" == "custom" && -n "${CUSTOM_DOCKER_MIRRORS:-}" ]]; then
    # 用户提供自定义
    backup_file "$daemon" || true
    cat >"$daemon" <<EOF
{
  "registry-mirrors": $CUSTOM_DOCKER_MIRRORS
}
EOF
    run_cmd "systemctl daemon-reload || true"
    run_cmd "systemctl restart docker || true"
  else
    _info "未配置 Docker 镜像加速器"
  fi
}

# -------------------------
# SSH 配置（含安全检查）
# -------------------------
check_has_authorized_keys() {
  local has=0
  if [[ -s /root/.ssh/authorized_keys ]]; then has=1; fi
  while IFS=: read -r user _ uid _ home _; do
    if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$uid" -ge 1000 ]] && [[ -d "$home" ]] && [[ -s "$home/.ssh/authorized_keys" ]]; then
      has=1; break
    fi
  done < <(getent passwd)
  echo "$has"
}

configure_ssh() {
  _info "配置 SSH (端口=$SSH_PORT, 禁止密码=${DISABLE_PWD})"
  local conf="/etc/ssh/sshd_config"
  local dropdir="/etc/ssh/sshd_config.d"
  mkdir -p "$BACKUP_DIR"
  backup_file "$conf" || true

  # 安全检查：如果要禁用密码但未检测到 authorized_keys
  if [[ "$DISABLE_PWD" -eq 1 ]]; then
    local has_keys
    has_keys="$(check_has_authorized_keys)"
    if [[ "$has_keys" -eq 0 ]]; then
      if [[ "$I_KNOW" -eq 1 ]]; then
        _warn "未检测到 authorized_keys，但用户已选择强制禁用密码（I_KNOW=1），将继续。"
      else
        _warn "未检测到任何用户的 ~/.ssh/authorized_keys（含 root）。为避免被锁定，默认将保留密码登录。"
        _warn "若确认已配置密钥或可带外访问，请选择强制模式。"
        # 将 DISABLE_PWD 改为 0
        DISABLE_PWD=0
      fi
    fi
  fi

  local target="$conf"
  if [[ -d "$dropdir" ]]; then
    target="$dropdir/99-hardening.conf"
    mkdir -p "$dropdir"
  fi

  # 生成 drop-in 或直接覆盖（已备份）
  cat >"$target" <<EOF
# 由 base-bootstrap 管理 - 时间: $TIMESTAMP
Port $SSH_PORT
# PasswordAuthentication: no 禁止密码登录, yes 允许
PasswordAuthentication $( [[ "$DISABLE_PWD" -eq 1 ]] && echo no || echo yes )
ChallengeResponseAuthentication no
UsePAM yes
ClientAliveInterval 60
ClientAliveCountMax 10
# 若需允许 root 登录，可在此手动设置 PermitRootLogin yes/no
EOF

  # 验证 sshd 配置语法
  if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
    run_cmd "systemctl restart $SSH_SERVICE || true"
    run_cmd "systemctl enable $SSH_SERVICE || true"
    _ok "SSH 配置已应用并尝试重启 $SSH_SERVICE"
  else
    _err "sshd 配置语法检查失败。备份已存于 $BACKUP_DIR，请手动检查修复。"
    exit 1
  fi
}

# -------------------------
# locale / timezone 配置
# -------------------------
configure_locale() {
  _info "设置系统语言为: $LOCALE_TARGET"
  case "$PM" in
    apt)
      pm_install locales || true
      if [[ -f /etc/locale.gen ]]; then
        if grep -q "^# *$LOCALE_TARGET UTF-8" /etc/locale.gen 2>/dev/null; then
          run_cmd "sed -i 's/^# *$LOCALE_TARGET UTF-8/$LOCALE_TARGET UTF-8/' /etc/locale.gen"
        else
          grep -q "$LOCALE_TARGET UTF-8" /etc/locale.gen 2>/dev/null || run_cmd "bash -c \"echo '$LOCALE_TARGET UTF-8' >> /etc/locale.gen\""
        fi
        run_cmd "locale-gen || true"
        run_cmd "update-locale LANG=$LOCALE_TARGET || true"
      else
        _warn "/etc/locale.gen 不存在，跳过 locale-gen"
      fi
      ;;
    dnf|yum)
      pm_install glibc-langpack-zh || pm_install glibc-common || true
      run_cmd "localectl set-locale LANG=$LOCALE_TARGET || true"
      ;;
    zypper)
      pm_install glibc-locale || true
      run_cmd "localectl set-locale LANG=$LOCALE_TARGET || true"
      ;;
    pacman)
      if [[ -f /etc/locale.gen ]]; then
        if grep -q "^# *$LOCALE_TARGET" /etc/locale.gen 2>/dev/null; then
          run_cmd "sed -i 's/^# *$LOCALE_TARGET/$LOCALE_TARGET/' /etc/locale.gen"
        else
          run_cmd "bash -c \"echo '$LOCALE_TARGET' >> /etc/locale.gen\""
        fi
        run_cmd "locale-gen || true"
        run_cmd "localectl set-locale LANG=$LOCALE_TARGET || true"
      else
        _warn "/etc/locale.gen 不存在，跳过"
      fi
      ;;
  esac
}

configure_timezone() {
  if [[ -z "$TIMEZONE" ]]; then _info "未指定时区，跳过"; return 0; fi
  if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    _info "设置时区为 $TIMEZONE"
    run_cmd "timedatectl set-timezone '$TIMEZONE' || true"
  else
    _warn "时区文件 /usr/share/zoneinfo/$TIMEZONE 不存在，跳过"
  fi
}

# -------------------------
# 安装基础包（按发行版）
# -------------------------
install_base_packages() {
  case "$PM" in
    apt)
      pm_install ca-certificates curl git gnupg lsb-release software-properties-common locales openssh-server python3 python3-pip || true
      ;;
    dnf)
      pm_install ca-certificates curl git openssh-server python3 python3-pip || true
      ;;
    yum)
      if [[ "$DIST_ID" == "centos" && "${DIST_VER%%.*}" == "7" ]]; then
        pm_install epel-release || true
      fi
      pm_install ca-certificates curl git openssh-server python3 python3-pip || true
      ;;
    zypper)
      pm_install ca-certificates curl git openssh python3 python3-pip glibc-locale || true
      ;;
    pacman)
      pm_install ca-certificates curl git openssh python python-pip || true
      ;;
  esac
}

# -------------------------
# 回滚脚本生成（根据 BACKUP_DIR 中的备份）
# -------------------------
generate_rollback_script() {
  local rb="$BACKUP_DIR/rollback.sh"
  cat >"$rb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "开始回滚备份 (恢复 $BACKUP_DIR 中的文件到系统位置)"
BACKUP_DIR_PLACEHOLDER='"'"$BACKUP_DIR"'"'
for file in "$BACKUP_DIR_PLACEHOLDER"/*; do
  base=$(basename "$file")
  # 恢复命名规则: originalname.bak.TIMESTAMP
  orig="${base%%.bak.*}"
  if [[ -n "$orig" && -f "$file" ]]; then
    echo "恢复 $file -> /${orig}"
    cp -a "$file" "/${orig}"
  fi
done
echo "回滚完成。请重启相关服务或检查文件是否正确恢复."
EOF
  chmod +x "$rb"
  _info "回滚脚本已生成： $rb （根据备份恢复配置，请在恢复前检查脚本）"
}

# -------------------------
# 主执行流程（按照原脚本顺序）
# -------------------------
_info "开始基础环境初始化..."

# APT 源切换（交互决定）
if [[ "$MIRROR" == "cn" ]]; then
  if [[ "$PM" == "apt" ]]; then
    install_base_packages || true
    setup_apt_mirrors_cn
  else
    _warn "选择了 cn 镜像，但当前系统非 apt，跳过 apt 源切换。"
  fi
elif [[ "$MIRROR" == "custom" ]]; then
  if [[ "$PM" == "apt" ]]; then
    install_base_packages || true
    setup_apt_mirrors_custom
  else
    _warn "选择 custom 镜像，但当前系统非 apt，跳过 apt 源替换。"
  fi
else
  _info "保留默认镜像源"
fi

# 更新/升级
pm_update_upgrade

# 安装基础包
install_base_packages

# pip 镜像
setup_pip_mirror "$PIP_MIRROR"

# Docker 安装和镜像配置
if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
  install_docker
  setup_docker_mirror
else
  _info "用户选择不安装 Docker"
fi

# 启动并启用 SSH 服务（若 systemd 可用）
if command -v systemctl >/dev/null 2>&1; then
  run_cmd "systemctl enable --now $SSH_SERVICE || true"
else
  _warn "systemctl 不可用，跳过启用服务"
fi

# SSH 配置（慎重）
configure_ssh

# locale & timezone
configure_locale
configure_timezone

# 生成 rollback 脚本
generate_rollback_script

_ok "完成！请务必检查日志: $LOG_FILE"
_ok "备份与回滚脚本位于: $BACKUP_DIR"

# 完成提示：建议新开一个 SSH 会话测试更改（避免在当前会话中断开）
log "- 建议：在新的 SSH 窗口测试新的端口与免密登录是否可用。"
log "- 若修改了 docker 组，当前用户需重新登录会话以生效。"
log "- 若修改 locale，重新登录或重启以确保全局生效。"

exit 0