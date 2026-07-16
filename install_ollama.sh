#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_UI_LIB="${SCRIPT_DIR}/lib/ui.sh"
[[ -r "$PROJECT_UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$PROJECT_UI_LIB" >&2; exit 1; }
# shellcheck source=lib/ui.sh
source "$PROJECT_UI_LIB"

readonly SERVICE_NAME="ollama.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly CONFIG_DIR="/etc/ollama"
readonly CONFIG_FILE="${CONFIG_DIR}/installer.conf"

run_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'error "第 ${LINENO} 行执行失败，安装已中止。"' ERR

require_ubuntu() {
  [[ -r /etc/os-release ]] || die '无法识别操作系统。此脚本仅支持 Ubuntu。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || die "检测到 ${PRETTY_NAME:-未知系统}，此脚本仅支持 Ubuntu。"
  command -v systemctl >/dev/null 2>&1 || die '未检测到 systemd/systemctl。'
  [[ -t 0 ]] || die '需要在交互式终端中运行此脚本。'
}

ensure_privilege() {
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die '需要 root 权限，请安装 sudo 或以 root 运行。'
    info '后续安装步骤需要 sudo 权限。'
    sudo -v
  fi
}

resolve_target_user() {
  if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
    TARGET_USER=$SUDO_USER
  else
    TARGET_USER=$(id -un)
  fi
  local passwd_entry
  passwd_entry=$(getent passwd "$TARGET_USER") || die "无法读取用户 $TARGET_USER 的账户信息。"
  TARGET_HOME=$(cut -d: -f6 <<<"$passwd_entry")
  TARGET_GROUP=$(id -gn "$TARGET_USER")
  [[ -n "$TARGET_HOME" && "$TARGET_HOME" == /* ]] || die "用户 $TARGET_USER 的 HOME 目录无效。"
  USER_LOCAL_ROOT="${TARGET_HOME}/.local"
  GPU_COMMAND="${USER_LOCAL_ROOT}/bin/ollama_gpu_select"
  INSTALLED_UI_LIB="${USER_LOCAL_ROOT}/lib/ollama-scripts/ui.sh"
}

install_personal_dir() {
  local mode=$1 path=$2
  if (( EUID == 0 )); then
    install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m "$mode" "$path"
  else
    install -d -m "$mode" "$path"
  fi
}

install_personal_file() {
  local mode=$1 source=$2 target=$3
  if (( EUID == 0 )); then
    install -o "$TARGET_USER" -g "$TARGET_GROUP" -m "$mode" "$source" "$target"
  else
    install -m "$mode" "$source" "$target"
  fi
}

install_dependencies() {
  local required=(curl ca-certificates tar zstd) missing=() package
  for package in "${required[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || missing+=("$package")
  done
  if ((${#missing[@]} == 0)); then
    success '依赖检查通过：curl、ca-certificates、tar、zstd。'
    return
  fi
  warn "缺少依赖：${missing[*]}"
  confirm '是否使用 apt 安装缺失依赖？' Y || die '用户取消依赖安装。'
  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  success '依赖安装完成。'
}

load_previous_config() {
  PREVIOUS_INSTALL_DIR=''
  PREVIOUS_MODEL_DIR=''
  if [[ -f "$CONFIG_FILE" ]]; then
    local key value
    while IFS='=' read -r key value; do
      case "$key" in
        INSTALL_DIR) PREVIOUS_INSTALL_DIR=$value ;;
        MODEL_DIR) PREVIOUS_MODEL_DIR=$value ;;
      esac
    done < <(run_root cat "$CONFIG_FILE")
  fi
}

show_existing_installation() {
  local binary='' version='未知' service_state='未安装'
  binary=$(command -v ollama 2>/dev/null || true)
  if [[ -n "$binary" ]]; then
    version=$("$binary" --version 2>&1 | head -n 1 || true)
  fi
  if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    service_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  fi
  warn '检测到已有 Ollama 安装或服务：'
  info "命令路径：${binary:-未在 PATH 中找到}"
  info "版本信息：${version:-未知}"
  info "服务状态：${service_state:-未知}"
  [[ -n "$PREVIOUS_INSTALL_DIR" ]] && info "安装目录：$PREVIOUS_INSTALL_DIR"
  [[ -n "$PREVIOUS_MODEL_DIR" ]] && info "模型目录：$PREVIOUS_MODEL_DIR"
  printf '%b[选择]%b 1) 更新/重新安装  2) 退出\n' "$UI_CYAN" "$UI_RESET"
  local choice
  choice=$(ask '请选择' '2')
  [[ "$choice" == '1' ]] || { info '未修改现有安装。'; exit 0; }
}

validate_path() {
  local path=$1 label=$2
  [[ "$path" == /* ]] || die "$label必须是绝对路径。"
  [[ "$path" != '/' ]] || die "$label不能是根目录 /。"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die "$label包含非法换行符。"
  [[ "$path" != *'$'* ]] || die "$label不能包含 \$，以免与 systemd 变量展开冲突。"
}

validate_model_path() {
  local path=$1
  case "$path" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die '模型目录不能直接使用系统顶层目录，请至少指定一个子目录。'
      ;;
  esac
}

choose_paths() {
  local default_install=${PREVIOUS_INSTALL_DIR:-/usr/local}
  local default_model=${PREVIOUS_MODEL_DIR:-/var/lib/ollama/models}
  INSTALL_DIR=$(ask 'Ollama 安装前缀目录' "$default_install")
  MODEL_DIR=$(ask '模型下载存储目录' "$default_model")
  INSTALL_DIR=${INSTALL_DIR%/}
  MODEL_DIR=${MODEL_DIR%/}
  validate_path "$INSTALL_DIR" '安装目录'
  validate_path "$MODEL_DIR" '模型目录'
  validate_model_path "$MODEL_DIR"
  [[ "$INSTALL_DIR" != "$MODEL_DIR" ]] || die '安装目录和模型目录不能相同。'
  info "程序将安装到：${INSTALL_DIR}/bin/ollama"
  info "模型将存储到：${MODEL_DIR}"
  confirm '确认使用以上路径？' Y || die '用户取消安装。'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) OLLAMA_ARCH='amd64' ;;
    aarch64|arm64) OLLAMA_ARCH='arm64' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

ensure_service_user() {
  if ! getent group ollama >/dev/null; then
    run_root groupadd --system ollama
  fi
  if ! id ollama >/dev/null 2>&1; then
    run_root useradd --system --gid ollama --home-dir /var/lib/ollama --create-home --shell /usr/sbin/nologin ollama
  fi
  run_root install -d -o ollama -g ollama -m 0750 /var/lib/ollama
  local group
  for group in render video; do
    getent group "$group" >/dev/null && run_root usermod -aG "$group" ollama
  done
}

download_and_install() {
  local archive="${TEMP_DIR}/ollama-linux-${OLLAMA_ARCH}.tar.zst"
  local url="https://ollama.com/download/ollama-linux-${OLLAMA_ARCH}.tar.zst"
  step '下载并安装 Ollama'
  info "下载地址：$url"
  curl --fail --location --progress-bar --output "$archive" "$url"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info '停止现有 Ollama 服务以安全更新程序文件。'
    run_root systemctl stop "$SERVICE_NAME"
  fi
  run_root install -d -m 0755 "$INSTALL_DIR"
  if [[ -d "${INSTALL_DIR}/lib/ollama" ]]; then
    info '清理安装目录中的旧版运行库。'
    run_root rm -rf -- "${INSTALL_DIR}/lib/ollama"
  fi
  zstd -dc -- "$archive" | run_root tar -xf - -C "$INSTALL_DIR"
  [[ -x "${INSTALL_DIR}/bin/ollama" ]] || die '压缩包解压后未找到 bin/ollama。'

  run_root install -d -m 0755 /usr/local/bin
  if [[ "${INSTALL_DIR}/bin/ollama" != '/usr/local/bin/ollama' ]]; then
    run_root ln -sfn "${INSTALL_DIR}/bin/ollama" /usr/local/bin/ollama
  fi
  success 'Ollama 程序文件安装完成。'
}

systemd_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\%/%%}
  printf '%s' "$value"
}

write_service() {
  local service_tmp="${TEMP_DIR}/ollama.service"
  local exec_path model_path
  exec_path=$(systemd_escape "${INSTALL_DIR}/bin/ollama")
  model_path=$(systemd_escape "$MODEL_DIR")
  ensure_service_user
  run_root install -d -o ollama -g ollama -m 0750 "$MODEL_DIR"
  run_root chown -R ollama:ollama "$MODEL_DIR"
  cat >"$service_tmp" <<EOF
[Unit]
Description=Ollama Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart="${exec_path}" serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="HOME=/var/lib/ollama"
Environment="OLLAMA_MODELS=${model_path}"

[Install]
WantedBy=multi-user.target
EOF
  run_root install -o root -g root -m 0644 "$service_tmp" "$SERVICE_FILE"
  run_root systemctl daemon-reload
  run_root systemctl enable --now "$SERVICE_NAME"
  success 'systemd 服务已创建并启动。'
}

write_gpu_command() {
  local gpu_tmp="${TEMP_DIR}/ollama_gpu_select"
  cat >"$gpu_tmp" <<'GPU_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UI_LIB="${SCRIPT_DIR%/bin}/lib/ollama-scripts/ui.sh"
[[ -r "$UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$UI_LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$UI_LIB"

SERVICE='ollama.service'
DROPIN_DIR='/etc/systemd/system/ollama.service.d'
DROPIN_FILE="${DROPIN_DIR}/gpu.conf"
root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

[[ -t 0 ]] || die '请在交互式终端中运行。'
systemctl cat "$SERVICE" >/dev/null 2>&1 || die '未找到 ollama.service，请先运行安装脚本。'
command -v nvidia-smi >/dev/null 2>&1 || die '未找到 nvidia-smi，无法枚举 NVIDIA GPU。'
mapfile -t GPUS < <(nvidia-smi --query-gpu=index,name,uuid --format=csv,noheader 2>/dev/null)
((${#GPUS[@]} > 0)) || die '未检测到可用的 NVIDIA GPU。'

printf '%b[GPU 列表]%b\n' "$UI_CYAN" "$UI_RESET"
for gpu in "${GPUS[@]}"; do printf '  %s\n' "$gpu"; done
printf '%b[选择]%b 输入逗号分隔的 GPU 编号（如 0,2），a=全部 GPU，c=强制 CPU\n' "$UI_CYAN" "$UI_RESET"
printf '%b[输入]%b 请选择 [a]: ' "$UI_CYAN" "$UI_RESET" >&2
IFS= read -r selection
selection=${selection:-a}

if [[ "$selection" =~ ^[Aa]$ ]]; then
  root rm -f -- "$DROPIN_FILE"
  info '已清除 CUDA_VISIBLE_DEVICES 限制，将允许 Ollama 使用全部 GPU。'
elif [[ "$selection" =~ ^[Cc]$ ]]; then
  value='-1'
else
  value=${selection//[[:space:]]/}
  [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]] || die '格式无效，请输入 a、c 或逗号分隔的 GPU 编号。'
  IFS=',' read -ra selected_ids <<<"$value"
  for id in "${selected_ids[@]}"; do
    found=0
    for gpu in "${GPUS[@]}"; do
      gpu_index=${gpu%%,*}
      gpu_index=${gpu_index//[[:space:]]/}
      [[ "$id" == "$gpu_index" ]] && found=1
    done
    ((found == 1)) || die "GPU 编号 $id 不存在。"
  done
fi

if [[ ! "$selection" =~ ^[Aa]$ ]]; then
  tmp=$(mktemp)
  trap 'rm -f -- "$tmp"' EXIT
  printf '[Service]\nEnvironment="CUDA_VISIBLE_DEVICES=%s"\n' "$value" >"$tmp"
  root install -d -o root -g root -m 0755 "$DROPIN_DIR"
  root install -o root -g root -m 0644 "$tmp" "$DROPIN_FILE"
  [[ "$value" == '-1' ]] && warn '已配置为强制使用 CPU。' || info "CUDA_VISIBLE_DEVICES=$value"
fi

root systemctl daemon-reload
root systemctl restart "$SERVICE"
if systemctl is-active --quiet "$SERVICE"; then
  ok 'GPU 设置已生效，Ollama 服务已重启。'
else
  die '服务重启失败，请运行 journalctl -u ollama -n 50 查看日志。'
fi
GPU_SCRIPT
  install_personal_dir 0755 "$USER_LOCAL_ROOT"
  install_personal_dir 0755 "${USER_LOCAL_ROOT}/bin"
  install_personal_dir 0755 "${USER_LOCAL_ROOT}/lib"
  install_personal_dir 0755 "${USER_LOCAL_ROOT}/lib/ollama-scripts"
  install_personal_file 0644 "$PROJECT_UI_LIB" "$INSTALLED_UI_LIB"
  install_personal_file 0755 "$gpu_tmp" "$GPU_COMMAND"
  success "GPU 选择命令已安装到用户 $TARGET_USER：$GPU_COMMAND"
  if [[ ":${PATH}:" != *":${USER_LOCAL_ROOT}/bin:"* ]]; then
    warn "${USER_LOCAL_ROOT}/bin 不在当前 PATH 中；可将 export PATH=\"\$HOME/.local/bin:\$PATH\" 加入 shell 配置。"
  fi
}

save_config() {
  local config_tmp="${TEMP_DIR}/installer.conf"
  {
    printf '# Generated by install_ollama.sh; one KEY=VALUE entry per line.\n'
    printf 'INSTALL_DIR=%s\n' "$INSTALL_DIR"
    printf 'MODEL_DIR=%s\n' "$MODEL_DIR"
    printf 'COMMAND_USER=%s\n' "$TARGET_USER"
    printf 'GPU_COMMAND=%s\n' "$GPU_COMMAND"
    printf 'INSTALLED_UI_LIB=%s\n' "$INSTALLED_UI_LIB"
  } >"$config_tmp"
  run_root install -d -o root -g root -m 0755 "$CONFIG_DIR"
  run_root install -o root -g root -m 0600 "$config_tmp" "$CONFIG_FILE"
}

print_summary() {
  local version service_state
  version=$("${INSTALL_DIR}/bin/ollama" --version 2>&1 | head -n 1 || true)
  service_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  step '安装结果'
  success "版本：${version:-已安装}"
  success "服务状态：${service_state:-未知}"
  info "程序目录：$INSTALL_DIR"
  info "模型目录：$MODEL_DIR"
  info "选择 NVIDIA GPU：$GPU_COMMAND"
  info '查看服务日志：journalctl -u ollama -f'
}

main() {
  step '环境检查'
  require_ubuntu
  ensure_privilege
  resolve_target_user
  load_previous_config
  if command -v ollama >/dev/null 2>&1 || systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || [[ -n "$PREVIOUS_INSTALL_DIR" ]]; then
    show_existing_installation
  else
    info '未检测到已有 Ollama 安装，将开始全新安装。'
  fi
  install_dependencies
  choose_paths
  detect_arch
  TEMP_DIR=$(mktemp -d)
  download_and_install
  step '配置服务与辅助命令'
  write_service
  write_gpu_command
  save_config
  print_summary
}

main "$@"
