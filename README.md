# Ollama Ubuntu 双模式交互式安装脚本

为 Ubuntu 提供 Ollama 的用户级和系统级安装、更新、GPU 选择、端口绑定及卸载能力。安装开始时由用户选择是否使用 sudo。

## 安装模式

### 当前用户安装

- 不需要 sudo，不修改系统目录
- 程序和命令默认位于 `~/.local`
- 模型默认位于 `~/.local/share/ollama/models`
- 服务由 `systemctl --user` 管理
- 只对当前用户生效

### sudo 系统级安装

- 安装时验证 sudo 权限
- 程序和命令默认位于 `/usr/local`
- 模型默认位于 `/var/lib/ollama/models`
- 服务文件位于 `/etc/systemd/system/ollama.service`
- 创建 `ollama` 系统服务账户
- `ollama` 及辅助命令对所有用户可见

系统模式下，普通用户可以使用 `ollama` 客户端连接服务；修改 GPU、启停系统服务或卸载仍属于管理操作，相关命令会请求 sudo。

## 功能

- 检测当前安装范围内的 Ollama、systemd 服务和安装记录
- 检查 `curl`、`tar`、`zstd`、`systemctl` 等依赖
- 系统模式可以通过 apt 安装缺失依赖；用户模式只提示缺失项
- 交互选择程序安装前缀和模型目录
- 交互选择默认端口、随机可用端口或自定义端口
- 安装 `ollama_start`、`ollama_stop`、`ollama_restart`、`ollama_status`、`ollama_logs`
- 安装 `ollama_gpu_select`，通过 systemd drop-in 配置 `CUDA_VISIBLE_DEVICES`
- 安装 `ollama_port_select`，运行期间可重新选择监听端口
- 安装后的辅助命令不依赖项目目录
- 彩色分级输出，设置 `NO_COLOR=1` 可关闭颜色
- 安全卸载，模型目录单独确认后才删除

## 系统要求

- Ubuntu 和 systemd
- `x86_64` 或 `aarch64/arm64`
- 可用的网络连接
- 用户模式需要可用的用户级 systemd 登录会话
- 系统模式需要当前账户拥有 sudo 权限

GPU 驱动不由本脚本安装。NVIDIA GPU 选择功能要求系统已经可以运行 `nvidia-smi`。

## 安装或更新

```bash
git clone https://ghfast.top/https://github.com/paulvkey/ollama-scripts.git
chmod +x install_ollama.sh uninstall_ollama.sh
./install_ollama.sh
```

脚本开始时会询问：

```text
1) 当前用户安装（无需 sudo）
2) 系统级安装（需要 sudo，所有用户可用）
```

不要直接执行 `sudo ./install_ollama.sh`。选择系统模式后，脚本会在需要时调用 sudo。

### 默认目录

| 内容         | 当前用户安装                              | 系统级安装                           |
| ------------ | ----------------------------------------- | ------------------------------------ |
| 安装前缀     | `~/.local`                                | `/usr/local`                         |
| 实际程序     | `~/.local/bin/ollama.bin`                 | `/usr/local/bin/ollama.bin`          |
| CLI 包装命令 | `~/.local/bin/ollama`                     | `/usr/local/bin/ollama`              |
| 模型目录     | `~/.local/share/ollama/models`            | `/var/lib/ollama/models`             |
| 服务文件     | `~/.config/systemd/user/ollama.service`   | `/etc/systemd/system/ollama.service` |
| 安装记录     | `~/.config/ollama-scripts/installer.conf` | `/etc/ollama-scripts/installer.conf` |

安装前缀和模型目录均可交互修改。用户模式要求目录对当前用户可写；系统模式通过 sudo 创建目录。

## 监听端口

安装过程中可以选择：

- 默认端口：`127.0.0.1:11434`
- 随机端口：从 `20000-60000` 中选择当前未占用端口，最多尝试 10 次
- 自定义端口：输入 `1024-65535` 之间的端口
- 更新已有安装时保持原端口

服务固定绑定本机回环地址，不会直接暴露到局域网。所选端口会保存到对应安装记录并写入服务的 `OLLAMA_HOST`。

安装的 `ollama` 是一个轻量包装命令，会自动连接所选端口，因此随机或自定义端口下仍可直接执行：

