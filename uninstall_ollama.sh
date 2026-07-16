#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_UI_LIB="${SCRIPT_DIR}/lib/ui.sh"
[[ -r "$PROJECT_UI_LIB" ]] || { printf '[错误] 缺少公共库：%s\n' "$PROJECT_UI_LIB" >&2; exit 1; }
# shellcheck source=lib/ui.sh
source "$PROJECT_UI_LIB"

readonly SERVICE='ollama.service'
readonly SERVICE_FILE='/etc/systemd/system/ollama.service'
readonly DROPIN_DIR='/etc/systemd/system/ollama.service.d'
readonly CONFIG_FILE='/etc/ollama/installer.conf'
root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

[[ -t 0 ]] || die '需要在交互式终端中运行此脚本。'
if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || die '需要 root 权限。'
  info '卸载步骤需要 sudo 权限。'
  sudo -v
fi

INSTALL_DIR=''
MODEL_DIR=''
COMMAND_USER=''
GPU_COMMAND=''
INSTALLED_UI_LIB=''
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      INSTALL_DIR) INSTALL_DIR=$value ;;
      MODEL_DIR) MODEL_DIR=$value ;;
      COMMAND_USER) COMMAND_USER=$value ;;
      GPU_COMMAND) GPU_COMMAND=$value ;;
      INSTALLED_UI_LIB) INSTALLED_UI_LIB=$value ;;
    esac
  done < <(root cat "$CONFIG_FILE")
fi

if [[ -z "$GPU_COMMAND" || -z "$INSTALLED_UI_LIB" ]]; then
  if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
    current_user=$SUDO_USER
  else
    current_user=$(id -un)
  fi
  passwd_entry=$(getent passwd "$current_user") || die "无法读取用户 $current_user 的账户信息。"
  current_home=$(cut -d: -f6 <<<"$passwd_entry")
  [[ -n "$current_home" && "$current_home" == /* ]] || die "用户 $current_user 的 HOME 目录无效。"
  GPU_COMMAND=${GPU_COMMAND:-${current_home}/.local/bin/ollama_gpu_select}
  INSTALLED_UI_LIB=${INSTALLED_UI_LIB:-${current_home}/.local/lib/ollama-scripts/ui.sh}
  COMMAND_USER=${COMMAND_USER:-$current_user}
fi

if [[ -z "$INSTALL_DIR" ]]; then
  binary=$(command -v ollama 2>/dev/null || true)
  if [[ -n "$binary" ]]; then
    binary=$(readlink -f "$binary")
    [[ "$binary" == */bin/ollama ]] && INSTALL_DIR=${binary%/bin/ollama}
  fi
fi

info "服务文件：$SERVICE_FILE"
info "安装目录：${INSTALL_DIR:-无法确认，将不删除程序文件}"
info "模型目录：${MODEL_DIR:-无法确认，将不删除模型}"
info "个人命令：$GPU_COMMAND（用户 ${COMMAND_USER:-未知}）"
confirm '确认卸载由本项目管理的 Ollama 服务和程序？' N || { info '已取消卸载。'; exit 0; }

if systemctl cat "$SERVICE" >/dev/null 2>&1; then
  root systemctl disable --now "$SERVICE" || warn '服务停止或禁用时返回异常，将继续清理。'
fi
root rm -f -- "$SERVICE_FILE"
root rm -f -- "${DROPIN_DIR}/gpu.conf"
root rmdir -- "$DROPIN_DIR" 2>/dev/null || true
root systemctl daemon-reload

if [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != '/' ]]; then
  target="${INSTALL_DIR}/bin/ollama"
  if [[ -L /usr/local/bin/ollama && "$(readlink -f /usr/local/bin/ollama)" == "$(readlink -f "$target" 2>/dev/null || true)" ]]; then
    root rm -f -- /usr/local/bin/ollama
  fi
  root rm -f -- "$target"
  root rm -rf -- "${INSTALL_DIR}/lib/ollama"
  root rmdir -- "${INSTALL_DIR}/bin" "$INSTALL_DIR" 2>/dev/null || true
  ok 'Ollama 程序文件已移除。'
else
  warn '无法安全确认安装目录，已跳过程序文件删除。'
fi

root rm -f -- "$GPU_COMMAND"
root rm -f -- "$INSTALLED_UI_LIB"
root rmdir -- "$(dirname -- "$INSTALLED_UI_LIB")" 2>/dev/null || true

model_dir_is_safe=1
case "$MODEL_DIR" in
  ''|/|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    model_dir_is_safe=0
    ;;
esac
if [[ -n "$MODEL_DIR" && -d "$MODEL_DIR" && "$model_dir_is_safe" == '1' ]]; then
  if confirm "是否同时永久删除模型目录 $MODEL_DIR？" N; then
    root rm -rf -- "$MODEL_DIR"
    ok '模型目录已删除。'
  else
    info "已保留模型目录：$MODEL_DIR"
  fi
elif [[ -n "$MODEL_DIR" && -d "$MODEL_DIR" ]]; then
  warn "模型目录 $MODEL_DIR 未通过安全检查，已拒绝删除。"
fi

if id ollama >/dev/null 2>&1 && confirm '是否删除 ollama 系统用户和用户组？' Y; then
  root userdel ollama 2>/dev/null || true
  getent group ollama >/dev/null && root groupdel ollama 2>/dev/null || true
  ok 'ollama 系统账户已删除。'
fi

root rm -f -- "$CONFIG_FILE"
root rmdir /etc/ollama 2>/dev/null || true
ok '卸载完成。'
