#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_UI_LIB="${SCRIPT_DIR}/lib/ui.sh"
[[ -r "$PROJECT_UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$PROJECT_UI_LIB" >&2; exit 1; }
# shellcheck source=lib/ui.sh
source "$PROJECT_UI_LIB"

readonly SERVICE='ollama.service'
[[ -t 0 ]] || die '需要在交互式终端中运行此脚本。'
(( EUID != 0 )) || die '请使用普通用户运行，不要直接使用 root。'

printf '%b[卸载范围]%b 1) 当前用户安装  2) sudo 系统级安装\n' "$UI_CYAN" "$UI_RESET"
scope_choice=$(ask '请选择要卸载的安装范围' '1')
case "$scope_choice" in
  1) INSTALL_SCOPE='user' ;;
  2) INSTALL_SCOPE='system' ;;
  *) die '无效选择，请输入 1 或 2。' ;;
esac

run_admin() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then sudo "$@"; else "$@"; fi; }
service_systemctl() { if [[ "$INSTALL_SCOPE" == 'system' ]]; then run_admin systemctl "$@"; else systemctl --user "$@"; fi; }

USER_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
USER_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
USER_LOCAL_ROOT="${HOME}/.local"
command -v systemctl >/dev/null 2>&1 || die '未找到 systemctl。'
if [[ "$INSTALL_SCOPE" == 'system' ]]; then
  command -v sudo >/dev/null 2>&1 || die '系统级卸载需要 sudo。'
  sudo -v
  CONFIG_DIR='/etc/ollama-scripts'
  CONFIG_FILE="${CONFIG_DIR}/installer.conf"
  COMMAND_ROOT='/usr/local'
  DEFAULT_SERVICE_FILE='/etc/systemd/system/ollama.service'
  DROPIN_DIR='/etc/systemd/system/ollama.service.d'
else
  CONFIG_DIR="${USER_CONFIG_HOME}/ollama-scripts"
  CONFIG_FILE="${CONFIG_DIR}/installer.conf"
  COMMAND_ROOT="$USER_LOCAL_ROOT"
  DEFAULT_SERVICE_FILE="${USER_CONFIG_HOME}/systemd/user/ollama.service"
  DROPIN_DIR="${USER_CONFIG_HOME}/systemd/user/ollama.service.d"
  systemctl --user show-environment >/dev/null 2>&1 || die '无法连接用户级 systemd。请在正常登录会话中运行。'
fi

INSTALL_DIR=''
MODEL_DIR=''
OLLAMA_COMMAND="${COMMAND_ROOT}/bin/ollama"
GPU_COMMAND="${COMMAND_ROOT}/bin/ollama_gpu_select"
PORT_COMMAND="${COMMAND_ROOT}/bin/ollama_port_select"
INSTALLED_UI_LIB="${COMMAND_ROOT}/lib/ollama-scripts/ui.sh"
SERVICE_CTL="${COMMAND_ROOT}/lib/ollama-scripts/service_ctl.sh"
SERVICE_FILE=$DEFAULT_SERVICE_FILE
if run_admin test -e "$CONFIG_FILE"; then
  while IFS='=' read -r key value; do
    case "$key" in
      INSTALL_DIR) INSTALL_DIR=$value ;;
      MODEL_DIR) MODEL_DIR=$value ;;
      OLLAMA_COMMAND) OLLAMA_COMMAND=$value ;;
      GPU_COMMAND) GPU_COMMAND=$value ;;
      PORT_COMMAND) PORT_COMMAND=$value ;;
      INSTALLED_UI_LIB) INSTALLED_UI_LIB=$value ;;
      SERVICE_CTL) SERVICE_CTL=$value ;;
      SERVICE_FILE) SERVICE_FILE=$value ;;
    esac
  done < <(run_admin cat "$CONFIG_FILE")
fi

info "服务文件：$SERVICE_FILE"
info "安装范围：$([[ "$INSTALL_SCOPE" == 'system' ]] && printf '系统级（所有用户）' || printf '当前用户')"
info "安装目录：${INSTALL_DIR:-无法确认，将不删除程序文件}"
info "模型目录：${MODEL_DIR:-无法确认，将不删除模型}"
info "个人命令：$OLLAMA_COMMAND、$GPU_COMMAND"
confirm '确认卸载所选范围的 Ollama 服务和程序？' N || { info '已取消卸载。'; exit 0; }

if service_systemctl cat "$SERVICE" >/dev/null 2>&1; then
  service_systemctl disable --now "$SERVICE" || warn '服务停止或禁用时返回异常，将继续清理。'
fi
run_admin rm -f -- "$SERVICE_FILE" "${DROPIN_DIR}/gpu.conf" "${DROPIN_DIR}/port.conf"
run_admin rmdir -- "$DROPIN_DIR" 2>/dev/null || true
service_systemctl daemon-reload

if [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != '/' ]]; then
  target="${INSTALL_DIR}/bin/ollama"
  run_admin rm -f -- "$OLLAMA_COMMAND" "$target" "${INSTALL_DIR}/bin/ollama.bin"
  run_admin rm -rf -- "${INSTALL_DIR}/lib/ollama"
  run_admin rmdir -- "${INSTALL_DIR}/bin" "$INSTALL_DIR" 2>/dev/null || true
  success 'Ollama 程序文件已移除。'
else
  warn '无法安全确认安装目录，已跳过程序文件删除。'
fi

run_admin rm -f -- "$GPU_COMMAND" "$PORT_COMMAND"
run_admin rm -f -- \
  "${COMMAND_ROOT}/bin/ollama_start" \
  "${COMMAND_ROOT}/bin/ollama_stop" \
  "${COMMAND_ROOT}/bin/ollama_restart" \
  "${COMMAND_ROOT}/bin/ollama_status" \
  "${COMMAND_ROOT}/bin/ollama_logs"
run_admin rm -f -- "$SERVICE_CTL" "$INSTALLED_UI_LIB"
run_admin rmdir -- "$(dirname -- "$INSTALLED_UI_LIB")" 2>/dev/null || true

model_dir_is_safe=1
case "$MODEL_DIR" in
  ''|/|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    model_dir_is_safe=0
    ;;
esac
case "$MODEL_DIR" in
  "$HOME"|"$USER_LOCAL_ROOT"|"$USER_CONFIG_HOME"|"$USER_DATA_HOME")
    model_dir_is_safe=0
    ;;
esac
if [[ -n "$MODEL_DIR" && -d "$MODEL_DIR" && "$model_dir_is_safe" == '1' ]]; then
  if confirm "是否同时永久删除模型目录 $MODEL_DIR？" N; then
    run_admin rm -rf -- "$MODEL_DIR"
    success '模型目录已删除。'
  else
    info "已保留模型目录：$MODEL_DIR"
  fi
elif [[ -n "$MODEL_DIR" && -d "$MODEL_DIR" ]]; then
  warn "模型目录 $MODEL_DIR 未通过安全检查，已拒绝删除。"
fi

if [[ "$INSTALL_SCOPE" == 'system' ]] && id ollama >/dev/null 2>&1 && confirm '是否删除 ollama 系统用户和用户组？' Y; then
  run_admin userdel ollama 2>/dev/null || true
  getent group ollama >/dev/null && run_admin groupdel ollama 2>/dev/null || true
  success 'ollama 系统账户已删除。'
fi

run_admin rm -f -- "$CONFIG_FILE"
run_admin rmdir -- "$CONFIG_DIR" 2>/dev/null || true
success 'Ollama 已卸载。'
