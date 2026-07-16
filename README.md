# Ollama Ubuntu 交互式安装脚本

为 Ubuntu 提供 Ollama 的交互式安装、更新、GPU 选择和卸载能力。

## 功能

- 检测现有 Ollama 命令、版本、systemd 服务状态和此前选择的路径
- 自动检查并通过 `apt` 安装 `curl`、`ca-certificates`、`tar`、`zstd`
- 交互选择 Ollama 安装前缀及模型存储目录
- 自动创建 `ollama` 系统用户和 `ollama.service`，开机启动
- 将 `ollama_gpu_select` 安装到当前个人用户，配置 `CUDA_VISIBLE_DEVICES`
- 彩色分级输出；设置 `NO_COLOR=1` 可关闭颜色
- 所有项目脚本复用 `lib/ui.sh`，统一颜色、日志和交互提示
- 安全卸载，模型和系统用户均单独确认后才删除

## 系统要求

- Ubuntu（使用 systemd）
- `x86_64` 或 `aarch64/arm64`
- 可用的网络连接
- root 权限或可使用 `sudo` 的账户

GPU 驱动不由本脚本安装。NVIDIA GPU 选择功能要求系统已正确安装驱动并可运行 `nvidia-smi`。

## 安装或更新

```bash
chmod +x install_ollama.sh uninstall_ollama.sh
./install_ollama.sh
```

脚本必须在交互式终端运行。全新安装时默认使用：

- 安装前缀：`/usr/local`（程序为 `/usr/local/bin/ollama`）
- 模型目录：`/var/lib/ollama/models`

也可以选择例如 `/opt/ollama` 作为安装前缀。此时脚本会创建 `/usr/local/bin/ollama` 符号链接，使命令仍可从 `PATH` 调用。

检测到旧安装时，脚本会显示已有命令路径、版本、服务状态和记录的目录，并让用户选择更新/重新安装或退出。路径记录保存在 root 专用的 `/etc/ollama/installer.conf`，供后续更新和安全卸载使用。

## 选择 NVIDIA GPU

安装完成后运行：

```bash
ollama_gpu_select
```

命令安装在执行安装脚本的个人用户目录 `~/.local/bin/ollama_gpu_select`，不会出现在其他用户的命令目录中。它所需的公共 UI 库会一并复制到 `~/.local/lib/ollama-scripts/ui.sh`，因此安装完成后不依赖本项目目录。如果 `~/.local/bin` 尚未加入 `PATH`，脚本会给出设置提示；也可直接运行完整路径。

命令会列出 `nvidia-smi` 检测到的 GPU，并提供以下选择：

- 输入 `0,2` 之类的逗号分隔编号，仅使用指定 GPU
- 输入 `a`，清除限制并使用全部 GPU
- 输入 `c`，设置 `CUDA_VISIBLE_DEVICES=-1` 强制使用 CPU

配置写入 `/etc/systemd/system/ollama.service.d/gpu.conf`，随后自动执行 `daemon-reload` 并重启 Ollama 服务。

## 常用命令

```bash
# 查看服务状态
systemctl status ollama

# 实时查看日志
journalctl -u ollama -f

# 查看版本
ollama --version

# 拉取模型
ollama pull llama3.2
```

## 卸载

```bash
./uninstall_ollama.sh
```

卸载脚本会停止并删除 systemd 服务、程序文件、当前安装记录对应用户下的 GPU 选择命令及其 UI 公共库。模型目录默认保留，只有再次明确确认才会永久删除；`ollama` 系统用户和用户组也会单独询问。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `install_ollama.sh` | 交互式安装或更新 Ollama |
| `uninstall_ollama.sh` | 交互式安全卸载 Ollama |
| `lib/ui.sh` | 公共颜色、日志和交互函数 |

Ollama Linux 安装包来自官方地址：`https://ollama.com/download/ollama-linux-<架构>.tar.zst`。
