# OMO (Oh-My-Ollama)

🤖 **Ollama Models Organizer** - A comprehensive tool for managing Ollama models with advanced features.

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/LaiQE/omo)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

**Language**: [English](README.md) | [中文](README_CN.md)

## ✨ Features

### 📥 Model Download

- **Ollama Official Models**: Download models directly from Ollama repository
- **HuggingFace GGUF**: Direct import of GGUF format models from HuggingFace
- **Resume Downloads**: Intelligent breakpoint resumption and cache reuse

### 💾 Model Backup & Restore

- **Complete Backup**: Full Ollama model backup (manifest + blobs)
- **Integrity Check**: MD5 checksum verification for data integrity
- **Detailed Reports**: Generate comprehensive backup information files
- **Force Recovery**: Support for force overwrite mode during restoration

### 📋 Model Management

- **List Models**: Display installed models with detailed information
- **Smart Deletion**: Intelligent model deletion (single/batch)
- **Integrity Verification**: Model completeness check and validation
- **Disk Usage**: Storage utilization statistics

### 🐳 Containerized Deployment

- **Docker Compose**: Generate Docker Compose configurations
- **Service Integration**: Integrate Ollama, One-API, Prompt-Optimizer services
- **GPU Support**: Automatic GPU detection and configuration
- **Smart Configuration**: Intelligent port and network setup

### ⚙️ Advanced Features

- **Custom Quantization**: Support multiple quantization types (q4_0, q5_0, q8_0, etc.)
- **Dynamic Docker**: Dynamic Docker image building
- **Parallel Processing**: Optimized caching and parallel execution
- **Comprehensive Logging**: Detailed logging and error handling

## 🚀 Quick Start

### Prerequisites

- **Docker** with GPU support (for CUDA acceleration)
- **rsync** for file synchronization
- **bash** shell environment

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

3. Create your models list file (see [Model File Format](#-model-file-format)):

```bash
touch models.list
```

### Basic Usage

```bash
# Show help
./omo.sh --help

# Download models from models.list
./omo.sh

# Use custom models file
./omo.sh --models-file my-models.list

# Backup a specific model
./omo.sh --backup deepseek-r1:1.5b

# Backup all models
./omo.sh --backup-all

# Restore a model
./omo.sh --restore deepseek-r1:1.5b

# List installed models
./omo.sh --list

# Delete a model
./omo.sh --delete deepseek-r1:1.5b

# Force download (ignore existing)
./omo.sh --force

# Generate Docker Compose
./omo.sh --docker-compose
```

## 📝 Model File Format

Create a `models.list` file with one model per line:

```
# Ollama official models
ollama deepseek-r1:1.5b
ollama llama3.2:3b

# HuggingFace GGUF models (direct import)
hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
hf-gguf hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF
```

### Model Format Types

| Format    | Description                    | Example                                                     |
| --------- | ------------------------------ | ----------------------------------------------------------- |
| `ollama`  | Official Ollama models         | `ollama deepseek-r1:1.5b`                                   |
| `hf-gguf` | HF GGUF models (direct import) | `hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest` |

## 📁 Directory Structure

```
omo/
├── omo.sh                    # Main script
├── models.list               # Model definitions
├── ollama/                   # Ollama data directory
│   └── models/              # Ollama models storage
├── backups/                 # Model backups
└── docker/                 # Docker build contexts (temporary)
```

## 🛠️ Command Line Options

| Option                    | Description                    | Default         |
| ------------------------- | ------------------------------ | --------------- |
| `--models-file FILE`      | Specify models list file       | `./models.list` |
| `--ollama-dir DIR`        | Ollama data directory          | `./ollama`      |
| `--backup-output-dir DIR` | Backup output directory        | `./backups`     |
| `--backup MODEL`          | Backup specific model          | -               |
| `--backup-all`            | Backup all models              | -               |
| `--restore MODEL`         | Restore specific model         | -               |
| `--list`                  | List installed models          | -               |
| `--delete MODEL`          | Delete specific model          | -               |
| `--force`                 | Force download/overwrite       | -               |
| `--docker-compose`        | Generate Docker Compose config | -               |
| `--rebuild`               | Force rebuild Docker images    | -               |
| `--verbose`               | Enable verbose logging         | -               |
| `--help`                  | Show help information          | -               |

## 🐳 Docker Integration

OMO can generate a complete Docker Compose setup with integrated services:

```bash
./omo.sh --docker-compose
```

This creates a `docker-compose.yml` with:

- **Ollama**: Core LLM runtime with GPU support
- **One-API**: API gateway for multiple LLM providers
- **Prompt-Optimizer**: Prompt optimization service
- **ChatGPT-Next-Web**: Web interface for chat interactions

### Generated Services

| Service          | Port  | Description           |
| ---------------- | ----- | --------------------- |
| Ollama           | 11434 | LLM runtime API       |
| One-API          | 3000  | API gateway dashboard |
| Prompt-Optimizer | 8080  | Prompt optimization   |
| ChatGPT-Next-Web | 3001  | Web chat interface    |

## 🔧 Advanced Configuration

### Environment Variables

```bash

# Verbose logging
export VERBOSE="true"
```

### Custom Directories

```bash
# Use custom directories
./omo.sh \
  --ollama-dir /custom/ollama \
  --backup-output-dir /custom/backups \
```

## 🚨 Error Handling

OMO includes comprehensive error handling:

- **Network Issues**: Automatic retry with exponential backoff
- **Disk Space**: Pre-flight disk space validation
- **Corrupted Downloads**: Automatic integrity verification
- **Docker Issues**: Detailed container diagnostics
- **Permission Problems**: Clear permission requirement messages

## 🤝 Contributing

Contributions are welcome! Please feel free to:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Ollama](https://ollama.ai/) - For the excellent LLM runtime
- [llama.cpp](https://github.com/ggerganov/llama.cpp) - For model quantization tools

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/LaiQE/omo/issues)
- **Discussions**: [GitHub Discussions](https://github.com/LaiQE/omo/discussions)

---

**Author**: Chain Lai  
**Repository**: https://github.com/LaiQE/omo
