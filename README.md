# OMO (Oh-My-Ollama / Ollama Model Organizer)

🤖 **Docker-based tool for managing Ollama models with backup and compose generation.**

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/LaiQE/omo)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue?logo=docker)](https://www.docker.com/)

**Language**: [English](README.md) | [中文](README_CN.md)

## 🌟 What is OMO?

**OMO** (Oh-My-Ollama / Ollama Model Organizer) is a Docker-based shell script for managing [Ollama](https://ollama.ai/) models. It provides essential model lifecycle operations including download, backup, restore, and removal, plus generates Docker Compose configurations for production deployments.

## ✨ Features

### 📥 Model Management

- **Download Models**: Install models from Ollama registry or HuggingFace repositories (only GGUF)
- **List Models**: Display installed models with detailed information
- **Remove Models**: Delete models individually or in batch
- **Model Verification**: Check model integrity after operations

### 💾 Backup & Restore

- **Complete Backup**: Full model backup including manifests and blob files
- **Integrity Verification**: MD5 checksum validation for backup integrity
- **Auto-Restore**: `--install` automatically checks and restores from backup before downloading
- **Manual Restore**: Direct restore from backup (use only when needed)
- **Batch Operations**: Backup or restore multiple models

### 🐳 Docker Integration

- **Compose Generation**: Create Docker Compose configurations
- **Multi-Service Stack**: Integrated Ollama, One-API, and Open-WebUI services
- **GPU Support**: Automatic NVIDIA GPU detection and configuration
- **Production Ready**: Proper volume management and networking

## 🚀 Quick Start

### Prerequisites

- **Docker**: Required for all operations
- **nvidia gpu**: for GPU acceleration

### Installation

1. Clone the repository:

```bash
git clone https://github.com/LaiQE/omo.git
cd omo
```

2. Make the script executable:

```bash
chmod +x omo.sh
```

3. Edit the models list file:

```bash
# Edit models.list to add your desired models
# The repository includes a template with examples
vim models.list
```

### Basic Usage

```bash
# Show help
./omo.sh --help

# Install missing models from models.list
./omo.sh --install

# List installed models
./omo.sh --list

# Backup a specific model
./omo.sh --backup ollama:qwen2.5:7b-instruct

# Backup all models
./omo.sh --backup-all

# Restore from backup (manual, not recommended)
# Note: --install automatically restores from backup if available
./omo.sh --restore qwen2.5_7b-instruct

# Remove a model
./omo.sh --remove deepseek-r1:1.5b

# Remove all models
./omo.sh --remove-all

# Generate Docker Compose
./omo.sh --generate-compose
```

## 📝 Model Configuration

Create a `models.list` file with one model per line:

```text
# Ollama registry models
ollama:deepseek-r1:1.5b
ollama:llama3.2:3b
ollama:qwen2.5:7b-instruct

# HuggingFace GGUF models
hf-gguf:hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
hf-gguf:hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF:q4_0

# Comments and empty lines are ignored
# Add your own models here
```

### Supported Formats

| Format              | Description             | Example                           |
| ------------------- | ----------------------- | --------------------------------- |
| `ollama:model:tag`  | Official Ollama models  | `ollama:llama3.2:3b`              |
| `hf-gguf:repo:file` | HuggingFace GGUF models | `hf-gguf:hf.co/author/model:file` |

## 📁 Directory Structure

```text
omo/
├── omo.sh              # Main script
├── models.list         # Model configuration
├── ollama/            # Ollama data directory
│   └── models/        # Model storage
├── backups/           # Model backups
└── docker-compose.yml # Generated compose file (optional)
```

## 🛠️ Command Line Options

### Core Commands

| Option               | Description                  |
| -------------------- | ---------------------------- |
| `--install`          | Download missing models      |
| `--check-only`       | Check status only (default)  |
| `--force-download`   | Force re-download all models |
| `--list`             | List installed models        |
| `--backup MODEL`     | Backup specific model        |
| `--backup-all`       | Backup all models            |
| `--restore FILE`     | Restore from backup          |
| `--remove MODEL`     | Remove specific model        |
| `--remove-all`       | Remove all models            |
| `--generate-compose` | Generate docker-compose.yml  |

### Configuration Options

| Option               | Description            | Default         |
| -------------------- | ---------------------- | --------------- |
| `--models-file FILE` | Model list file        | `./models.list` |
| `--ollama-dir DIR`   | Ollama data directory  | `./ollama`      |
| `--backup-dir DIR`   | Backup directory       | `./backups`     |
| `--verbose`          | Enable verbose logging | -               |
| `--force`            | Skip confirmations     | -               |

## 🐳 Docker Compose Integration

Generate a complete Docker stack:

```bash
./omo.sh --generate-compose
```

This creates a `docker-compose.yml` with:

| Service        | Port  | Description                    |
| -------------- | ----- | ------------------------------ |
| **Ollama**     | 11434 | Model runtime with GPU support |
| **One-API**    | 3000  | API gateway and management     |
| **Open-WebUI** | 3001  | Web interface for chat         |

**External References:**

- [Ollama](https://ollama.ai/) - AI model runtime
- [One-API](https://github.com/songquanpeng/one-api) - OpenAI API gateway
- [Open-WebUI](https://github.com/open-webui/open-webui) - Web interface

## 🔧 Configuration

### Environment Variables

```bash
# Enable verbose logging
export VERBOSE="true"

# Use custom directories
./omo.sh --ollama-dir /custom/ollama --backup-dir /custom/backups
```

## 📋 Examples

### Model Management Workflow

```bash
# 1. Check what models need to be downloaded
./omo.sh --check-only

# 2. Install missing models
./omo.sh --install

# 3. List all installed models
./omo.sh --list

# 4. Backup important models
./omo.sh --backup ollama:qwen2.5:7b-instruct

# 5. Generate Docker Compose for deployment
./omo.sh --generate-compose

# 6. Start the stack
docker-compose up -d
```

### Backup and Restore

```bash
# Recommended workflow: Backup all models
./omo.sh --backup-all

# Install will automatically restore from backup if available
# This is the recommended way - no manual restore needed
./omo.sh --install

# Manual restore (only use when auto-restore doesn't work)
./omo.sh --restore qwen2.5_7b-instruct

# Force restore (overwrite existing)
./omo.sh --force --restore qwen2.5_7b-instruct
```

## 🚨 Error Handling

OMO includes basic error handling for:

- **Network Issues**: Clear error messages for download failures
- **Docker Problems**: Docker daemon status verification
- **File Integrity**: MD5 checksum validation for backups
- **Model Conflicts**: Confirmation prompts for destructive operations

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **[Ollama](https://ollama.ai/)** - Excellent LLM runtime platform
- **[Docker](https://docker.com/)** - Containerization platform

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/LaiQE/omo/issues)
- **Discussions**: [GitHub Discussions](https://github.com/LaiQE/omo/discussions)

---

**Author**: Chain Lai  
**Repository**: <https://github.com/LaiQE/omo>
