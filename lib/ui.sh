#!/usr/bin/env bash

# 统一的终端颜色与交互输出。调用方应在加载前启用所需的 Bash 严格模式。
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  UI_RESET='\033[0m'
  UI_BLUE='\033[1;34m'
  UI_GREEN='\033[1;32m'
  UI_YELLOW='\033[1;33m'
  UI_RED='\033[1;31m'
  UI_CYAN='\033[1;36m'
else
  UI_RESET=''
  UI_BLUE=''
  UI_GREEN=''
  UI_YELLOW=''
  UI_RED=''
  UI_CYAN=''
fi
readonly UI_RESET UI_BLUE UI_GREEN UI_YELLOW UI_RED UI_CYAN

info()    { printf '%b[信息]%b %s\n' "$UI_BLUE" "$UI_RESET" "$*"; }
success() { printf '%b[成功]%b %s\n' "$UI_GREEN" "$UI_RESET" "$*"; }
ok()      { success "$@"; }
warn()    { printf '%b[警告]%b %s\n' "$UI_YELLOW" "$UI_RESET" "$*"; }
error()   { printf '%b[错误]%b %s\n' "$UI_RED" "$UI_RESET" "$*" >&2; }
step()    { printf '\n%b==>%b %s\n' "$UI_CYAN" "$UI_RESET" "$*"; }
die()     { trap - ERR; error "$*"; exit 1; }

ask() {
  local prompt=$1 default=${2-} answer
  if [[ -n "$default" ]]; then
    printf '%b[输入]%b %s [%s]: ' "$UI_CYAN" "$UI_RESET" "$prompt" "$default" >&2
  else
    printf '%b[输入]%b %s: ' "$UI_CYAN" "$UI_RESET" "$prompt" >&2
  fi
  IFS= read -r answer
  printf '%s' "${answer:-$default}"
}

confirm() {
  local prompt=$1 default=${2:-N} answer suffix='y/N'
  [[ "$default" =~ ^[Yy]$ ]] && suffix='Y/n'
  printf '%b[确认]%b %s (%s): ' "$UI_YELLOW" "$UI_RESET" "$prompt" "$suffix" >&2
  IFS= read -r answer
  answer=${answer:-$default}
  [[ "$answer" =~ ^[Yy]$ ]]
}