```bash
ollama pull llama3.2
ollama run llama3.2
```

显式设置 `OLLAMA_HOST` 可以临时覆盖安装配置。

## 服务管理命令

```bash
ollama_start
ollama_stop
ollama_restart
ollama_status
ollama_logs
```

用户模式下这些命令操作 `systemctl --user`。系统模式下操作系统级服务，并在管理操作时请求 sudo。`ollama_logs` 会持续跟踪日志，按 `Ctrl+C` 退出。

`ollama_start` 会在启动前检测安装时选择的端口。如果服务尚未运行且端口已被其他进程占用，命令会停止 systemd 的重试并提示运行 `ollama_port_select`。`ollama_restart` 在服务未运行时也会执行相同检查。

## 重新选择端口

安装完成后随时可以运行：

```bash
ollama_port_select
```

命令提供默认端口、随机可用端口和自定义端口三种选择，并同步更新：

- systemd 的 `port.conf` drop-in
- `ollama` CLI 包装命令中的 `OLLAMA_HOST`
- 当前安装范围的 `installer.conf`

更新完成后会重新加载并重启 Ollama。用户模式不需要 sudo；系统模式修改全局服务和命令时会请求 sudo。

也可以直接使用 systemd：

```bash
# 用户模式
systemctl --user status ollama
journalctl --user -u ollama -f

# 系统模式
sudo systemctl status ollama
sudo journalctl -u ollama -f
```

用户服务通常在登录后启动、退出登录后停止。如果需要在未登录时继续运行，需要系统允许当前用户启用 lingering：

```bash
loginctl show-user "$USER" -p Linger
```

## 选择 NVIDIA GPU

```bash
ollama_gpu_select
```

默认选择 GPU 0；也支持输入逗号分隔的 GPU 编号、使用全部 GPU，或设置 `CUDA_VISIBLE_DEVICES=-1` 强制使用 CPU。如果未检测到编号为 0 的 NVIDIA GPU，GPU 选择会提示错误并退出。

命令将 GPU 和并行数作为两个独立操作，启动后可以选择：

```text
1) 仅选择 GPU
2) 仅设置 OLLAMA_NUM_PARALLEL
3) 同时配置两项
```

执行单项操作时会保留另一项的现有值；因此没有 NVIDIA GPU 或没有 `nvidia-smi` 时，也可以单独调整 `OLLAMA_NUM_PARALLEL`。

选择 GPU 时会先显示当前所有可用 NVIDIA GPU 的编号、型号、GPU 利用率、显存已用/总量、显存占用率和 UUID。利用率是执行命令时由 `nvidia-smi` 获取的一次实时快照。

`OLLAMA_NUM_PARALLEL` 表示每个模型能够同时处理的最大请求数，提供 `1`、`2`、`4` 和自定义 `1-128` 四种选择。默认值 `1` 最节省显存或内存；提高数值可能增加并发吞吐，但上下文缓存也会消耗更多资源，显存不足时应选择较小值。

- 用户模式写入 `~/.config/systemd/user/ollama.service.d/gpu.conf`
- 系统模式写入 `/etc/systemd/system/ollama.service.d/gpu.conf`，需要 sudo

## 多用户说明

系统级安装只需安装一次，所有用户共享同一个 Ollama 服务、端口、模型目录和 GPU 资源。

用户级安装彼此独立，每位用户拥有自己的程序、配置和模型。如果多个用户需要同时启动各自服务，应选择不同端口；模型文件和 GPU 显存也不会自动共享。

## 卸载

```bash
./uninstall_ollama.sh
```

卸载开始时选择当前用户安装或 sudo 系统级安装。脚本只清理所选范围；模型目录必须再次明确确认才会永久删除。系统模式还会询问是否删除 `ollama` 系统账户。

## 文件说明

| 文件                  | 作用                          |
| --------------------- | ----------------------------- |
| `install_ollama.sh`   | 双模式交互式安装或更新 Ollama |
| `uninstall_ollama.sh` | 双模式交互式安全卸载 Ollama   |
| `lib/ui.sh`           | 公共颜色、日志和交互函数      |

Ollama Linux 安装包来自官方地址：`https://ollama.com/download/ollama-linux-<架构>.tar.zst`。
