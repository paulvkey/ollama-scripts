#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_UI_LIB="${SCRIPT_DIR}/lib/ui.sh"
[[ -r "$PROJECT_UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$PROJECT_UI_LIB" >&2; exit 1; }
# shellcheck source=lib/ui.sh
source "$PROJECT_UI_LIB"

readonly SERVICE_NAME='ollama.service'
INSTALL_SCOPE=''

run_admin() {
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo "$@"; else "$@"; fi
}

service_systemctl() {
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    run_admin systemctl "$@"
  else
    systemctl --user "$@"
  fi
}

choose_install_scope() {
  printf '%b[安装范围]%b 1) 当前用户安装（无需 sudo）  2) 系统级安装（需要 sudo，所有用户可用）\n' "$UI_CYAN" "$UI_RESET"
  local choice
  choice=$(ask '请选择安装范围' '1')
  case "$choice" in
    1) INSTALL_SCOPE='user' ;;
    2) INSTALL_SCOPE='system' ;;
    *) die '无效选择，请输入 1 或 2。' ;;
  esac
}

configure_scope() {
  USER_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
  USER_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
  USER_LOCAL_ROOT="${HOME}/.local"
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    command -v sudo >/dev/null 2>&1 || die '系统级安装需要 sudo，但当前未找到 sudo。'
    (( EUID != 0 )) || die '请使用普通用户运行脚本并在交互中选择系统级安装，不要直接使用 root。'
    info '系统级安装需要验证 sudo 权限。'
    sudo -v
    CONFIG_DIR='/etc/ollama-scripts'
    CONFIG_FILE="${CONFIG_DIR}/installer.conf"
    SYSTEMD_DIR='/etc/systemd/system'
    SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}"
    COMMAND_ROOT='/usr/local'
    DATA_ROOT='/var/lib'
  else
    (( EUID != 0 )) || die '当前用户安装不能使用 root。'
    USER_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
    USER_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
    CONFIG_DIR="${USER_CONFIG_HOME}/ollama-scripts"
    CONFIG_FILE="${CONFIG_DIR}/installer.conf"
    SYSTEMD_DIR="${USER_CONFIG_HOME}/systemd/user"
    SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}"
    COMMAND_ROOT="${HOME}/.local"
    DATA_ROOT="$USER_DATA_HOME"
  fi
  OLLAMA_COMMAND="${COMMAND_ROOT}/bin/ollama"
  GPU_COMMAND="${COMMAND_ROOT}/bin/ollama_gpu_select"
  PORT_COMMAND="${COMMAND_ROOT}/bin/ollama_port_select"
  INSTALLED_UI_LIB="${COMMAND_ROOT}/lib/ollama-scripts/ui.sh"
  SERVICE_CTL="${COMMAND_ROOT}/lib/ollama-scripts/service_ctl.sh"
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'error "第 ${LINENO} 行执行失败，安装已中止。"' ERR

ensure_dir() {
  local mode=$1 path=$2
  [[ -d "$path" ]] || run_admin install -d -m "$mode" "$path"
}

