# OMO (Oh-My-Ollama / Ollama模型组织器)

🤖 **基于Docker的Ollama模型管理工具，支持备份和编排生成。**

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/LaiQE/omo)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue?logo=docker)](https://www.docker.com/)

**语言**: [English](README.md) | [中文](README_CN.md)

## 🌟 什么是OMO?

**OMO** (Oh-My-Ollama / Ollama模型组织器) 是一个基于Docker的shell脚本，用于管理[Ollama](https://ollama.ai/)模型。它提供基本的模型生命周期操作，包括下载、备份、恢复和删除，同时可以生成用于生产部署的Docker Compose配置。

## ✨ 功能特性

### 📥 模型管理

- **下载模型**: 从Ollama仓库或HuggingFace仓库(仅GGUF)安装模型
- **列出模型**: 显示已安装模型的详细信息
- **删除模型**: 单个或批量删除模型
- **模型验证**: 操作后检查模型完整性

### 💾 备份与恢复

- **完整备份**: 包含清单和blob文件的完整模型备份
- **完整性验证**: 备份完整性的MD5校验和验证
- **灵活恢复**: 从备份档案恢复模型
- **批量操作**: 备份或恢复多个模型

### 🐳 Docker集成

- **编排生成**: 创建Docker Compose配置
- **多服务堆栈**: 集成Ollama、One-API和Open-WebUI服务
- **GPU支持**: 自动NVIDIA GPU检测和配置
- **生产就绪**: 适当的卷管理和网络配置

## 🚀 快速开始

### 环境要求

- **Docker**: 所有操作都需要
- **nvidia-gpu**: 用于部署时的GPU加速

### 安装

1. 克隆仓库：

```bash
git clone https://github.com/LaiQE/omo.git
cd omo
```

2. 设置脚本执行权限：

```bash
chmod +x omo.sh
```

3. 创建模型列表文件：

```bash
touch models.list
```

### 基本使用

```bash
# 显示帮助
./omo.sh --help

# 从models.list安装缺失的模型
./omo.sh --install

# 列出已安装的模型
./omo.sh --list

# 备份特定模型
./omo.sh --backup qwen2.5:7b-instruct

# 备份所有模型
./omo.sh --backup-all

# 从备份恢复
./omo.sh --restore /path/to/backup.tar.gz

# 删除模型
./omo.sh --remove deepseek-r1:1.5b

# 生成Docker Compose
./omo.sh --generate-compose

# 强制操作（跳过确认）
./omo.sh --force --install
```

## 📝 模型配置

创建`models.list`文件，每行一个模型：

```text
# Ollama仓库模型
ollama:deepseek-r1:1.5b
ollama:llama3.2:3b
ollama:qwen2.5:7b-instruct

# HuggingFace GGUF模型
hf-gguf:hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
hf-gguf:hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF:q4_0

# 注释和空行将被忽略
# 在这里添加你自己的模型
```

### 支持的格式

| 格式                | 描述                 | 示例                           |
| ------------------- | -------------------- | ------------------------------ |
| `ollama:模型:标签`  | Ollama官方模型       | `ollama:llama3.2:3b`           |
| `hf-gguf:仓库:文件` | HuggingFace GGUF模型 | `hf-gguf:hf.co/作者/模型:文件` |

## 📁 目录结构

```text
omo/
├── omo.sh              # 主脚本
├── models.list         # 模型配置
├── ollama/            # Ollama数据目录
│   └── models/        # 模型存储
├── backups/           # 模型备份
└── docker-compose.yml # 生成的compose文件（可选）
```

## 🛠️ 命令行选项

### 核心命令

| 选项                 | 描述                   |
| -------------------- | ---------------------- |
| `--install`          | 下载缺失的模型         |
| `--check-only`       | 仅检查状态（默认）     |
| `--force-download`   | 强制重新下载所有模型   |
| `--list`             | 列出已安装的模型       |
| `--backup MODEL`     | 备份特定模型           |
| `--backup-all`       | 备份所有模型           |
| `--restore FILE`     | 从备份恢复             |
| `--remove MODEL`     | 删除特定模型           |
| `--remove-all`       | 删除所有模型           |
| `--generate-compose` | 生成docker-compose.yml |

### 配置选项

| 选项                 | 描述           | 默认值          |
| -------------------- | -------------- | --------------- |
| `--models-file FILE` | 模型列表文件   | `./models.list` |
| `--ollama-dir DIR`   | Ollama数据目录 | `./ollama`      |
| `--backup-dir DIR`   | 备份目录       | `./backups`     |
| `--verbose`          | 启用详细日志   | -               |
| `--force`            | 跳过确认       | -               |

## 🐳 Docker Compose集成

生成完整的Docker堆栈：

```bash
./omo.sh --generate-compose
```

这将创建包含以下服务的`docker-compose.yml`：

| 服务           | 端口  | 描述                |
| -------------- | ----- | ------------------- |
| **Ollama**     | 11434 | 支持GPU的模型运行时 |
| **One-API**    | 3000  | API网关和管理       |
| **Open-WebUI** | 3001  | 聊天的Web界面       |

**外部参考:**

- [Ollama](https://ollama.ai/) - AI模型运行时
- [One-API](https://github.com/songquanpeng/one-api) - OpenAI API网关
- [Open-WebUI](https://github.com/open-webui/open-webui) - Web界面

## 🔧 配置

### 环境变量

```bash
# 启用详细日志
export VERBOSE="true"

# 使用自定义目录
./omo.sh --ollama-dir /custom/ollama --backup-dir /custom/backups
```

## 📋 示例

### 模型管理工作流

```bash
# 1. 检查需要下载的模型
./omo.sh --check-only

# 2. 安装缺失的模型
./omo.sh --install

# 3. 列出所有已安装的模型
./omo.sh --list

# 4. 备份重要模型
./omo.sh --backup qwen2.5:7b-instruct

# 5. 生成用于部署的Docker Compose
./omo.sh --generate-compose

# 6. 启动堆栈
docker-compose up -d
```

### 备份和恢复

```bash
# 备份所有模型
./omo.sh --backup-all

# 恢复特定模型
./omo.sh --restore backups/qwen2.5_7b-instruct_20241201_123456.tar.gz

# 强制恢复（覆盖现有）
./omo.sh --force --restore backups/model_backup.tar.gz
```

## 🚨 错误处理

OMO包含基本的错误处理：

- **网络问题**: 下载失败的清晰错误信息
- **Docker问题**: Docker守护程序状态验证
- **文件完整性**: 备份的MD5校验和验证
- **模型冲突**: 破坏性操作的确认提示

## 🤝 贡献

欢迎贡献！请：

1. Fork仓库
2. 创建功能分支
3. 进行更改
4. 提交Pull Request

## 📄 许可证

本项目采用MIT许可证 - 详见[LICENSE](LICENSE)文件。

## 🙏 致谢

- **[Ollama](https://ollama.ai/)** - 优秀的LLM运行时平台
- **[Docker](https://docker.com/)** - 容器化平台

## 📞 支持

- **问题反馈**: [GitHub Issues](https://github.com/LaiQE/omo/issues)
- **讨论**: [GitHub Discussions](https://github.com/LaiQE/omo/discussions)

---

**作者**: Chain Lai  
**仓库**: <https://github.com/LaiQE/omo>
