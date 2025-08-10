# OMO (Oh-My-Ollama)

🤖 **Ollama模型组织器** - 一个功能全面的Ollama模型管理工具。

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/LaiQE/omo)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

**语言**: [English](README.md) | [中文](README_CN.md)

## ✨ 功能特性

### 📥 模型下载

- **Ollama官方模型**: 直接从Ollama仓库下载模型
- **HuggingFace GGUF**: 直接导入HuggingFace的GGUF格式模型
- **断点续传**: 智能断点续传和缓存复用

### 💾 模型备份与恢复

- **完整备份**: Ollama模型完整备份（manifest + blobs）
- **完整性检查**: MD5校验确保数据完整性
- **详细报告**: 生成详细备份信息文件
- **强制恢复**: 支持恢复时强制覆盖模式

### 📋 模型管理

- **列出模型**: 显示已安装模型及详细信息
- **智能删除**: 智能模型删除（单个/批量）
- **完整性验证**: 模型完整性检查和验证
- **磁盘使用**: 存储使用情况统计

### 🐳 容器化部署

- **Docker Compose**: 生成Docker Compose配置
- **服务集成**: 集成Ollama、One-API、Prompt-Optimizer服务
- **GPU支持**: 自动GPU检测和配置
- **智能配置**: 智能端口和网络设置

### ⚙️ 高级特性

- **自定义量化**: 支持多种量化类型（q4_0, q5_0, q8_0等）
- **动态Docker**: 动态Docker镜像构建
- **并行处理**: 优化缓存和并行执行
- **详细日志**: 详细日志记录和错误处理

## 🚀 快速开始

### 环境要求

- **Docker** 支持GPU（用于CUDA加速）
- **rsync** 用于文件同步
- **bash** shell环境

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

3. 创建模型列表文件（参见[模型文件格式](#-模型文件格式)）：

```bash
touch models.list
```

### 基本使用

```bash
# 显示帮助
./omo.sh --help

# 从models.list下载模型
./omo.sh

# 使用自定义模型文件
./omo.sh --models-file my-models.list

# 备份特定模型
./omo.sh --backup deepseek-r1:1.5b

# 备份所有模型
./omo.sh --backup-all

# 恢复模型
./omo.sh --restore deepseek-r1:1.5b

# 列出已安装模型
./omo.sh --list

# 删除模型
./omo.sh --delete deepseek-r1:1.5b

# 强制下载（忽略已存在）
./omo.sh --force

# 生成Docker Compose
./omo.sh --docker-compose
```

## 📝 模型文件格式

创建`models.list`文件，每行一个模型：

```
# Ollama官方模型
ollama deepseek-r1:1.5b
ollama llama3.2:3b

# HuggingFace模型（带量化）
huggingface microsoft/DialoGPT-medium q4_0
huggingface Qwen/Qwen3-0.6B q5_0

# HuggingFace GGUF模型（直接导入）
hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
hf-gguf hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF
```

### 模型格式类型

| 格式      | 描述                    | 示例                                                        |
| --------- | ----------------------- | ----------------------------------------------------------- |
| `ollama`  | Ollama官方模型          | `ollama deepseek-r1:1.5b`                                   |
| `hf-gguf` | HF GGUF模型（直接导入） | `hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest` |

## 📁 目录结构

```
omo/
├── omo.sh                    # 主脚本
├── models.list               # 模型定义
├── ollama/                   # Ollama数据目录
│   └── models/              # Ollama模型存储
├── backups/                 # 模型备份
└── docker/                 # Docker构建上下文（临时）
```

## 🛠️ 命令行选项

| 选项                      | 描述                   | 默认值          |
| ------------------------- | ---------------------- | --------------- |
| `--models-file FILE`      | 指定模型列表文件       | `./models.list` |
| `--ollama-dir DIR`        | Ollama数据目录         | `./ollama`      |
| `--backup-output-dir DIR` | 备份输出目录           | `./backups`     |
| `--backup MODEL`          | 备份特定模型           | -               |
| `--backup-all`            | 备份所有模型           | -               |
| `--restore MODEL`         | 恢复特定模型           | -               |
| `--list`                  | 列出已安装模型         | -               |
| `--delete MODEL`          | 删除特定模型           | -               |
| `--force`                 | 强制下载/覆盖          | -               |
| `--docker-compose`        | 生成Docker Compose配置 | -               |
| `--rebuild`               | 强制重建Docker镜像     | -               |
| `--verbose`               | 启用详细日志           | -               |
| `--help`                  | 显示帮助信息           | -               |

## 🐳 Docker集成

OMO可以生成包含集成服务的完整Docker Compose设置：

```bash
./omo.sh --docker-compose
```

这将创建包含以下服务的`docker-compose.yml`：

- **Ollama**: 支持GPU的核心LLM运行时
- **One-API**: 多LLM提供商的API网关
- **Prompt-Optimizer**: 提示词优化服务
- **ChatGPT-Next-Web**: 聊天交互的Web界面

### 生成的服务

| 服务             | 端口  | 描述         |
| ---------------- | ----- | ------------ |
| Ollama           | 11434 | LLM运行时API |
| One-API          | 3000  | API网关面板  |
| Prompt-Optimizer | 8080  | 提示词优化   |
| ChatGPT-Next-Web | 3001  | Web聊天界面  |

## 🔧 高级配置

### 环境变量

```bash

# 详细日志
export VERBOSE="true"
```

### 自定义目录

```bash
# 使用自定义目录
./omo.sh \
  --ollama-dir /custom/ollama \
  --backup-output-dir /custom/backups \
  --hf-backup-dir /custom/hf_originals
```

## 🚨 错误处理

OMO包含全面的错误处理：

- **网络问题**: 指数退避的自动重试
- **磁盘空间**: 预检磁盘空间验证
- **下载损坏**: 自动完整性验证
- **Docker问题**: 详细容器诊断
- **权限问题**: 清晰的权限要求消息

## 🤝 贡献

欢迎贡献！请随时：

1. Fork仓库
2. 创建功能分支
3. 进行更改
4. 提交Pull Request

## 📄 许可证

本项目采用MIT许可证 - 详见[LICENSE](LICENSE)文件。

## 🙏 致谢

- [Ollama](https://ollama.ai/) - 优秀的LLM运行时
- [llama.cpp](https://github.com/ggerganov/llama.cpp) - 模型量化工具

## 📞 支持

- **问题反馈**: [GitHub Issues](https://github.com/LaiQE/omo/issues)
- **讨论**: [GitHub Discussions](https://github.com/LaiQE/omo/discussions)

---

**作者**: Chain Lai  
**仓库**: https://github.com/LaiQE/omo