require_environment() {
  [[ -t 0 ]] || die '需要在交互式终端中运行此脚本。'
  [[ -r /etc/os-release ]] || die '无法识别操作系统。此脚本仅支持 Ubuntu。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || die "检测到 ${PRETTY_NAME:-未知系统}，此脚本仅支持 Ubuntu。"
  [[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" && -w "$HOME" ]] || die '当前 HOME 目录不可写。'

  local missing=() command
  for command in curl install tar zstd systemctl; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  if ((${#missing[@]} > 0)); then
    error "缺少依赖：${missing[*]}"
    if [[ "$INSTALL_SCOPE" == 'system' ]]; then
      confirm '是否使用 apt 安装所需依赖？' Y || die '用户取消依赖安装。'
      run_admin apt-get update
      run_admin env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar zstd coreutils systemd
    else
      die '无 sudo 模式无法安装系统依赖，请联系管理员安装上述缺失命令。'
    fi
  fi
  success '依赖检查通过：curl、install、tar、zstd、systemctl。'

  if [[ "$INSTALL_SCOPE" == 'user' ]]; then
    systemctl --user show-environment >/dev/null 2>&1 || die '无法连接用户级 systemd。请在正常登录会话中运行，并确认 user manager 可用。'
  fi
}

load_previous_config() {
  PREVIOUS_INSTALL_DIR=''
  PREVIOUS_MODEL_DIR=''
  PREVIOUS_PORT=''
  if run_admin test -e "$CONFIG_FILE"; then
    local key value
    while IFS='=' read -r key value; do
      case "$key" in
        INSTALL_DIR) PREVIOUS_INSTALL_DIR=$value ;;
        MODEL_DIR) PREVIOUS_MODEL_DIR=$value ;;
        OLLAMA_PORT) PREVIOUS_PORT=$value ;;
      esac
    done < <(run_admin cat "$CONFIG_FILE")
    [[ -n "$PREVIOUS_INSTALL_DIR" && -z "$PREVIOUS_PORT" ]] && PREVIOUS_PORT='11434'
    if [[ -n "$PREVIOUS_PORT" ]] && { [[ ! "$PREVIOUS_PORT" =~ ^[0-9]+$ || ${#PREVIOUS_PORT} -gt 5 ]] || ((10#$PREVIOUS_PORT < 1024 || 10#$PREVIOUS_PORT > 65535)); }; then
      warn "安装记录中的端口 $PREVIOUS_PORT 无效，将忽略。"
      PREVIOUS_PORT=''
    fi
  fi
}

check_system_service_conflict() {
  [[ "$INSTALL_SCOPE" == 'user' ]] || return 0
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    warn '检测到系统级 ollama.service 正在运行；请选择未被它占用的端口。'
  elif systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    warn '检测到系统级 ollama.service，但当前未运行；本脚本不会修改它。'
  fi
}

show_existing_installation() {
  local binary='' version='未知' service_state='未安装'
  if [[ -x "${OLLAMA_COMMAND:-}" ]]; then
    binary=$OLLAMA_COMMAND
  else
    binary=$(command -v ollama 2>/dev/null || true)
  fi
  if [[ -n "$binary" ]]; then
    version=$("$binary" --version 2>&1 | head -n 1 || true)
  fi
  if service_systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    service_state=$(service_systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  fi
  warn '检测到已有 Ollama 命令、用户服务或安装记录：'
  info "命令路径：${binary:-未在 PATH 中找到}"
  info "版本信息：${version:-未知}"
  info "用户服务状态：${service_state:-未知}"
  [[ -n "$PREVIOUS_INSTALL_DIR" ]] && info "安装目录：$PREVIOUS_INSTALL_DIR"
  [[ -n "$PREVIOUS_MODEL_DIR" ]] && info "模型目录：$PREVIOUS_MODEL_DIR"
  [[ -n "$PREVIOUS_PORT" ]] && info "监听地址：127.0.0.1:$PREVIOUS_PORT"
  printf '%b[选择]%b 1) 更新/重新安装用户级 Ollama  2) 退出\n' "$UI_CYAN" "$UI_RESET"
  local choice
  choice=$(ask '请选择' '2')
  [[ "$choice" == '1' ]] || { info '未修改现有安装。'; exit 0; }
}

port_is_open() {
  local port=$1
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

port_is_available() {
  local port=$1
  if [[ "$port" == "$PREVIOUS_PORT" ]] && service_systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    return 0
  fi
  ! port_is_open "$port"
}

pick_random_port() {
  local candidate attempts
  for ((attempts = 0; attempts < 10; attempts++)); do
    candidate=$((20000 + (((RANDOM << 15) | RANDOM) % 40001)))
    if port_is_available "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

choose_port() {
  local choice custom_port default_choice='1' previous_option=''
  if [[ -n "$PREVIOUS_PORT" ]]; then
    default_choice='4'
    previous_option="  4) 保持原端口 ${PREVIOUS_PORT}"
  fi
  while true; do
    printf '%b[端口]%b 1) 默认端口 11434  2) 随机可用端口  3) 自定义端口%s\n' "$UI_CYAN" "$UI_RESET" "$previous_option"
    choice=$(ask '请选择端口方式' "$default_choice")
    case "$choice" in
      1)
        OLLAMA_PORT='11434'
        ;;
      2)
        OLLAMA_PORT=$(pick_random_port) || die '尝试 10 次后仍未找到可用随机端口。'
        ;;
      3)
        custom_port=$(ask '请输入 1024-65535 之间的端口')
        if [[ ! "$custom_port" =~ ^[0-9]+$ || ${#custom_port} -gt 5 ]] || ((10#$custom_port < 1024 || 10#$custom_port > 65535)); then
          warn '端口无效，普通用户只能选择 1024-65535。'
          continue
        fi
        OLLAMA_PORT=$((10#$custom_port))
        ;;
      4)
        if [[ -z "$PREVIOUS_PORT" ]]; then
          warn '没有可保留的原端口。'
          continue
        fi
        OLLAMA_PORT=$PREVIOUS_PORT
        ;;
      *)
        warn '无效选择，请输入菜单中的编号。'
        continue
        ;;
    esac
    if ! port_is_available "$OLLAMA_PORT"; then
      warn "端口 $OLLAMA_PORT 已被占用，请重新选择。"
      continue
    fi
    info "Ollama 将绑定到：127.0.0.1:$OLLAMA_PORT"
    info '端口已确认，安装完成后脚本会自动启动 Ollama 服务，无需手动执行 ollama_start。'
    return 0
  done
}

validate_path() {
  local path=$1 label=$2 parent
  [[ "$path" == /* ]] || die "$label必须是绝对路径。"
  [[ "$path" != '/' ]] || die "$label不能是根目录 /。"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die "$label包含非法换行符。"
  [[ "$path" != *'$'* ]] || die "$label不能包含 \$，以免与 systemd 变量展开冲突。"
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    case "$path" in
      /home/*|/root|/root/*)
        die "系统级安装的${label}不能位于个人 HOME 下，否则其他用户或 ollama 服务账户可能无法访问。"
        ;;
    esac
  fi
  parent=$path
  while [[ ! -e "$parent" ]]; do
    parent=$(dirname -- "$parent")
  done
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    run_admin test -d "$parent" || die "$label的现有父路径 $parent 不是目录。"
  else
    [[ -d "$parent" && -w "$parent" ]] || die "$label的现有父目录 $parent 不可写。"
  fi
  [[ ! -e "$path" || -d "$path" ]] || die "$label已存在但不是目录。"
  if [[ "$INSTALL_SCOPE" == 'user' ]]; then
    [[ ! -d "$path" || -w "$path" ]] || die "$label不可写。"
  fi
}

validate_model_path() {
  local path=$1
  case "$path" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die '模型目录不能直接使用系统顶层目录，请至少指定一个子目录。'
      ;;
  esac
  case "$path" in
    "$HOME"|"$USER_LOCAL_ROOT"|"$USER_CONFIG_HOME"|"$USER_DATA_HOME")
      die '模型目录不能直接使用 HOME 或用户数据/配置顶层目录，请至少指定一个子目录。'
      ;;
  esac
}

choose_paths() {
  local default_install=${PREVIOUS_INSTALL_DIR:-$COMMAND_ROOT}
  local default_model=${PREVIOUS_MODEL_DIR:-${DATA_ROOT}/ollama/models}
  INSTALL_DIR=$(ask 'Ollama 安装前缀目录' "$default_install")
  MODEL_DIR=$(ask '模型下载存储目录' "$default_model")
  [[ "$INSTALL_DIR" == '/' ]] || INSTALL_DIR=${INSTALL_DIR%/}
  [[ "$MODEL_DIR" == '/' ]] || MODEL_DIR=${MODEL_DIR%/}
  validate_path "$INSTALL_DIR" '安装目录'
  validate_path "$MODEL_DIR" '模型目录'
  validate_model_path "$MODEL_DIR"
  [[ "$INSTALL_DIR" != "$MODEL_DIR" ]] || die '安装目录和模型目录不能相同。'
  case "${MODEL_DIR}/" in
    "${INSTALL_DIR}/bin/"*|"${INSTALL_DIR}/lib/ollama/"*)
      die '模型目录不能位于 Ollama 程序或运行库目录内。'
      ;;
  esac
  info "实际程序将安装到：${INSTALL_DIR}/bin/ollama.bin"
  info "模型将存储到：${MODEL_DIR}"
  info "服务将写入：$SERVICE_FILE"
  if [[ -n "$PREVIOUS_INSTALL_DIR" && "$PREVIOUS_INSTALL_DIR" != "$INSTALL_DIR" ]]; then
    warn "安装前缀已变更；旧目录 $PREVIOUS_INSTALL_DIR 不会自动删除。"
  fi
  confirm '确认使用以上用户级配置？' Y || die '用户取消安装。'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) OLLAMA_ARCH='amd64' ;;
    aarch64|arm64) OLLAMA_ARCH='arm64' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

download_and_install() {
  local archive="${TEMP_DIR}/ollama-linux-${OLLAMA_ARCH}.tar.zst"
  local url="https://ollama.com/download/ollama-linux-${OLLAMA_ARCH}.tar.zst"
  local actual_binary="${INSTALL_DIR}/bin/ollama.bin"
  local wrapper_tmp="${TEMP_DIR}/ollama-wrapper"
  step '下载并安装 Ollama'
  info "下载地址：$url"
  curl --fail --location --progress-bar --output "$archive" "$url"
  if service_systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info '停止现有 Ollama 服务以安全更新程序文件。'
    service_systemctl stop "$SERVICE_NAME"
  fi
  ensure_dir 0755 "$INSTALL_DIR"
  if [[ -d "${INSTALL_DIR}/lib/ollama" ]]; then
    info '清理安装目录中的旧版运行库。'
    run_admin rm -rf -- "${INSTALL_DIR}/lib/ollama"
  fi
  zstd -dc -- "$archive" | run_admin tar --no-same-owner -xf - -C "$INSTALL_DIR"
  [[ -x "${INSTALL_DIR}/bin/ollama" ]] || die '压缩包解压后未找到 bin/ollama。'
  run_admin mv -f -- "${INSTALL_DIR}/bin/ollama" "$actual_binary"

  ensure_dir 0755 "${COMMAND_ROOT}/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:%s}"\n' "$OLLAMA_PORT"
    printf 'exec %q "$@"\n' "$actual_binary"
  } >"$wrapper_tmp"
  run_admin rm -f -- "$OLLAMA_COMMAND"
  run_admin install -m 0755 "$wrapper_tmp" "$OLLAMA_COMMAND"
  success 'Ollama 用户级程序文件安装完成。'
}

systemd_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\%/%%}
  printf '%s' "$value"
}

write_service() {
  local service_tmp="${TEMP_DIR}/ollama.service" exec_path model_path home_path service_identity wanted_target gpu_group
  exec_path=$(systemd_escape "${INSTALL_DIR}/bin/ollama.bin")
  model_path=$(systemd_escape "$MODEL_DIR")
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    home_path='/var/lib/ollama'
    wanted_target='multi-user.target'
  else
    home_path=$(systemd_escape "$HOME")
    wanted_target='default.target'
  fi
  ensure_dir 0750 "$MODEL_DIR"
  ensure_dir 0755 "$SYSTEMD_DIR"
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    if ! getent group ollama >/dev/null; then run_admin groupadd --system ollama; fi
    if ! id ollama >/dev/null 2>&1; then
      run_admin useradd --system --gid ollama --home-dir /var/lib/ollama --create-home --shell /usr/sbin/nologin ollama
    fi
    run_admin install -d -o ollama -g ollama -m 0750 /var/lib/ollama
    for gpu_group in render video; do
      getent group "$gpu_group" >/dev/null && run_admin usermod -aG "$gpu_group" ollama
    done
    run_admin chown -R ollama:ollama "$MODEL_DIR"
    service_identity=$'User=ollama\nGroup=ollama'
  else
    service_identity=''
  fi
  cat >"$service_tmp" <<EOF
[Unit]
Description=Ollama User Service

[Service]
Type=simple
ExecStart="${exec_path}" serve
${service_identity}
Restart=always
RestartSec=3
Environment="HOME=${home_path}"
Environment="OLLAMA_MODELS=${model_path}"
Environment="OLLAMA_HOST=127.0.0.1:${OLLAMA_PORT}"
Environment="OLLAMA_GPU=all"
Environment="OLLAMA_VULKAN=false"
Environment="OLLAMA_FLASH_ATTENTION=1"

[Install]
WantedBy=${wanted_target}
EOF
  run_admin install -m 0644 "$service_tmp" "$SERVICE_FILE"
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    run_admin rm -f -- /etc/systemd/system/ollama.service.d/port.conf
  else
    rm -f -- "${USER_CONFIG_HOME}/systemd/user/ollama.service.d/port.conf"
  fi
  service_systemctl daemon-reload
  service_systemctl enable --now "$SERVICE_NAME"
  success 'Ollama systemd 服务已创建并启动。'
}

write_gpu_command() {
  local gpu_tmp="${TEMP_DIR}/ollama_gpu_select"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nINSTALL_SCOPE=%q\n' "$INSTALL_SCOPE"
    cat <<'GPU_SCRIPT'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UI_LIB="${SCRIPT_DIR%/bin}/lib/ollama-scripts/ui.sh"
[[ -r "$UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$UI_LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$UI_LIB"

SERVICE='ollama.service'
if [[ "$INSTALL_SCOPE" == 'system' ]]; then
  DROPIN_DIR='/etc/systemd/system/ollama.service.d'
else
  DROPIN_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/ollama.service.d"
fi
DROPIN_FILE="${DROPIN_DIR}/gpu.conf"
root() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo "$@"; else "$@"; fi; }
svc() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo systemctl "$@"; else systemctl --user "$@"; fi; }

[[ -t 0 ]] || die '请在交互式终端中运行。'
svc cat "$SERVICE" >/dev/null 2>&1 || die '未找到 ollama.service，请先运行安装脚本。'
cuda_value=''
parallel_value='1'
if root test -e "$DROPIN_FILE"; then
  while IFS= read -r config_line; do
    case "$config_line" in
      *CUDA_VISIBLE_DEVICES=*)
        cuda_value=${config_line#*CUDA_VISIBLE_DEVICES=}
        cuda_value=${cuda_value%\"}
        ;;
      *OLLAMA_NUM_PARALLEL=*)
        parallel_value=${config_line#*OLLAMA_NUM_PARALLEL=}
        parallel_value=${parallel_value%\"}
        ;;
    esac
  done < <(root cat "$DROPIN_FILE")
fi

show_current_settings() {
  if [[ -z "$cuda_value" ]]; then
    info '当前 GPU 设置：全部可见的 NVIDIA GPU'
  elif [[ "$cuda_value" == '-1' ]]; then
    info '当前 GPU 设置：强制使用 CPU'
  else
    info "当前 CUDA_VISIBLE_DEVICES=$cuda_value"
  fi
  info "当前 OLLAMA_NUM_PARALLEL=$parallel_value"
}

choose_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 || die '未找到 nvidia-smi，无法执行 GPU 选择；仍可单独设置 OLLAMA_NUM_PARALLEL。'
  mapfile -t GPUS < <(nvidia-smi --query-gpu=index,name,uuid --format=csv,noheader 2>/dev/null)
  ((${#GPUS[@]} > 0)) || die '未检测到可用的 NVIDIA GPU。'
  printf '%b[GPU 列表]%b\n' "$UI_CYAN" "$UI_RESET"
  for gpu in "${GPUS[@]}"; do printf '  %s\n' "$gpu"; done
  printf '%b[GPU 选择]%b 输入逗号分隔的 GPU 编号（如 0,2），a=全部 GPU，c=强制 CPU\n' "$UI_CYAN" "$UI_RESET"
  local selection id found gpu gpu_index
  selection=$(ask '请选择 GPU' 'a')
  if [[ "$selection" =~ ^[Aa]$ ]]; then
    cuda_value=''
  elif [[ "$selection" =~ ^[Cc]$ ]]; then
    cuda_value='-1'
  else
    cuda_value=${selection//[[:space:]]/}
    [[ "$cuda_value" =~ ^[0-9]+(,[0-9]+)*$ ]] || die 'GPU 格式无效。'
    IFS=',' read -ra selected_ids <<<"$cuda_value"
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
}

choose_parallel() {
  info 'OLLAMA_NUM_PARALLEL 表示每个模型同时处理的最大请求数；数值越高并发吞吐可能越高，但会占用更多显存或内存。'
  printf '%b[并行数]%b 1) 1（默认）  2) 2  3) 4  4) 自定义\n' "$UI_CYAN" "$UI_RESET"
  local parallel_choice
  parallel_choice=$(ask '请选择 OLLAMA_NUM_PARALLEL' '1')
  case "$parallel_choice" in
    1) parallel_value='1' ;;
    2) parallel_value='2' ;;
    3) parallel_value='4' ;;
    4)
      parallel_value=$(ask '请输入 1-128 之间的并行请求数')
      [[ "$parallel_value" =~ ^[0-9]+$ && ${#parallel_value} -le 3 ]] || die '并行请求数格式无效。'
      ((10#$parallel_value >= 1 && 10#$parallel_value <= 128)) || die '并行请求数必须在 1-128 之间。'
      parallel_value=$((10#$parallel_value))
      ;;
    *) die '无效选择，请输入 1、2、3 或 4。' ;;
  esac
}

show_current_settings
printf '%b[操作]%b 1) 仅选择 GPU  2) 仅设置 OLLAMA_NUM_PARALLEL  3) 同时配置两项\n' "$UI_CYAN" "$UI_RESET"
operation=$(ask '请选择操作' '1')
case "$operation" in
  1) choose_gpu ;;
  2) choose_parallel ;;
  3) choose_gpu; choose_parallel ;;
  *) die '无效选择，请输入 1、2 或 3。' ;;
esac

tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT
printf '[Service]\n' >"$tmp"
[[ -n "$cuda_value" ]] && printf 'Environment="CUDA_VISIBLE_DEVICES=%s"\n' "$cuda_value" >>"$tmp"
printf 'Environment="OLLAMA_NUM_PARALLEL=%s"\n' "$parallel_value" >>"$tmp"
root install -d -m 0755 "$DROPIN_DIR"
root install -m 0644 "$tmp" "$DROPIN_FILE"
if [[ "$cuda_value" == '-1' ]]; then
  warn '已配置为强制使用 CPU。'
elif [[ -n "$cuda_value" ]]; then
  info "CUDA_VISIBLE_DEVICES=$cuda_value"
fi
info "OLLAMA_NUM_PARALLEL=$parallel_value"

svc daemon-reload
svc restart "$SERVICE"
if svc is-active --quiet "$SERVICE"; then
  success 'GPU 设置已生效，Ollama 服务已重启。'
else
  die '服务重启失败，请使用 ollama_logs 查看日志。'
fi
GPU_SCRIPT
  } >"$gpu_tmp"
  ensure_dir 0755 "$COMMAND_ROOT"
  ensure_dir 0755 "${COMMAND_ROOT}/bin"
  ensure_dir 0755 "${COMMAND_ROOT}/lib"
  ensure_dir 0755 "${COMMAND_ROOT}/lib/ollama-scripts"
  run_admin install -m 0644 "$PROJECT_UI_LIB" "$INSTALLED_UI_LIB"
  run_admin install -m 0755 "$gpu_tmp" "$GPU_COMMAND"
  success "GPU 选择命令已安装：$GPU_COMMAND"
  if [[ ":${PATH}:" != *":${COMMAND_ROOT}/bin:"* ]]; then
    warn "${COMMAND_ROOT}/bin 不在当前 PATH 中，请将其加入 shell 配置。"
  fi
}

write_port_command() {
  local port_tmp="${TEMP_DIR}/ollama_port_select"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'INSTALL_SCOPE=%q\nCONFIG_FILE=%q\nOLLAMA_COMMAND=%q\nACTUAL_BINARY=%q\n' \
      "$INSTALL_SCOPE" "$CONFIG_FILE" "$OLLAMA_COMMAND" "${INSTALL_DIR}/bin/ollama.bin"
    cat <<'PORT_SCRIPT'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UI_LIB="${SCRIPT_DIR%/bin}/lib/ollama-scripts/ui.sh"
[[ -r "$UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$UI_LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$UI_LIB"

SERVICE='ollama.service'
if [[ "$INSTALL_SCOPE" == 'system' ]]; then
  DROPIN_DIR='/etc/systemd/system/ollama.service.d'
else
  DROPIN_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/ollama.service.d"
fi
DROPIN_FILE="${DROPIN_DIR}/port.conf"
root() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo "$@"; else "$@"; fi; }
svc() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo systemctl "$@"; else systemctl --user "$@"; fi; }
port_is_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

[[ -t 0 ]] || die '请在交互式终端中运行。'
svc cat "$SERVICE" >/dev/null 2>&1 || die '未找到 ollama.service，请先运行安装脚本。'

CURRENT_PORT=''
if root test -e "$CONFIG_FILE"; then
  while IFS='=' read -r key value; do
    [[ "$key" == 'OLLAMA_PORT' ]] && CURRENT_PORT=$value
  done < <(root cat "$CONFIG_FILE")
fi
[[ -n "$CURRENT_PORT" ]] && info "当前监听地址：127.0.0.1:$CURRENT_PORT"

port_is_available() {
  local port=$1
  if [[ "$port" == "$CURRENT_PORT" ]] && svc is-active --quiet "$SERVICE" 2>/dev/null; then return 0; fi
  ! port_is_open "$port"
}

pick_random_port() {
  local candidate attempts
  for ((attempts = 0; attempts < 10; attempts++)); do
    candidate=$((20000 + (((RANDOM << 15) | RANDOM) % 40001)))
    if port_is_available "$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

while true; do
  printf '%b[端口]%b 1) 默认端口 11434  2) 随机可用端口  3) 自定义端口\n' "$UI_CYAN" "$UI_RESET"
  choice=$(ask '请选择端口方式' '2')
  case "$choice" in
    1) NEW_PORT='11434' ;;
    2) NEW_PORT=$(pick_random_port) || die '尝试 10 次后仍未找到可用随机端口。' ;;
    3)
      custom_port=$(ask '请输入 1024-65535 之间的端口')
      if [[ ! "$custom_port" =~ ^[0-9]+$ || ${#custom_port} -gt 5 ]] || ((10#$custom_port < 1024 || 10#$custom_port > 65535)); then
        warn '端口无效，普通用户只能选择 1024-65535。'
        continue
      fi
      NEW_PORT=$((10#$custom_port))
      ;;
    *) warn '无效选择，请输入 1、2 或 3。'; continue ;;
  esac
  if ! port_is_available "$NEW_PORT"; then
    warn "端口 $NEW_PORT 已被占用，请重新选择。"
    continue
  fi
  break
done
info "端口已选择为 127.0.0.1:${NEW_PORT}，命令会自动更新配置并启动 Ollama 服务。"

tmp_dropin=$(mktemp)
tmp_wrapper=$(mktemp)
trap 'rm -f -- "$tmp_dropin" "$tmp_wrapper"' EXIT
printf '[Service]\nEnvironment="OLLAMA_HOST=127.0.0.1:%s"\n' "$NEW_PORT" >"$tmp_dropin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:%s}"\n' "$NEW_PORT"
  printf 'exec %q "$@"\n' "$ACTUAL_BINARY"
} >"$tmp_wrapper"

root install -d -m 0755 "$DROPIN_DIR"
root install -m 0644 "$tmp_dropin" "$DROPIN_FILE"
root install -m 0755 "$tmp_wrapper" "$OLLAMA_COMMAND"
if root test -e "$CONFIG_FILE"; then
  root sed -i "s/^OLLAMA_PORT=.*/OLLAMA_PORT=${NEW_PORT}/" "$CONFIG_FILE"
else
  warn '未找到安装记录，端口已应用但无法保存给下次安装使用。'
fi

svc daemon-reload
svc restart "$SERVICE" || die 'systemd 未能提交 Ollama 重启请求。'
sleep 1
if ! svc is-active --quiet "$SERVICE"; then
  svc stop "$SERVICE" >/dev/null 2>&1 || true
  die '新端口应用后服务启动失败，已停止自动重试，请查看 ollama_logs。'
fi
success "端口已更新为 127.0.0.1:${NEW_PORT}，Ollama 服务已重启。"
PORT_SCRIPT
  } >"$port_tmp"
  run_admin install -m 0755 "$port_tmp" "$PORT_COMMAND"
  success "端口选择命令已安装：$PORT_COMMAND"
}

write_service_commands() {
  local ctl_tmp="${TEMP_DIR}/service_ctl.sh" command_name
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nINSTALL_SCOPE=%q\nUI_LIB=%q\nCONFIG_FILE=%q\nOLLAMA_PORT=%q\n' \
      "$INSTALL_SCOPE" "$INSTALLED_UI_LIB" "$CONFIG_FILE" "$OLLAMA_PORT"
    cat <<'SERVICE_CTL_SCRIPT'
[[ -r "$UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$UI_LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$UI_LIB"

SERVICE='ollama.service'
ACTION=${0##*/}
root() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo "$@"; else "$@"; fi; }
svc() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo systemctl "$@"; else systemctl --user "$@"; fi; }
logs() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo journalctl -u "$SERVICE" -f; else journalctl --user -u "$SERVICE" -f; fi; }
if root test -e "$CONFIG_FILE"; then
  while IFS='=' read -r key value; do
    [[ "$key" == 'OLLAMA_PORT' ]] && OLLAMA_PORT=$value
  done < <(root cat "$CONFIG_FILE")
fi
port_is_open() { (exec 3<>"/dev/tcp/127.0.0.1/${OLLAMA_PORT}") >/dev/null 2>&1; }
ensure_startable() {
  if svc is-active --quiet "$SERVICE"; then
    return 0
  fi
  if port_is_open; then
    svc stop "$SERVICE" >/dev/null 2>&1 || true
    die "端口 127.0.0.1:${OLLAMA_PORT} 已被其他进程占用。请运行 ollama_port_select 选择新端口。"
  fi
}
svc cat "$SERVICE" >/dev/null 2>&1 || die '未找到 ollama.service，请先运行安装脚本。'

case "$ACTION" in
  ollama_start)
    ensure_startable
    if svc is-active --quiet "$SERVICE"; then
      info 'Ollama 服务已经在运行。'
      exit 0
    fi
    svc start "$SERVICE" || die 'systemd 未能提交 Ollama 启动请求。'
    sleep 1
    if ! svc is-active --quiet "$SERVICE"; then
      svc stop "$SERVICE" >/dev/null 2>&1 || true
      die 'Ollama 服务启动失败，已停止自动重试，请查看 ollama_logs。'
    fi
    success 'Ollama 服务已启动。'
    ;;
  ollama_stop)
    svc stop "$SERVICE"
    if svc is-active --quiet "$SERVICE"; then
      die 'Ollama 服务未能停止。'
    fi
    success 'Ollama 服务已停止。'
    ;;
  ollama_restart)
    ensure_startable
    svc restart "$SERVICE" || die 'systemd 未能提交 Ollama 重启请求。'
    sleep 1
    if ! svc is-active --quiet "$SERVICE"; then
      svc stop "$SERVICE" >/dev/null 2>&1 || true
      die 'Ollama 服务重启失败，已停止自动重试，请查看 ollama_logs。'
    fi
    success 'Ollama 服务已重启。'
    ;;
  ollama_status)
    svc --no-pager status "$SERVICE"
    ;;
  ollama_logs)
    info '按 Ctrl+C 退出实时日志。'
    logs
    ;;
  *)
    die "未知的服务命令：$ACTION"
    ;;
esac
SERVICE_CTL_SCRIPT
  } >"$ctl_tmp"
  run_admin install -m 0755 "$ctl_tmp" "$SERVICE_CTL"
  for command_name in ollama_start ollama_stop ollama_restart ollama_status ollama_logs; do
    run_admin ln -sfn "$SERVICE_CTL" "${COMMAND_ROOT}/bin/${command_name}"
  done
  success '服务命令已安装：ollama_start、ollama_stop、ollama_restart、ollama_status、ollama_logs。'
}

save_config() {
  local config_tmp="${TEMP_DIR}/installer.conf"
  {
    printf '# Generated by install_ollama.sh; one KEY=VALUE entry per line.\n'
    printf 'INSTALL_DIR=%s\n' "$INSTALL_DIR"
    printf 'MODEL_DIR=%s\n' "$MODEL_DIR"
    printf 'OLLAMA_PORT=%s\n' "$OLLAMA_PORT"
    printf 'INSTALL_SCOPE=%s\n' "$INSTALL_SCOPE"
    printf 'OLLAMA_COMMAND=%s\n' "$OLLAMA_COMMAND"
    printf 'GPU_COMMAND=%s\n' "$GPU_COMMAND"
    printf 'PORT_COMMAND=%s\n' "$PORT_COMMAND"
    printf 'INSTALLED_UI_LIB=%s\n' "$INSTALLED_UI_LIB"
    printf 'SERVICE_CTL=%s\n' "$SERVICE_CTL"
    printf 'SERVICE_FILE=%s\n' "$SERVICE_FILE"
  } >"$config_tmp"
  if [[ "$INSTALL_SCOPE" == 'system' ]]; then
    run_admin install -d -m 0755 "$CONFIG_DIR"
  else
    run_admin install -d -m 0700 "$CONFIG_DIR"
  fi
  run_admin install -m 0600 "$config_tmp" "$CONFIG_FILE"
}

print_summary() {
  local version service_state linger_state='未知'
  version=$("${INSTALL_DIR}/bin/ollama.bin" --version 2>&1 | head -n 1 || true)
  service_state=$(service_systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  if [[ "$INSTALL_SCOPE" == 'user' ]] && command -v loginctl >/dev/null 2>&1; then
    linger_state=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)
  fi
  step '安装结果'
  success "版本：${version:-已安装}"
  success "服务状态：${service_state:-未知}"
  info "安装范围：$([[ "$INSTALL_SCOPE" == 'system' ]] && printf '系统级（所有用户）' || printf '当前用户')"
  info "程序目录：$INSTALL_DIR"
  info "模型目录：$MODEL_DIR"
  info "监听地址：127.0.0.1:$OLLAMA_PORT"
  info "选择 NVIDIA GPU：$GPU_COMMAND"
  info "重新选择端口：$PORT_COMMAND"
  info '服务管理：ollama_start、ollama_stop、ollama_restart、ollama_status、ollama_logs'
  if [[ "$INSTALL_SCOPE" == 'user' && "$linger_state" != 'yes' ]]; then
    warn '当前未确认启用 lingering；退出登录后用户服务可能停止。是否允许启用需咨询系统管理员。'
  fi
}

main() {
  step '选择安装范围'
  choose_install_scope
  configure_scope
  step '环境检查'
  require_environment
  check_system_service_conflict
  load_previous_config
  if command -v ollama >/dev/null 2>&1 || service_systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || [[ -n "$PREVIOUS_INSTALL_DIR" ]]; then
    show_existing_installation
  else
    info '未检测到已有用户级 Ollama 安装，将开始全新安装。'
  fi
  choose_paths
  choose_port
  detect_arch
  TEMP_DIR=$(mktemp -d)
  download_and_install
  step '配置用户服务与辅助命令'
  save_config
  write_service
  write_gpu_command
  write_port_command
  write_service_commands
  print_summary
}

main "$@"
