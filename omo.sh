#!/bin/bash
# =============================================================================
# OMO (oh-my-ollama or Ollama Models Organizer)
# =============================================================================
#
# 🤖 功能概览：
#   📥 模型下载：
#       • 从Ollama官方仓库下载模型
#       • 从HuggingFace仓库下载模型并自动转换量化
#       • 直接下载HuggingFace的GGUF格式模型
#       • 支持断点续传和缓存复用
#       • 智能HuggingFace镜像端点检测
#
#   💾 模型备份：
#       • 完整备份Ollama模型（manifest + blobs）
#       • 备份HuggingFace原始模型文件
#       • MD5校验确保数据完整性
#       • 生成详细备份信息文件
#
#   🔄 模型恢复：
#       • 从备份恢复Ollama模型
#       • 恢复HuggingFace原始模型到缓存
#       • 支持强制覆盖模式
#       • 自动验证文件完整性
#
#   📋 模型管理：
#       • 列出已安装模型及详细信息
#       • 智能删除模型（单个/批量）
#       • 模型完整性检查和验证
#       • 磁盘使用情况统计
#
#   🐳 容器化部署：
#       • 生成Docker Compose配置
#       • 集成Ollama、One-API、Prompt-Optimizer等服务
#       • 自动GPU支持和时区配置
#       • 智能端口和网络配置
#
#   ⚙️  高级特性：
#       • 支持自定义量化类型（q4_0, q5_0, q8_0等）
#       • 动态Docker镜像构建
#       • 并行处理和缓存优化
#       • 详细日志和错误处理
#
# 📝 支持的模型格式：
#   • ollama [model]:[tag]     - Ollama官方模型
#   • huggingface [model] [quant] - HuggingFace模型(需转换)
#   • hf-gguf [model]:[tag]    - HuggingFace GGUF模型(直接导入)
#
# 🔧 环境要求：
#   • Docker (支持GPU可选)
#   • Bash 4.0+
#   • curl, jq (自动安装到容器)
#
# 👨‍💻 作者：Chain Lai
# 📖 详细使用说明请运行：./omo.sh --help
# =============================================================================

set -euo pipefail  # 启用严格的错误处理

#==============================================================================
# 全局配置和变量定义
#==============================================================================
SCRIPT_DIR=""
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODELS_LIST_FILE="${SCRIPT_DIR}/models.list"
# 基础路径配置（可在main函数中被覆盖）
OLLAMA_DATA_DIR="${SCRIPT_DIR}/ollama"
OLLAMA_MODELS_DIR="${OLLAMA_DATA_DIR}/models"
BACKUP_OUTPUT_DIR="${SCRIPT_DIR}/backups"
HF_DOWNLOAD_CACHE_DIR="${SCRIPT_DIR}/hf_download_cache"
HF_ORIGINAL_BACKUP_DIR="${SCRIPT_DIR}/hf_originals"

# 预计算的绝对路径（性能优化）
ABS_OLLAMA_DATA_DIR=""
ABS_HF_DOWNLOAD_CACHE_DIR=""
ABS_HF_ORIGINAL_BACKUP_DIR=""

# HuggingFace镜像配置
HF_ENDPOINT=""  # 初始为空，会在需要时动态检测最优端点


# Docker镜像配置
readonly DOCKER_IMAGE_LLAMA_CPP="ghcr.io/ggml-org/llama.cpp:full-cuda"
readonly DOCKER_IMAGE_OLLAMA="ollama/ollama:latest"
readonly DOCKER_IMAGE_ONE_API="justsong/one-api:latest"
readonly DOCKER_IMAGE_PROMPT_OPTIMIZER="linshen/prompt-optimizer:latest"
readonly DOCKER_IMAGE_CHATGPT_NEXT_WEB="yidadaa/chatgpt-next-web:latest"

# 备份配置

# 运行时配置
VERBOSE="false"  # 详细模式开关

#==============================================================================
# 工具函数
#==============================================================================

# 显示容器日志的工具函数
show_container_logs() {
    local container_name="$1"
    log_error "容器日志:"
    docker logs "$container_name" 2>&1 | tail -10
}

# 获取主机时区
get_host_timezone() {
    # 尝试多种方法获取主机时区
    if command_exists timedatectl; then
        # 优先使用 timedatectl（systemd 系统）
        timedatectl show --property=Timezone --value 2>/dev/null
    elif [[ -L /etc/localtime ]]; then
        # 通过符号链接获取时区
        readlink /etc/localtime | sed 's|.*/zoneinfo/||'
    elif [[ -f /etc/timezone ]]; then
        # 从 /etc/timezone 文件读取
        cat /etc/timezone
    else
        # 默认回退到 UTC
        echo "UTC"
    fi
}

#==============================================================================
# Docker集成模块（HuggingFace模型转换）
#==============================================================================
readonly IMAGE_NAME="hf_downloader"
readonly IMAGE_TAG="latest"
readonly FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# Docker集成内容（嵌入式文件）
# 创建临时构建目录并写入必要文件
create_docker_build_context() {
    local build_dir="$1"
    
    mkdir -p "$build_dir"
    
    # 获取主机时区
    local host_timezone=$(get_host_timezone)
    [[ -z "$host_timezone" ]] && host_timezone="UTC"
    
    # 写入Dockerfile
    cat > "$build_dir/Dockerfile" << EOF
FROM $DOCKER_IMAGE_LLAMA_CPP
WORKDIR /app
ENV DEBIAN_FRONTEND=noninteractive TZ=${host_timezone}
RUN apt-get update && apt-get install -y --no-install-recommends curl aria2 jq tzdata && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    ln -snf /usr/share/zoneinfo/${host_timezone} /etc/localtime && echo ${host_timezone} > /etc/timezone && \
    curl -fsSL https://hf-mirror.com/hfd/hfd.sh -o /app/hfd.sh && chmod +x /app/hfd.sh
COPY convert_model.sh /app/
RUN chmod +x /app/convert_model.sh
ENTRYPOINT ["/app/convert_model.sh"]
EOF
    
    # 写入convert_model.sh
    cat > "$build_dir/convert_model.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
# 简化日志函数（Docker环境专用）
log_info() { printf "[INFO] %s\n" "$1" >&2; }
log_success() { printf "[SUCCESS] %s\n" "$1" >&2; }
log_error() { printf "[ERROR] %s\n" "$1" >&2; }
run_command() {
    local description="$1" verbose="$2"
    shift 2
    log_info "$description"
    if [[ "$verbose" == "true" ]]; then
        "$@"
    else
        if "$@" >/dev/null 2>&1; then
            log_success "${description}完成"
        else
            log_error "${description}失败"
            "$@" 2>&1 | tail -5
            exit 1
        fi
    fi
}
download_model() {
    local model_name="$1" download_dir="$2"
    log_info "下载模型: $model_name"
    if [[ -n "${HF_ENDPOINT:-}" ]]; then
        export HF_ENDPOINT="${HF_ENDPOINT}"
    fi
    local cache_dir="/app/download_cache"
    if [[ -d "$cache_dir" ]]; then
        local model_safe_name=$(echo "$model_name" | sed 's/[\/:]/_/g')
        local cached_model_dir="${cache_dir}/${model_safe_name}"
        
        # 检查是否有未完成的下载（存在.aria2文件）
        if [[ -d "$cached_model_dir" ]] && [[ -n "$(find "$cached_model_dir" -name "*.aria2" 2>/dev/null)" ]]; then
            log_info "检测到未完成的下载，继续下载..."
            export ARIA2C_OPTS="--continue=true --max-tries=10 --retry-wait=3 --split=8 --max-connection-per-server=8 --auto-file-renaming=false"
            if /app/hfd.sh "$model_name" --local-dir "$cached_model_dir" --tool aria2c; then
                rm -f "$cached_model_dir"/*.aria2 2>/dev/null || true
                if [[ -n "$(ls -A "$cached_model_dir" 2>/dev/null)" ]]; then
                    cp -r "$cached_model_dir"/* "$download_dir"/ 2>/dev/null || true
                fi
            else
                log_error "模型下载失败"
                exit 1
            fi
        elif [[ -d "$cached_model_dir" ]] && [[ -n "$(ls -A "$cached_model_dir" 2>/dev/null)" ]]; then
            log_info "使用已缓存的完整模型"
            if [[ -n "$(ls -A "$cached_model_dir" 2>/dev/null)" ]]; then
                cp -r "$cached_model_dir"/* "$download_dir"/ 2>/dev/null || true
            fi
            return 0
        else
            # 全新下载
            mkdir -p "$cached_model_dir"
            export ARIA2C_OPTS="--continue=true --max-tries=10 --retry-wait=3 --split=8 --max-connection-per-server=8 --auto-file-renaming=false"
            if /app/hfd.sh "$model_name" --local-dir "$cached_model_dir" --tool aria2c; then
                rm -f "$cached_model_dir"/*.aria2 2>/dev/null || true
                if [[ -n "$(ls -A "$cached_model_dir" 2>/dev/null)" ]]; then
                    cp -r "$cached_model_dir"/* "$download_dir"/ 2>/dev/null || true
                fi
            else
                log_error "模型下载失败"
                exit 1
            fi
        fi
    else
        if ! /app/hfd.sh "$model_name" --local-dir "$download_dir" --tool aria2c; then
            log_error "模型下载失败"
            exit 1
        fi
    fi
}
convert_to_gguf() {
    local model_dir="$1" output_file="$2" verbose="$3"
    run_command "转换为GGUF格式" "$verbose" \
        python3 /app/convert_hf_to_gguf.py "$model_dir" --outfile "$output_file" --outtype f16
}
quantize_model() {
    local input_file="$1" output_file="$2" quantize_type="$3" verbose="$4"
    run_command "量化模型 (${quantize_type})" "$verbose" \
        /app/llama-quantize "$input_file" "$output_file" "$quantize_type"
    rm -f "$input_file"
}
convert_main() {
    local model_name="" quantize_type="q4_0" gguf_dir="/app/models" verbose=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quantize)
                [[ -z "${2:-}" ]] && { log_error "缺少 --quantize 参数值"; exit 1; }
                quantize_type="$2"; shift 2 ;;
            --gguf-dir)
                [[ -z "${2:-}" ]] && { log_error "缺少 --gguf-dir 参数值"; exit 1; }
                gguf_dir="$2"; shift 2 ;;
            --verbose) verbose=true; shift ;;
            -*) log_error "未知参数: $1"; exit 1 ;;
            *)
                if [[ -z "$model_name" ]]; then
                    model_name="$1"
                else
                    log_error "多余的参数: $1"; exit 1
                fi
                shift ;;
        esac
    done
    if [[ -z "$model_name" ]]; then
        log_error "缺少模型名称参数"; exit 1
    fi
    log_info "处理模型: $model_name (${quantize_type})"
    mkdir -p "$gguf_dir"
    local temp_dir="/tmp/model_download_$$"
    mkdir -p "$temp_dir"
    local model_basename=$(echo "$model_name" | sed 's/\//-/g')
    local final_gguf_file="${gguf_dir}/${model_basename}-${quantize_type}.gguf"
    if [[ -f "$final_gguf_file" ]]; then
        log_info "输出文件已存在，跳过转换"; exit 0
    fi
    local temp_gguf_file="${temp_dir}/${model_basename}.gguf"
    download_model "$model_name" "$temp_dir"
    convert_to_gguf "$temp_dir" "$temp_gguf_file" "$verbose"
    quantize_model "$temp_gguf_file" "$final_gguf_file" "$quantize_type" "$verbose"
    log_success "转换完成: $final_gguf_file"
    if [[ -f "$final_gguf_file" ]]; then
        local file_size=$(du -h "$final_gguf_file" | cut -f1)
        log_info "文件大小: $file_size"
    fi
}
convert_main "$@"
EOF
    
    chmod +x "$build_dir/convert_model.sh"
    log_success "Docker构建上下文创建完成"
}

# 清理临时构建目录
cleanup_docker_build_context() {
    local build_dir="$1"
    if [[ -d "$build_dir" ]]; then
        rm -rf "$build_dir"
    fi
}

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;95m'
readonly NC='\033[0m' # No Color

#==============================================================================
# 日志系统模块
#==============================================================================
log_operation() {
    local operation="$1"
    local target="$2" 
    local status="${3:-开始}"
    
    case "$operation" in
        "backup")
            case "$status" in
                "开始") log_info "备份模型: $target" ;;
                "成功") log_success "模型备份完成: $target" ;;
                "失败") log_error "模型备份失败: $target" ;;
                "存在") log_info "模型备份已存在: $target" ;;
            esac
            ;;
        "restore")
            case "$status" in
                "开始") log_info "恢复模型: $target" ;;
                "成功") log_success "模型恢复完成: $target" ;;
                "失败") log_error "模型恢复失败: $target" ;;
            esac
            ;;
        "download")
            case "$status" in
                "开始") log_info "下载模型: $target" ;;
                "成功") log_success "模型下载完成: $target" ;;  
                "失败") log_error "模型下载失败: $target" ;;
            esac
            ;;
        "check")
            case "$status" in
                "开始") log_info "检查模型: $target" ;;
                "存在") log_info "模型已存在: $target" ;;
                "不存在") log_info "模型不存在: $target" ;;
            esac
            ;;
    esac
}

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_build() {
    printf "${CYAN}[BUILD]${NC} %s\n" "$1"
}

log_docker() {
    printf "${CYAN}[DOCKER]${NC} %s\n" "$1"
}

log_ollama() {
    printf "${MAGENTA}[OLLAMA]${NC} %s\n" "$1"
}

# HuggingFace端点智能检测函数
detect_optimal_hf_endpoint() {
    # 如果已经检测过，直接返回
    if [[ "$HF_ENDPOINT_DETECTED" == "true" ]]; then
        return 0
    fi
    
    local cache_file="/tmp/.hf_endpoint_cache"
    local cache_timeout=3600  # 缓存1小时
    
    # 检查缓存是否有效
    if [[ -f "$cache_file" ]]; then
        local cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        if [[ $((current_time - cache_time)) -lt $cache_timeout ]]; then
            HF_ENDPOINT=$(cat "$cache_file")
            HF_ENDPOINT_DETECTED="true"
            log_info "使用缓存的HuggingFace端点: $HF_ENDPOINT"
            return 0
        fi
    fi
    
    local hf_official="https://huggingface.co"
    local hf_mirror="https://hf-mirror.com"
    local timeout=3
    
    log_info "检测最优HuggingFace端点..."
    
    # 测试单个端点的函数
    test_endpoint() {
        local endpoint="$1"
        local host=$(echo "$endpoint" | sed 's|https\?://||' | cut -d'/' -f1)
        
        # 使用ping测试连通性和延迟
        local ping_result=$(ping -c 1 -W $timeout "$host" 2>/dev/null | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/')
        
        if [[ -n "$ping_result" ]]; then
            # 将延迟转换为毫秒整数
            local latency=$(echo "$ping_result" | cut -d'.' -f1)
            [[ -z "$latency" ]] && latency=0
            echo "$endpoint:$latency"
        else
            echo "$endpoint:999999"  # 表示无法访问
        fi
    }
    
    # 并行测试
    local official_result="" mirror_result=""
    {
        official_result=$(test_endpoint "$hf_official")
    } &
    local pid1=$!
    
    {
        mirror_result=$(test_endpoint "$hf_mirror")
    } &
    local pid2=$!
    
    # 等待测试完成
    wait $pid1 $pid2
    
    # 解析结果
    local official_latency="${official_result#*:}"
    local mirror_latency="${mirror_result#*:}"
    
    # 收集可用端点
    local available_endpoints=()
    [[ "$official_latency" != "999999" ]] && available_endpoints+=("$hf_official:$official_latency")
    [[ "$mirror_latency" != "999999" ]] && available_endpoints+=("$hf_mirror:$mirror_latency")
    
    # 检查是否有可用端点
    if [[ ${#available_endpoints[@]} -eq 0 ]]; then
        log_error "无法访问任何HuggingFace端点，脚本中止"
        exit 1
    fi
    
    # 选择延迟最低的端点
    local best_endpoint=""
    local best_latency=999999
    for endpoint_info in "${available_endpoints[@]}"; do
        local endpoint="${endpoint_info%:*}"
        local latency="${endpoint_info#*:}"
        if [[ $latency -lt $best_latency ]]; then
            best_latency=$latency
            best_endpoint=$endpoint
        fi
    done
    
    local selected_endpoint="$best_endpoint"
    log_info "选择最优端点: $selected_endpoint (${best_latency}ms)"
    
    # 更新全局变量并缓存结果
    HF_ENDPOINT="$selected_endpoint"
    HF_ENDPOINT_DETECTED="true"
    echo "$selected_endpoint" > "$cache_file"
    
    return 0
}

# 格式化字节大小为人类可读格式
format_bytes() {
    local bytes="$1"
    
    # 使用单次awk调用减少开销，预定义常量提高可读性
    awk -v b="$bytes" '
    BEGIN {
        if (b >= 1073741824) printf "%.1fGB", b / 1073741824
        else if (b >= 1048576) printf "%.1fMB", b / 1048576  
        else printf "%.1fKB", b / 1024
    }'
}

# 验证模型格式是否正确
validate_model_format() {
    local model_spec="$1"
    if [[ "$model_spec" != *":"* ]]; then
        log_error "模型格式错误，应为 '模型名:版本'，例如 'llama2:7b'"
        return 1
    fi
    return 0
}

# 等待Ollama容器就绪
wait_for_ollama_ready() {
    local container_name="$1"
    local max_attempts=120  # 增加到120秒
    local attempt=0
    
    log_info "等待Ollama服务启动..."
    
    while (( attempt < max_attempts )); do
        # 首先检查容器是否还在运行
        if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then
            log_error "容器 $container_name 已停止运行"
            show_container_logs "$container_name"
            return 1
        fi
        
        # 检查ollama服务是否就绪
        if docker exec "$container_name" ollama list &>/dev/null; then
            log_success "Ollama服务已就绪"
            return 0
        fi
        
        # 每10秒显示一次进度
        if (( attempt % 10 == 0 && attempt > 0 )); then
            log_info "等待中... ($attempt/$max_attempts 秒)"
        fi
        
        sleep 1
        ((attempt++))
    done
    
    log_error "等待Ollama服务就绪超时 ($max_attempts 秒)"
    show_container_logs "$container_name"
    return 1
}

# 构建完整的Docker运行命令
build_full_docker_cmd() {
    local container_name="$1"
    local use_gpu="${2:-true}"
    local include_hf_token="${3:-false}"
    local extra_env=()
    local extra_volumes=()
    
    # 处理额外的环境变量和挂载卷参数
    shift 3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)
                extra_env+=("$2")
                shift 2
                ;;
            --volume)
                extra_volumes+=("$2")
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    
    local docker_cmd=("docker" "run" "--name" "$container_name" "--rm" "-t")
    
    # GPU支持
    if [[ "$use_gpu" == "true" ]]; then
        docker_cmd+=("--gpus" "all")
    fi
    
    # HF Token支持
    if [[ "$include_hf_token" == "true" && -n "${HF_TOKEN:-}" ]]; then
        docker_cmd+=("-e" "HF_TOKEN=${HF_TOKEN}")
    fi
    
    # 基础环境变量
    docker_cmd+=("-e" "HF_ENDPOINT=${HF_ENDPOINT:-https://hf-mirror.com}")
    docker_cmd+=("-e" "PYTHONUNBUFFERED=1")
    docker_cmd+=("-e" "TERM=xterm-256color")
    docker_cmd+=("-v" "/etc/localtime:/etc/localtime:ro")
    docker_cmd+=("-e" "TZ=${HOST_TIMEZONE:-UTC}")
    
    # 添加额外的环境变量
    for env_var in "${extra_env[@]}"; do
        docker_cmd+=("-e" "$env_var")
    done
    
    # 添加额外的挂载卷
    for volume in "${extra_volumes[@]}"; do
        docker_cmd+=("-v" "$volume")
    done
    
    printf '%s\n' "${docker_cmd[@]}"
}

# 通用cleanup函数生成器
create_cleanup_function() {
    local cleanup_name="$1"
    shift
    local cleanup_items_str="$*"
    
    # 动态创建cleanup函数
    eval "${cleanup_name}() {
        local item
        local cleanup_items=($cleanup_items_str)
        for item in \"\${cleanup_items[@]}\"; do
            if [[ -f \"\$item\" ]]; then
                rm -f \"\$item\"
            elif [[ -d \"\$item\" ]]; then
                rm -rf \"\$item\"
            elif [[ \"\$item\" =~ ^[a-zA-Z0-9_-]+\$ ]]; then
                # 假设是容器名
                docker rm -f \"\$item\" &>/dev/null || true
            fi
        done
    }"
}

# 设置cleanup trap的通用函数
setup_cleanup_trap() {
    local cleanup_function="$1"
    local signals="${2:-EXIT INT TERM}"
    trap '$cleanup_function' "$signals"
}

# Ollama模型列表缓存
declare -g OLLAMA_MODELS_CACHE=""
declare -g OLLAMA_CACHE_INITIALIZED="false"

# 临时Ollama容器管理
declare -g TEMP_OLLAMA_CONTAINER=""
declare -g EXISTING_OLLAMA_CONTAINER=""

# 全局清理函数管理
declare -g GLOBAL_CLEANUP_FUNCTIONS=()
declare -g GLOBAL_CLEANUP_INITIALIZED="false"

# HuggingFace端点检测状态管理
declare -g HF_ENDPOINT_DETECTED="false"

# 全局清理函数管理
add_cleanup_function() {
    local func_name="$1"
    if [[ -z "$func_name" ]]; then
        log_error "清理函数名称不能为空"
        return 1
    fi
    
    # 检查函数是否已存在，避免重复添加
    local func
    for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
        if [[ "$func" == "$func_name" ]]; then
            return 0  # 已存在，直接返回
        fi
    done
    
    GLOBAL_CLEANUP_FUNCTIONS+=("$func_name")
    
    # 如果是第一次添加，设置全局 trap
    if [[ "$GLOBAL_CLEANUP_INITIALIZED" == "false" ]]; then
        trap 'execute_global_cleanup' EXIT INT TERM
        GLOBAL_CLEANUP_INITIALIZED="true"
        log_info "初始化全局清理机制"
    fi
}

# 执行所有清理函数
execute_global_cleanup() {
    local exit_code=$?
    local func
    
    # 如果是中断信号，显示中断消息
    if [[ $exit_code -eq 130 ]]; then  # Ctrl+C
        log_warning "检测到中断信号 (Ctrl+C)"
    elif [[ $exit_code -eq 143 ]]; then  # SIGTERM
        log_warning "检测到终止信号 (SIGTERM)"
    fi
    
    for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
        if declare -f "$func" >/dev/null 2>&1; then
            log_info "执行清理函数: $func"
            "$func"
        fi
    done
    
    # 如果是中断，退出
    if [[ $exit_code -eq 130 || $exit_code -eq 143 ]]; then
        exit $exit_code
    fi
}

# 移除清理函数
remove_cleanup_function() {
    local func_name="$1"
    local new_array=()
    local func
    
    for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
        if [[ "$func" != "$func_name" ]]; then
            new_array+=("$func")
        fi
    done
    
    GLOBAL_CLEANUP_FUNCTIONS=("${new_array[@]}")
}

# 初始化Ollama模型列表缓存
init_ollama_cache() {
    if [[ "$OLLAMA_CACHE_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    log_info "初始化Ollama模型列表缓存..."
    
    # 使用统一的容器逻辑获取模型列表
    log_info "获取Ollama模型列表..."
    
    # 获取模型列表并缓存
    OLLAMA_MODELS_CACHE=$(execute_ollama_command_with_output "list" | awk 'NR>1 {print $1}' | sort)
    if [[ -n "$OLLAMA_MODELS_CACHE" ]]; then
        OLLAMA_CACHE_INITIALIZED="true"
        log_success "Ollama模型列表缓存初始化完成"
    else
        log_info "Ollama模型列表为空"
        OLLAMA_MODELS_CACHE=""
        OLLAMA_CACHE_INITIALIZED="true"
    fi
    
    return 0
}

# 检查Ollama模型是否存在（使用缓存）
check_ollama_model_exists() {
    local model_name="$1"
    
    # 确保缓存已初始化
    if ! init_ollama_cache; then
        log_error "无法初始化Ollama模型缓存"
        return 1
    fi
    
    # 在缓存中查找模型
    if echo "$OLLAMA_MODELS_CACHE" | grep -q "^${model_name}$"; then
        return 0
    else
        return 1
    fi
}


# 验证模型业务逻辑完整性
validate_model_business_integrity() {
    local backup_file="$1"
    
    # 创建临时目录提取备份文件
    local temp_dir=$(mktemp -d) || { log_error "无法创建临时目录"; return 1; }
    
    # 清理函数
    cleanup_temp_business() {
        [[ -d "${temp_dir:-}" ]] && docker_rm_rf "$temp_dir"
    }
    add_cleanup_function "cleanup_temp_business"
    
    # 提取备份文件到临时目录
    if ! docker run --rm --entrypoint="" -v "$(dirname "$backup_file"):/data" -v "$temp_dir:/temp" hf_downloader:latest sh -c "
        cd /data && tar -xf '$(basename "$backup_file")' -C /temp 2>/dev/null
    "; then
        log_error "无法提取备份文件进行业务逻辑检查"
        cleanup_temp_business
        return 1
    fi
    
    # 查找manifest文件
    local manifest_files=()
    while IFS= read -r -d '' manifest; do
        manifest_files+=("$manifest")
    done < <(find "$temp_dir" -path "*/manifests/*" -type f -print0 2>/dev/null)
    
    if [[ ${#manifest_files[@]} -eq 0 ]]; then
        log_error "备份中未找到manifest文件"
        cleanup_temp_business
        return 1
    fi
    
    # 检查每个manifest引用的blob文件
    local missing_blobs=0
    local total_blobs=0
    
    for manifest_file in "${manifest_files[@]}"; do
        if [[ -f "$manifest_file" ]]; then
            # 解析manifest文件中的blob引用
            local blob_digests
            blob_digests=$(grep -o '"digest":"sha256:[a-f0-9]\{64\}"' "$manifest_file" 2>/dev/null | sed 's/"digest":"sha256:\([a-f0-9]\{64\}\)"/\1/g')
            
            for digest in $blob_digests; do
                ((total_blobs++))
                local blob_path="$temp_dir/blobs/sha256-$digest"
                if [[ ! -f "$blob_path" ]]; then
                    log_error "缺少blob文件: sha256-$digest"
                    ((missing_blobs++))
                fi
            done
        fi
    done
    
    cleanup_temp_business
    remove_cleanup_function "cleanup_temp_business"
    
    if [[ $missing_blobs -gt 0 ]]; then
        log_error "发现 $missing_blobs/$total_blobs 个blob文件缺失"
        return 1
    fi
    
    log_success "模型业务逻辑完整性验证通过 ($total_blobs 个blob文件)"
    return 0
}


# 清理不完整的模型
cleanup_incomplete_model() {
    local model_name="$1"
    local model_tag="$2"
    local full_model_name="${model_name}:${model_tag}"
    
    log_warning "检测到不完整的模型，正在清理: $full_model_name"
    
    # 确定manifest文件路径
    local manifest_file
    if [[ "$model_name" == hf.co/* ]]; then
        # HuggingFace GGUF模型
        manifest_file="$OLLAMA_MODELS_DIR/manifests/$model_name/$model_tag"
    elif [[ "$model_name" == *"/"* ]]; then
        # 用户分享的模型
        local user_name="${model_name%/*}"
        local repo_name="${model_name#*/}"
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/$user_name/$repo_name/$model_tag"
    else
        # 官方模型
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/library/$model_name/$model_tag"
    fi
    
    # 删除manifest文件
    if [[ -f "$manifest_file" ]]; then
        if docker_rm_rf "$manifest_file"; then
            log_info "已删除不完整的manifest文件: $manifest_file"
        else
            log_warning "无法删除manifest文件: $manifest_file"
        fi
    fi
    
    # 清除缓存，强制重新检查
    OLLAMA_CACHE_INITIALIZED="false"
    OLLAMA_MODELS_CACHE=""
    
    log_success "不完整模型清理完成: $full_model_name"
}

# 验证模型安装后的完整性
verify_model_after_installation() {
    local model_name="$1"
    local model_tag="$2"
    local full_model_name="${model_name}:${model_tag}"
    
    log_info "验证模型安装完整性: $full_model_name"
    
    # 初始化缓存以提高完整性检查性能
    ensure_cache_initialized
    
    # 等待一下让文件系统同步
    sleep 2
    
    # 检查模型完整性（使用缓存优化）
    local model_spec="${model_name}:${model_tag}"
    if verify_integrity "model" "$model_spec" "use_cache:true,check_blobs:true"; then
        log_success "模型安装完整性验证通过: $full_model_name"
        return 0
    else
        log_error "模型安装不完整，正在清理: $full_model_name"
        cleanup_incomplete_model "$model_name" "$model_tag"
        return 1
    fi
}

# 简化的模型检查函数
check_ollama_model() {
    local model_name="$1"
    local model_tag="$2"
    local full_model_name="${model_name}:${model_tag}"
    
    # 首先尝试通过Ollama容器检查（最准确）
    if check_ollama_model_exists "$full_model_name"; then
        log_success "Ollama模型已存在: $full_model_name"
        return 0
    fi
    
    # 如果Ollama容器检查失败，进行完整性检查（使用缓存优化）
    local model_spec="${model_name}:${model_tag}"
    if verify_integrity "model" "$model_spec" "use_cache:true,check_blobs:true"; then
        log_success "Ollama模型已存在（文件系统验证）: $full_model_name"
        return 0
    else
        log_warning "Ollama模型不存在或不完整: $full_model_name"
        return 1
    fi
}

# 解析模型规格（model:version格式）
parse_model_spec() {
    local model_spec="$1"
    local -n name_var="$2"
    local -n version_var="$3"
    
    if ! validate_model_format "$model_spec"; then
        return 1
    fi
    
    name_var="${model_spec%:*}"
    version_var="${model_spec#*:}"
    return 0
}

# 初始化绝对路径
init_paths() {
    # 获取绝对路径，如果目录不存在则先创建父目录
    mkdir -p "${OLLAMA_DATA_DIR}" "${HF_DOWNLOAD_CACHE_DIR}" "${HF_ORIGINAL_BACKUP_DIR}" || {
        log_error "无法创建必要目录"
        return 1
    }
    
    ABS_OLLAMA_DATA_DIR="$(realpath "${OLLAMA_DATA_DIR}")"
    ABS_HF_DOWNLOAD_CACHE_DIR="$(realpath "${HF_DOWNLOAD_CACHE_DIR}")"
    ABS_HF_ORIGINAL_BACKUP_DIR="$(realpath "${HF_ORIGINAL_BACKUP_DIR}")"
    
}

# Docker backup helper functions

# Docker辅助函数 - 重命名分卷文件（从.000,.001,.002格式到.001,.002,.003格式）

# Docker helper function - list tar content directly

# Docker文件系统操作辅助函数
docker_rm_rf() {
    local target_path="$1"
    local parent_dir
    local target_name
    
    # 安全检查：防止删除空路径或根目录
    if [[ -z "$target_path" || "$target_path" == "/" ]]; then
        log_error "安全删除: 路径为空或根目录，拒绝删除"
        return 1
    fi
    
    # 获取父目录和目标名称
    parent_dir="$(dirname "$target_path")"
    target_name="$(basename "$target_path")"
    
    # log_info "使用Docker删除: $target_path"
    
    # 使用Docker容器以root权限删除文件/目录，覆盖ENTRYPOINT
    docker run --rm --entrypoint="" \
        -v "$parent_dir:/work" \
        "$FULL_IMAGE_NAME" \
        rm -rf "/work/$target_name" 2>/dev/null
}

docker_mkdir_p() {
    local target_path="$1"
    local parent_dir
    local target_name
    
    # 如果目录已存在，直接返回
    [[ -d "$target_path" ]] && return 0
    
    # 获取父目录和目标名称
    parent_dir="$(dirname "$target_path")"
    target_name="$(basename "$target_path")"
    
    
    # 使用Docker容器以root权限创建目录，覆盖ENTRYPOINT
    if docker run --rm --entrypoint="" --user root \
        -v "$parent_dir:/work" \
        "$FULL_IMAGE_NAME" \
        sh -c "mkdir -p /work/$target_name" 2>/dev/null; then
        return 0
    else 
        log_error "Docker创建目录失败: $target_path" >&2
        return 1
    fi
}


# 确保hf_downloader镜像存在
ensure_hf_downloader_image() {
    if ! docker image inspect "$FULL_IMAGE_NAME" &>/dev/null; then
        log_info "构建 $FULL_IMAGE_NAME 镜像..."
        if ! build_docker_image; then
            log_error "$FULL_IMAGE_NAME 镜像构建失败"
            return 1
        fi
        log_success "$FULL_IMAGE_NAME 镜像构建完成"
    fi
    return 0
}


# 确保ollama/ollama镜像存在
ensure_ollama_image() {
    if ! docker image inspect "$DOCKER_IMAGE_OLLAMA" &>/dev/null; then
        log_info "拉取 $DOCKER_IMAGE_OLLAMA 镜像..."
        if ! docker pull "$DOCKER_IMAGE_OLLAMA"; then
            log_error "$DOCKER_IMAGE_OLLAMA 镜像拉取失败"
            return 1
        fi
        log_success "$DOCKER_IMAGE_OLLAMA 镜像拉取完成"
    fi
    return 0
}

# 查找运行中的Ollama容器
find_running_ollama_container() {
    # 检查是否有运行中的 Ollama 容器
    local running_containers
    running_containers=$(docker ps --format "{{.Names}}" --filter "ancestor=ollama/ollama")
    
    if [[ -n "$running_containers" ]]; then
        # 找到第一个运行中的容器
        EXISTING_OLLAMA_CONTAINER=$(echo "$running_containers" | head -n1)
        log_info "找到运行中的Ollama容器: $EXISTING_OLLAMA_CONTAINER"
        return 0
    fi
    
    # 检查本地11434端口是否有服务响应（可能是外部容器）
    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 2 http://localhost:11434/api/version >/dev/null 2>&1; then
            # 找到使用11434端口的容器
            local port_container
            port_container=$(docker ps --format "{{.Names}}" --filter "publish=11434")
            if [[ -n "$port_container" ]]; then
                EXISTING_OLLAMA_CONTAINER=$(echo "$port_container" | head -n1)
                log_info "找到使用11434端口的Ollama容器: $EXISTING_OLLAMA_CONTAINER"
                return 0
            fi
        fi
    fi
    
    EXISTING_OLLAMA_CONTAINER=""
    return 1
}

# 启动临时Ollama容器
start_temp_ollama_container() {
    if [[ -n "$TEMP_OLLAMA_CONTAINER" ]]; then
        # 检查临时容器是否还在运行
        if docker ps -q --filter "name=^${TEMP_OLLAMA_CONTAINER}$" | grep -q .; then
            log_info "临时Ollama容器仍在运行: $TEMP_OLLAMA_CONTAINER"
            return 0
        else
            log_info "临时Ollama容器已停止，重新启动"
            TEMP_OLLAMA_CONTAINER=""
        fi
    fi
    
    # 确保 Ollama 镜像存在
    ensure_ollama_image || return 1
    
    TEMP_OLLAMA_CONTAINER="ollama-temp-$$"
    
    log_info "启动临时Ollama容器: $TEMP_OLLAMA_CONTAINER"
    
    # 构建容器启动命令
    local cmd=("docker" "run" "-d" "--name" "$TEMP_OLLAMA_CONTAINER")
    cmd+=("-e" "HF_ENDPOINT=${HF_ENDPOINT}")
    cmd+=("--gpus" "all")
    cmd+=("-v" "${ABS_OLLAMA_DATA_DIR}:/root/.ollama")
    cmd+=("-p" "11435:11434")  # 使用不同端口避免冲突
    cmd+=("$DOCKER_IMAGE_OLLAMA")
    
    # 启动容器
    local start_output
    if start_output=$("${cmd[@]}" 2>&1); then
        log_info "临时容器启动成功，ID: ${start_output:0:12}"
        
        # 等待服务就绪
        if wait_for_ollama_ready "$TEMP_OLLAMA_CONTAINER"; then
            log_success "临时Ollama容器就绪: $TEMP_OLLAMA_CONTAINER"
            # 设置清理陷阱
            setup_temp_container_cleanup
            return 0
        else
            log_error "临时Ollama容器启动失败"
            docker rm -f "$TEMP_OLLAMA_CONTAINER" &>/dev/null
            TEMP_OLLAMA_CONTAINER=""
            return 1
        fi
    else
        log_error "无法启动临时Ollama容器"
        log_error "Docker启动错误: $start_output"
        TEMP_OLLAMA_CONTAINER=""
        return 1
    fi
}

# 清理临时Ollama容器
cleanup_temp_ollama_container() {
    if [[ -n "$TEMP_OLLAMA_CONTAINER" ]]; then
        log_info "清理临时Ollama容器: $TEMP_OLLAMA_CONTAINER"
        docker rm -f "$TEMP_OLLAMA_CONTAINER" &>/dev/null
        TEMP_OLLAMA_CONTAINER=""
    fi
}

# 设置临时容器清理陷阱
setup_temp_container_cleanup() {
    add_cleanup_function "cleanup_temp_ollama_container"
}

# 统一的Ollama命令执行函数
execute_ollama_command() {
    local action="$1"
    shift
    local args=("$@")
    
    log_info "执行Ollama命令: $action ${args[*]}"
    
    # 首先查找运行中的Ollama容器
    if find_running_ollama_container; then
        log_info "使用现有Ollama容器: $EXISTING_OLLAMA_CONTAINER"
        log_info "执行命令: docker exec $EXISTING_OLLAMA_CONTAINER ollama $action ${args[*]}"
        if docker exec "$EXISTING_OLLAMA_CONTAINER" ollama "$action" "${args[@]}"; then
            return 0
        else
            log_error "在现有容器中执行Ollama命令失败: $action ${args[*]}"
            return 1
        fi
    else
        # 没有找到运行中的容器，启动临时容器
        log_info "未找到运行中的Ollama容器，启动临时容器"
        if start_temp_ollama_container; then
            log_info "在临时容器中执行命令: docker exec $TEMP_OLLAMA_CONTAINER ollama $action ${args[*]}"
            if docker exec "$TEMP_OLLAMA_CONTAINER" ollama "$action" "${args[@]}"; then
                return 0
            else
                log_error "在临时容器中执行Ollama命令失败: $action ${args[*]}"
                return 1
            fi
        else
            log_error "无法启动临时Ollama容器"
            return 1
        fi
    fi
}

# 执行Ollama命令并获取输出
execute_ollama_command_with_output() {
    local action="$1"
    shift
    local args=("$@")
    
    # 首先查找运行中的Ollama容器
    if find_running_ollama_container; then
        docker exec "$EXISTING_OLLAMA_CONTAINER" ollama "$action" "${args[@]}" 2>/dev/null
    else
        # 没有找到运行中的容器，启动临时容器
        if start_temp_ollama_container; then
            docker exec "$TEMP_OLLAMA_CONTAINER" ollama "$action" "${args[@]}" 2>/dev/null
        else
            return 1
        fi
    fi
}


# 显示使用帮助
show_help() {
    cat << 'EOF'
🤖 OMO - Oh My Ollama / Ollama Models Organizer

使用方法:
  ./omo.sh [OPTIONS]

选项:
  --models-file FILE    指定模型列表文件 (默认: ./models.list)
  --ollama-dir DIR      指定Ollama数据目录 (默认: ./ollama)
  --hf-backup-dir DIR   指定HuggingFace原始模型备份目录 (默认: ./hf_originals)
  --install             安装/下载模型 (覆盖默认的仅检查行为)
  --check-only          仅检查模型状态，不下载 (默认行为)
  --force-download      强制重新下载所有模型 (自动启用安装模式)
  --verbose             显示详细日志
  --hf-token TOKEN      HuggingFace访问令牌
  --rebuild             强制重新构建Docker镜像
  --list                列出已安装的Ollama模型及详细信息
  --backup MODEL        备份指定模型 (格式: 模型名:版本)
  --backup-all          备份所有模型
  --restore FILE        恢复指定备份文件
  --remove MODEL        删除指定模型
  --remove-all          删除所有模型
  --backup-dir DIR      备份目录 (默认: ./backups)
  --force               强制操作（跳过确认）
  --generate-compose    生成docker-compose.yaml文件（基于models.list）
  --help                显示帮助信息

模型列表文件格式:
  ollama deepseek-r1:1.5b
  huggingface microsoft/DialoGPT-medium q4_0
  hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest

下载缓存:
  HuggingFace模型下载支持断点续传和缓存复用
  缓存目录: ./hf_download_cache (自动创建)
  每个模型有独立的缓存子目录
  中断后重新运行脚本将恢复下载，完成后自动缓存

原始备份:
  HuggingFace模型转换完成后自动备份原始文件
  备份目录: ./hf_originals (自动创建)  
  备份格式: 
EOF
    cat << 'EOF'
  备份格式: 目录复制 (模型名_original/)
  自动生成: MD5校验文件 (模型名_original.md5)
  备份信息文件: 模型名_original_info.txt (包含文件列表和MD5校验)
  用途: HuggingFace API调用、重新量化、模型恢复等

Ollama模型备份:
  支持完整的Ollama模型备份和恢复
  备份目录: ./backups (默认，可通过--backup-dir指定)
  备份格式: 目录复制 (模型名/)
  包含内容: manifest文件和所有blob数据
  自动生成: MD5校验文件和详细信息文件
  
备份特性:
  - 直接复制备份，无压缩处理，备份和恢复速度极快
  - MD5校验确保文件完整性
  - 每个模型独立文件夹，便于管理

示例:
  # 检查模型状态 (默认行为)
  ./omo.sh
  
  # 安装/下载缺失的模型
  ./omo.sh --install
  
  # 仅检查状态 (同默认行为)
  ./omo.sh --check-only
  
  # 列出已安装的模型
  ./omo.sh --list
  
  # 备份模型
  ./omo.sh --backup tinyllama:latest
  
  # 删除模型
  ./omo.sh --remove llama2:7b --force

EOF
}

# 检查依赖
# 检查GPU支持
check_gpu_support() {
    # 检查是否支持NVIDIA GPU
    if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
        return 0  # 支持GPU
    fi
    return 1  # 不支持GPU
}

check_dependencies() {
    local missing_deps=()
    
    # 检查 docker
    if ! command_exists docker; then
        missing_deps+=("docker")
        log_error "Docker 未安装或不在 PATH 中"
    else
        # 检查 Docker 守护进程是否运行
        if ! docker info &> /dev/null; then
            log_error "Docker 已安装但守护进程未运行，请启动 Docker 服务"
            return 1
        fi
    fi
    
    # 检查 tar
    if ! command_exists tar; then
        missing_deps+=("tar")
        log_error "tar 未安装，用于模型文件打包/解包"
    fi
    
    # 如果有缺失的依赖，给出提示并退出
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少必需的系统依赖: ${missing_deps[*]}"
        log_error "请安装缺失的依赖后重新运行脚本"
        return 1
    fi
    
    # 检查GPU支持（必需项）
    if ! check_gpu_support; then
        log_error "未检测到NVIDIA GPU支持，此脚本需要GPU环境"
        log_error "请确保：1) 安装了NVIDIA驱动  2) 安装了nvidia-smi工具"
        return 1
    fi
    
    log_info "检测到GPU支持，将启用GPU加速"
    
    # 所有依赖检查通过，静默返回
    return 0
}

# 构建Docker镜像 - 集成版本
build_docker_image() {
    log_build "构建Docker镜像: $FULL_IMAGE_NAME"
    
    # 创建临时构建目录
    local temp_build_dir="/tmp/docker_build_$$"
    
    # 保存当前的trap设置
    local original_trap
    original_trap=$(trap -p EXIT | sed "s/trap -- '//" | sed "s/' EXIT//")
    
    # 设置复合trap - 修复shellcheck SC2089/SC2090
    if [[ -n "$original_trap" ]]; then
        trap "cleanup_docker_build_context '$temp_build_dir'; $original_trap" EXIT
    else
        trap "cleanup_docker_build_context '$temp_build_dir'" EXIT
    fi
    
    # 创建构建上下文
    create_docker_build_context "$temp_build_dir"
    
    # 构建支持CUDA的镜像
    local build_args=()
    log_build "构建支持CUDA的镜像，请耐心等待..."
    build_args+=("--build-arg" "USE_CUDA=true")
    
    # 执行构建命令
    local docker_build_cmd=("docker" "build" "${build_args[@]}" "-t" "$FULL_IMAGE_NAME" "$temp_build_dir")
    
    if "${docker_build_cmd[@]}"; then
        log_success "Docker镜像构建完成: $FULL_IMAGE_NAME"
        cleanup_docker_build_context "$temp_build_dir"
        # 恢复原始trap
        if [[ -n "$original_trap" ]]; then
            trap '$original_trap' EXIT
        else
            trap - EXIT
        fi
        return 0
    else
        log_error "Docker镜像构建失败"
        cleanup_docker_build_context "$temp_build_dir"
        # 恢复原始trap
        if [[ -n "$original_trap" ]]; then
            trap '$original_trap' EXIT
        else
            trap - EXIT
        fi
        exit 1
    fi
}


# 解析模型列表文件
parse_models_list() {
    local models_file="$1"
    local -n models_array=${2:-models}
    
    if [[ ! -f "$models_file" ]]; then
        log_error "模型列表文件不存在: $models_file"
        return 1
    fi
    
    log_info "解析模型列表文件: $models_file"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释行
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # 使用空格分隔解析模型信息: 模型类型 模型名称 [量化类型]
        read -r model_type model_name quantization <<< "$line"
        
        if [[ -n "$model_type" && -n "$model_name" ]]; then
            if [[ "$model_type" == "ollama" || "$model_type" == "huggingface" || "$model_type" == "hf-gguf" ]]; then
                # 如果有量化类型，添加到模型信息中
                if [[ -n "$quantization" ]]; then
                    models_array+=("$model_type:$model_name:$quantization")
                    log_info "添加模型: $model_type -> $model_name:$quantization"
                else
                    models_array+=("$model_type:$model_name")
                    log_info "添加模型: $model_type -> $model_name"
                fi
            else
                log_warning "未知模型类型: $model_type (行: $line)"
            fi
        else
            log_warning "忽略无效行: $line"
        fi
    done < "$models_file"
    
    # 检查是否找到有效模型
    if [[ ${#models_array[@]} -eq 0 ]]; then
        log_warning "================================ WARNING ================================"
        log_warning "No valid models found in models.list file!"
        log_warning "All model entries are either commented out or invalid."
        log_warning ""
        log_warning "Please edit the models.list file:"
        log_warning "1. Uncomment (remove # at the beginning) the models you need"
        log_warning "2. Add your own model configurations"
        log_warning "3. Check model search URLs in the comments for available models"
        log_warning ""
        log_warning "Examples:"
        log_warning "  ollama deepseek-r1:1.5b"
        log_warning "  huggingface Qwen/Qwen3-0.6B q4_0"
        log_warning "  hf-gguf hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF"
        log_warning "====================================================================="
        echo
    else
        log_info "共解析到 ${#models_array[@]} 个模型"
    fi
}

# 检查HuggingFace GGUF模型是否存在（通过Ollama检查）
check_hf_gguf_model() {
    local model_name="$1"
    local model_tag="$2"
    local full_model_name="${model_name}:${model_tag}"
    
    
    # 使用容器检查
    if check_ollama_model_exists "$full_model_name"; then
        log_success "HuggingFace GGUF模型已存在: $full_model_name"
        return 0
    fi
    
    log_warning "HuggingFace GGUF模型不存在: $full_model_name"
    return 1
}

# 生成Ollama模型名称
generate_ollama_model_name() {
    local model_name="$1"
    local quantize_type="$2"
    
    # 清理量化类型
    local clean_quant=$(echo "${quantize_type}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    
    # 使用统一的命名函数进行Ollama模型名称转换
    local full_name_clean=$(get_safe_model_name "$model_name" "ollama")
    
    # 为从HuggingFace下载的模型添加识别前缀和量化后缀
    echo "hf-${full_name_clean}:${clean_quant}"
}

# 下载Ollama模型
download_ollama_model() {
    local model_name="$1"
    local model_tag="$2"
    
    log_ollama "开始下载Ollama模型: ${model_name}:${model_tag}"
    
    if execute_ollama_command "pull" "${model_name}:${model_tag}"; then
        log_success "Ollama模型下载完成: ${model_name}:${model_tag}"
        
        # 验证下载后的模型完整性
        if verify_model_after_installation "$model_name" "$model_tag"; then
            log_success "模型完整性验证通过: ${model_name}:${model_tag}"
            return 0
        else
            log_error "模型完整性验证失败，模型已被清理: ${model_name}:${model_tag}"
            return 1
        fi
    else
        log_error "Ollama模型下载失败: ${model_name}:${model_tag}"
        return 1
    fi
}

# 下载HuggingFace GGUF模型（通过Ollama直接下载）
download_hf_gguf_model() {
    local model_name="$1"
    local model_tag="$2"
    local full_model_name="${model_name}:${model_tag}"
    
    log_ollama "开始下载HuggingFace GGUF模型: $full_model_name"
    
    if execute_ollama_command "pull" "$full_model_name"; then
        log_success "HuggingFace GGUF模型下载完成: $full_model_name"
        
        # 验证下载后的模型完整性
        if verify_model_after_installation "$model_name" "$model_tag"; then
            log_success "模型完整性验证通过: $full_model_name"
            return 0
        else
            log_error "模型完整性验证失败，模型已被清理: $full_model_name"
            return 1
        fi
    else
        log_error "HuggingFace GGUF模型下载失败: $full_model_name"
        return 1
    fi
}

# 删除Ollama模型
remove_ollama_model() {
    local model_spec="$1"
    local force_delete="${2:-false}"
    
    # 解析模型名称和版本
    if ! validate_model_format "$model_spec"; then
        return 1
    fi
    
    log_info "准备删除Ollama模型: $model_spec"
    
    # 检查模型是否存在
    local model_name model_version
    if ! parse_model_spec "$model_spec" model_name model_version; then
        return 1
    fi
    if ! check_ollama_model "$model_name" "$model_version"; then
        log_warning "模型不存在，无需删除: $model_spec"
        return 0
    fi
    
    # 如果不是强制删除，询问用户确认
    if [[ "$force_delete" != "true" ]]; then
        log_warning "即将删除模型: $model_spec"
        echo -n "确认删除？[y/N]: "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "取消删除操作"
            return 0
        fi
    fi
    
    if execute_ollama_command "rm" "$model_spec"; then
        log_success "Ollama模型删除完成: $model_spec"
        return 0
    else
        log_error "Ollama模型删除失败: $model_spec"
        return 1
    fi
}

# 获取模型相关的blob文件路径
get_model_blob_paths() {
    local manifest_file="$1"
    local models_dir="$2"
    local blob_paths=()
    
    if [[ ! -f "$manifest_file" ]]; then
        log_error "模型manifest文件不存在: $manifest_file"
        return 1
    fi
    
    # 使用hf_downloader镜像中的jq解析JSON文件
    local layers
    layers=$(docker run --rm --entrypoint="" -v "$(dirname "$manifest_file"):/data" hf_downloader jq -r '.layers[].digest, .config.digest' "/data/$(basename "$manifest_file")" 2>/dev/null | sort -u)
    
    # 构建blob文件路径
    while IFS= read -r digest; do
        if [[ -n "$digest" ]]; then
            # 将 sha256:xxx 格式转换为 sha256-xxx
            local blob_name="${digest//:/-}"
            local blob_file="$models_dir/blobs/$blob_name"
            blob_paths+=("$blob_file")
        fi
    done <<< "$layers"
    
    # 输出路径
    printf '%s\n' "${blob_paths[@]}"
}

# ===== 备份工具函数 =====

# 通用命令检查函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 模型名称安全化处理
# 统一的模型名称转换函数
# 参数1: 模型名称
# 参数2: 转换类型 (backup|ollama|filesystem)
get_safe_model_name() {
    local model_spec="$1"
    local conversion_type="${2:-backup}"
    
    case "$conversion_type" in
        "backup")
            # 用于备份目录命名：/ 和 : → _
            echo "$model_spec" | sed 's/[\/:]/_/g'
            ;;
        "ollama")
            # 用于Ollama模型命名：复杂转换规则（一次性处理）
            local full_name_clean
            full_name_clean=$(echo "$model_spec" | tr '[:upper:]' '[:lower:]' | sed -e 's/\//_/g' -e 's/[^a-z0-9_-]/_/g' -e 's/__*/_/g' -e 's/--*/-/g' -e 's/^[-_]\+\|[-_]\+$//g')
            # 长度限制
            if [[ ${#full_name_clean} -gt 50 ]]; then
                local prefix="${full_name_clean:0:30}"
                local suffix="${full_name_clean: -15}"
                full_name_clean="${prefix}_${suffix}"
            fi
            echo "$full_name_clean"
            ;;
        "filesystem")
            # 用于文件系统安全命名：/ → _，其他非法字符 → -
            echo "$model_spec" | sed -e 's/\//_/g' -e 's/[^a-zA-Z0-9._-]/-/g'
            ;;
        *)
            # 默认使用backup规则
            echo "$model_spec" | sed 's/[\/:]/_/g'
            ;;
    esac
}

# 文件大小工具函数
get_file_size() {
    local file_path="$1"
    local format="${2:-mb}"  # mb, human
    
    case "$format" in
        "mb")
            du -sm "$file_path" 2>/dev/null | cut -f1
            ;;
        "human")
            du -sh "$file_path" 2>/dev/null | cut -f1 
            ;;
        *)
            log_error "Unknown format: $format. Use 'mb' or 'human'"
            return 1
            ;;
    esac
}

# 向后兼容的包装函数
get_file_size_mb() {
    get_file_size "$1" "mb"
}

get_file_size_human() {
    get_file_size "$1" "human"
}

# 计算目录的MD5校验值
calculate_directory_md5() {
    local dir_path="$1"
    local md5_file="$2"
    
    if [[ ! -d "$dir_path" ]]; then
        log_error "目录不存在: $dir_path"
        return 1
    fi
    
    log_info "正在计算目录MD5校验值: $dir_path"
    
    # 使用find和md5sum计算所有文件的MD5值，使用相对路径
    # 按文件路径排序以确保结果一致性
    if (cd "$dir_path" && find . -type f -print0 | sort -z | xargs -0 md5sum) > "$md5_file" 2>/dev/null; then
        log_info "MD5校验文件已生成: $md5_file"
        return 0
    else
        log_error "MD5校验计算失败"
        return 1
    fi
}

# 验证目录的MD5校验值
verify_directory_md5() {
    local dir_path="$1"
    local md5_file="$2"
    
    if [[ ! -d "$dir_path" ]]; then
        log_error "目录不存在: $dir_path"
        return 1
    fi
    
    if [[ ! -f "$md5_file" ]]; then
        log_error "MD5校验文件不存在: $md5_file"
        return 1
    fi
    
    log_info "正在验证目录MD5校验值: $dir_path"
    
    # 临时计算当前目录的MD5值
    local temp_md5=$(mktemp)
    if ! calculate_directory_md5 "$dir_path" "$temp_md5"; then
        rm -f "$temp_md5"
        return 1
    fi
    
    # 比较MD5文件
    if diff "$md5_file" "$temp_md5" >/dev/null 2>&1; then
        log_info "MD5校验通过"
        rm -f "$temp_md5"
        return 0
    else
        log_error "MD5校验失败"
        rm -f "$temp_md5"
        return 1
    fi
}

# 全局缓存变量
declare -A BACKUP_CONTENT_CACHE
declare -A MODEL_BLOB_CACHE

# 检查备份完整性（检查备份中是否包含所有必需的blob文件）

# 获取模型blob列表（带缓存）
get_model_blobs_cached() {
    local model_spec="$1"
    
    # 检查缓存
    if [[ -n "${MODEL_BLOB_CACHE[$model_spec]:-}" ]]; then
        echo "${MODEL_BLOB_CACHE[$model_spec]}"
        return 0
    fi
    
    # 解析模型名称和版本
    local model_name model_version
    if ! parse_model_spec "$model_spec" model_name model_version; then
        return 1
    fi
    
    # 确定manifest文件路径
    local manifest_file
    if [[ "$model_name" == hf.co/* ]]; then
        manifest_file="$OLLAMA_MODELS_DIR/manifests/$model_name/$model_version"
    elif [[ "$model_name" == *"/"* ]]; then
        local user_name="${model_name%/*}"
        local repo_name="${model_name#*/}"
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/$user_name/$repo_name/$model_version"
    else
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/library/$model_name/$model_version"
    fi
    
    # 获取blob文件列表
    if [[ -f "$manifest_file" ]]; then
        local blobs=$(get_model_blob_paths "$manifest_file" "$OLLAMA_MODELS_DIR" | sed "s|^$OLLAMA_MODELS_DIR/||")
        if [[ -n "$blobs" ]]; then
            # 缓存结果
            MODEL_BLOB_CACHE[$model_spec]="$blobs"
            echo "$blobs"
            return 0
        fi
    fi
    
    return 1
}

# 快速检查单文件备份完整性


# 清理完整性检查缓存
clear_integrity_cache() {
    [[ -n "${VERBOSE}" ]] && log_info "清理完整性检查缓存"
    unset BACKUP_CONTENT_CACHE
    unset MODEL_BLOB_CACHE
    declare -g -A BACKUP_CONTENT_CACHE
    declare -g -A MODEL_BLOB_CACHE
}

# 确保完整性检查缓存已初始化
ensure_cache_initialized() {
    # 如果缓存数组不存在，初始化它们
    if [[ ! -v BACKUP_CONTENT_CACHE ]] || [[ ! -v MODEL_BLOB_CACHE ]]; then
        declare -g -A BACKUP_CONTENT_CACHE
        declare -g -A MODEL_BLOB_CACHE
        [[ -n "${VERBOSE}" ]] && log_info "完整性检查缓存已初始化"
    fi
}

# ==================================================================================
#                           统一完整性验证架构
# ==================================================================================

# 通用完整性验证函数 - 统一所有验证逻辑的入口点
verify_integrity() {
    local verification_type="$1"  # model, backup, hf_model
    local target="$2"             # 目标文件/路径/模型规格
    local options="${3:-}"        # 附加选项 (use_cache:true, check_blobs:true, etc.)
    
    # 解析选项
    local use_cache="true"
    local check_blobs="true"
    local model_spec=""
    
    # 解析选项字符串
    if [[ -n "$options" ]]; then
        while IFS=',' read -ra ADDR; do
            for i in "${ADDR[@]}"; do
                case "$i" in
                    use_cache:*)
                        use_cache="${i#*:}"
                        ;;
                    check_blobs:*)
                        check_blobs="${i#*:}"
                        ;;
                    model_spec:*)
                        model_spec="${i#*:}"
                        ;;
                esac
            done
        done <<< "$options"
    fi
    
    # 确保缓存已初始化
    [[ "$use_cache" == "true" ]] && ensure_cache_initialized
    
    # 根据验证类型调用相应的验证逻辑
    case "$verification_type" in
        "model")
            _verify_local_model "$target" "$use_cache" "$check_blobs"
            ;;
        "backup")
            _verify_backup_target "$target" "$model_spec" "$use_cache" "$check_blobs"
            ;;
        "hf_model")
            _verify_hf_model "$target" "$check_blobs"
            ;;
        "backup_file")
            _verify_backup_file "$target" "$use_cache"
            ;;
        *)
            log_error "Unknown verification type: $verification_type"
            return 1
            ;;
    esac
}

# 内部函数：验证本地模型完整性
_verify_local_model() {
    local model_spec="$1"
    local use_cache="$2"
    local check_blobs="$3"
    
    # 解析模型规格
    local model_name model_tag
    if [[ "$model_spec" =~ ^(.+):(.+)$ ]]; then
        model_name="${BASH_REMATCH[1]}"
        model_tag="${BASH_REMATCH[2]}"
    else
        log_error "Invalid model spec format: $model_spec"
        return 1
    fi
    
    # 确定manifest文件路径
    local manifest_file
    if [[ "$model_name" == hf.co/* ]]; then
        manifest_file="$OLLAMA_MODELS_DIR/manifests/$model_name/$model_tag"
    elif [[ "$model_name" == *"/"* ]]; then
        local user_name="${model_name%/*}"
        local repo_name="${model_name#*/}"
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/$user_name/$repo_name/$model_tag"
    else
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/library/$model_name/$model_tag"
    fi
    
    # 检查manifest文件是否存在
    [[ ! -f "$manifest_file" ]] && return 1
    
    # 如果不需要检查blob，只验证manifest存在即可
    [[ "$check_blobs" == "false" ]] && return 0
    
    # 获取blob文件列表并验证
    local blob_files
    if [[ "$use_cache" == "true" ]]; then
        blob_files=$(get_model_blobs_cached "$model_spec")
        [[ -z "$blob_files" ]] && return 1
        
        # 检查每个blob文件
        while IFS= read -r blob_relative_path; do
            [[ -n "$blob_relative_path" && ! -f "$OLLAMA_MODELS_DIR/$blob_relative_path" ]] && return 1
        done <<< "$blob_files"
    else
        blob_files=$(get_model_blob_paths "$manifest_file" "$OLLAMA_MODELS_DIR")
        [[ -z "$blob_files" ]] && return 1
        
        # 检查每个blob文件
        while IFS= read -r blob_file; do
            [[ -n "$blob_file" && ! -f "$blob_file" ]] && return 1
        done <<< "$blob_files"
    fi
    
    return 0
}

# 内部函数：验证备份目标（目录备份）
_verify_backup_target() {
    local backup_target="$1"
    local model_spec="$2"
    local use_cache="$3"
    local check_blobs="$4"
    
    # 检查目录备份
    if [[ -d "$backup_target" ]]; then
        # 验证目录结构
        if [[ -d "$backup_target/manifests" ]] && [[ -d "$backup_target/blobs" ]]; then
            # 验证MD5校验
            local md5_file="${backup_target}.md5"
            if [[ -f "$md5_file" ]]; then
                if verify_directory_md5 "$backup_target" "$md5_file"; then
                    [[ -n "${VERBOSE}" ]] && log_info "目录备份MD5校验通过: $backup_target"
                    return 0
                else
                    log_error "目录备份MD5校验失败: $backup_target"
                    return 1
                fi
            else
                log_warning "未找到MD5校验文件: $md5_file"
                return 0  # 没有MD5文件也认为有效，但会记录警告
            fi
        else
            log_error "无效的目录备份结构: $backup_target"
            return 1
        fi
    fi
    
    return 1
}


# 内部函数：验证HuggingFace模型
_verify_hf_model() {
    local source_dir="$1"
    local check_files="$2"
    
    # 检查源目录是否存在
    [[ ! -d "$source_dir" ]] && return 1
    
    # 如果不需要检查文件，只验证目录存在
    [[ "$check_files" == "false" ]] && return 0
    
    # 检查必要的文件
    local has_model_files=false
    for ext in safetensors bin gguf; do
        if ls "$source_dir"/*."$ext" >/dev/null 2>&1; then
            has_model_files=true
            break
        fi
    done
    
    [[ "$has_model_files" == "false" ]] && return 1
    return 0
}

# 内部函数：验证备份文件（业务逻辑完整性）
_verify_backup_file() {
    local backup_file="$1"
    local use_detailed_check="$2"
    
    [[ ! -f "$backup_file" ]] && return 1
    
    # 基本tar文件完整性检查
    if ! docker run --rm --entrypoint="" -v "$(dirname "$backup_file"):/data" hf_downloader:latest sh -c "
        cd /data && tar -tf '$(basename "$backup_file")' >/dev/null 2>&1
    "; then
        return 1
    fi
    
    # 如果需要详细检查，执行业务逻辑验证
    [[ "$use_detailed_check" == "true" ]] && validate_model_business_integrity "$backup_file"
}

# 删除不完整的备份文件
remove_incomplete_backup() {
    local backup_base="$1"
    local backup_suffix="${2:-}"
    
    log_info "删除不完整的备份: ${backup_base}${backup_suffix}"
    
    # 删除目录备份
    local backup_dir="${backup_base}${backup_suffix}"
    if [[ -d "$backup_dir" ]]; then
        rm -rf "$backup_dir"
        log_info "已删除备份目录: $backup_dir"
    fi
    
    # 删除MD5校验文件
    local md5_file="${backup_dir}.md5"
    if [[ -f "$md5_file" ]]; then
        rm -f "$md5_file"
        log_info "已删除MD5校验文件: $md5_file"
    fi
    
    # 删除备份信息文件
    local info_file="${backup_base}${backup_suffix}_info.txt"
    if [[ -f "$info_file" ]]; then
        rm -f "$info_file"
        log_info "已删除备份信息文件: $info_file"
    fi
}


# 安全的临时文件创建
create_temp_file() {
    local prefix="${1:-temp}"
    local temp_file
    temp_file=$(mktemp) || {
        log_error "无法创建临时文件"
        return 1
    }
    echo "$temp_file"
}


# 创建模型备份目录
create_model_backup_dir() {
    local model_spec="$1"
    local base_backup_dir="$2"
    local model_safe_name=$(get_safe_model_name "$model_spec")
    local model_backup_dir="${base_backup_dir}/${model_safe_name}"
    
    # 创建备份目录
    if ! mkdir -p "$model_backup_dir"; then
        log_error "无法创建备份目录: $model_backup_dir"
        return 1
    fi
    echo "$model_backup_dir"
}

# 生成备份基础路径
get_backup_base_path() {
    local model_spec="$1"
    local backup_dir="$2"
    local suffix="${3:-}"
    local model_safe_name=$(get_safe_model_name "$model_spec")
    echo "${backup_dir}/${model_safe_name}${suffix}"
}

# 创建tar文件的通用函数（用于HuggingFace模型）
create_hf_tar_file() {
    local output_file="$1"
    local source_dir="$2"
    
    # 创建排除文件列表
    local temp_exclude="/tmp/tar_exclude_$$.txt"
    cat > "$temp_exclude" << 'EOF'
*.aria2
*.tmp
*.part
EOF
    
    # 使用Docker创建tar文件
    local output_dir="$(dirname "$output_file")"
    local output_basename="$(basename "$output_file")"
    local source_parent="$(dirname "$source_dir")"
    local source_name="$(basename "$source_dir")"
    
    # 确保hf_downloader镜像存在
    ensure_hf_downloader_image || { rm -f "$temp_exclude"; return 1; }
    
    if docker run --rm --entrypoint="" \
        -v "$source_parent:/source:ro" \
        -v "$output_dir:/output" \
        -v "$temp_exclude:/exclude.txt:ro" \
        "$FULL_IMAGE_NAME" \
        tar -cf "/output/$output_basename" -C /source --exclude-from=/exclude.txt "$source_name" 2>/dev/null; then
        rm -f "$temp_exclude"
        return 0
    else
        log_error "创建tar文件失败: $output_file"
        rm -f "$temp_exclude"
        return 1
    fi
}

# 备份信息和管理函数

# 创建备份信息文件
create_backup_info() {
    local model_spec="$1"
    local backup_base="$2"
    local backup_type="$3"  # "directory", "single" 或 "split"
    local volume_count="$4"
    local backup_extension="${5:-original}"
    
    local info_file="${backup_base}_info.txt"
    local current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local model_safe_name=$(get_safe_model_name "$model_spec")
    
    # 使用临时文件创建备份信息
    local temp_info=$(mktemp)
    cat > "$temp_info" << EOF
================================================================================
                           模型备份信息
================================================================================

备份基本信息:
  模型规格: $model_spec
  备份名称: ${model_safe_name}
  备份类型: $backup_type
  创建时间: $current_time

备份文件信息:
EOF

    # 根据备份类型添加具体的文件信息和MD5
    if [[ "$backup_type" == "directory" ]]; then
        local backup_dir="${backup_base}_${backup_extension}"
        # 对于ollama备份，backup_base已经是完整路径，不需要添加后缀
        if [[ "$backup_extension" == "ollama" ]]; then
            backup_dir="$backup_base"
        fi
        local backup_size=$(get_file_size_human "$backup_dir" || echo "未知")
        local md5_file="${backup_dir}.md5"
        local md5_status="有效"
        
        if [[ ! -f "$md5_file" ]]; then
            md5_status="缺失"
        fi
        
        cat >> "$temp_info" << EOF
  备份方式: 目录复制
  备份目录: $(basename "$backup_dir")
  备份大小: $backup_size
  MD5校验文件: $md5_status

文件列表:
EOF
        
        # 添加文件列表
        if [[ -d "$backup_dir" ]]; then
            find "$backup_dir" -type f -exec basename {} \; | sort >> "$temp_info"
        fi
        
        cat >> "$temp_info" << EOF

MD5校验信息:
EOF
        
        # 添加MD5校验信息
        if [[ -f "$md5_file" ]]; then
            cat "$md5_file" >> "$temp_info"
        else
            echo "  MD5校验文件创建失败或不存在" >> "$temp_info"
            echo "  文件路径: $md5_file" >> "$temp_info"
            echo "  建议: 重新运行备份以生成MD5校验文件" >> "$temp_info"
        fi
        
        cat >> "$temp_info" << EOF

恢复命令:
  # 使用omo.sh恢复
  ./omo.sh --restore "$(basename "$backup_dir")"
  
  # 手动恢复（Ollama模型）
  cp -r "$(basename "$backup_dir")/manifests/"* "\$OLLAMA_MODELS_DIR/manifests/"
  cp "$(basename "$backup_dir")/blobs/"* "\$OLLAMA_MODELS_DIR/blobs/"
  
  # 手动恢复（HuggingFace模型）
  cp -r "$(basename "$backup_dir")" "\$HF_DOWNLOAD_CACHE_DIR/"

EOF
    else
        log_error "不支持的备份类型: $backup_type"
        rm -f "$temp_info"
        return 1
    fi
    
    cat >> "$temp_info" << EOF
================================================================================
                               验证信息
================================================================================

备份验证:
1. 检查文件完整性:
   - 使用MD5校验文件验证每个文件的完整性
   - md5sum -c $(basename "${backup_dir}.md5")

2. 检查备份结构:
   - 确保备份目录包含完整的文件结构
   - 对于Ollama模型: manifests/ 和 blobs/ 目录
   - 对于HuggingFace模型: 模型文件和配置文件

备份特性:
   - 直接复制: 极快的备份和恢复速度，无需压缩/解压缩
   - MD5校验: 确保文件完整性和一致性
   - 简化管理: 备份文件可直接访问和检查

使用说明:
- 此备份包含模型的完整文件结构
- 恢复后可直接使用，无需额外处理
- 支持增量备份和差异检查

生成时间: $current_time
================================================================================
EOF

    # 直接写入信息文件
    if mv "$temp_info" "$info_file"; then
        log_success "备份信息文件创建完成: $(basename "$info_file")"
    else
        log_error "无法写入备份信息文件: $info_file"
        rm -f "$temp_info"
        return 1
    fi
}

# 创建HuggingFace原始模型备份（直接复制）
backup_hf_original_model() {
    local model_name="$1"
    local source_dir="$2"
    
    log_info "备份HuggingFace模型: $model_name"
    log_info "源目录: $source_dir"
    
    # 检查源目录是否存在
    if [[ ! -d "$source_dir" ]]; then
        log_error "源目录不存在: $source_dir"
        return 1
    fi
    
    # 检查本地模型完整性
    log_info "检查本地模型完整性..."
    if ! verify_integrity "hf_model" "$source_dir" "check_files:true"; then
        log_error "本地模型不完整，取消备份操作"
        return 1
    fi
    
    # 创建备份目录和生成路径
    local model_backup_dir
    model_backup_dir=$(create_model_backup_dir "$model_name" "$ABS_HF_ORIGINAL_BACKUP_DIR") || return 1
    local model_safe_name=$(get_safe_model_name "$model_name")
    local backup_dir="$model_backup_dir/${model_safe_name}_original"
    
    # 检查是否已存在备份目录
    if [[ -d "$backup_dir" ]]; then
        log_info "原始模型备份已存在: $backup_dir"
        return 0
    fi
    
    log_info "模型备份目录: $backup_dir"
    
    # 计算源目录大小
    local source_size_human=$(get_file_size_human "$source_dir")
    log_info "源目录大小: $source_size_human"
    
    # 复制源目录到备份目录，排除 .hfd 临时目录
    log_info "开始复制文件..."
    mkdir -p "$backup_dir"
    if rsync -av --exclude='.hfd' "$source_dir/" "$backup_dir/" 2>/dev/null || {
        # 如果没有 rsync，使用 cp 加手动排除
        log_info "rsync 不可用，使用 cp 复制（排除 .hfd 目录）"
        # 使用 find 复制，排除 .hfd 目录
        (cd "$source_dir" && find . -type d -name '.hfd' -prune -o -type f -print0 | cpio -0pdm "$backup_dir/") 2>/dev/null
    }; then
        # 计算MD5校验
        log_info "计算MD5校验值..."
        local md5_file="${backup_dir}.md5"
        if calculate_directory_md5 "$backup_dir" "$md5_file"; then
            log_info "MD5校验文件已创建: $md5_file"
        else
            log_warning "MD5校验文件创建失败"
        fi
        
        # 创建备份信息文件
        create_backup_info "$model_name" "${model_backup_dir}/${model_safe_name}" "directory" 1 "original"
        
        log_success "HuggingFace原始模型备份完成: $model_name"
        return 0
    else
        log_error "复制文件失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 列出已安装的Ollama模型及详细信息
list_installed_models() {
    log_info "扫描Ollama模型..."
    
    # 初始化缓存以提高完整性检查性能
    ensure_cache_initialized
    
    # 检查Ollama模型目录是否存在
    if [[ ! -d "$OLLAMA_MODELS_DIR" ]]; then
        log_error "Ollama模型目录不存在: $OLLAMA_MODELS_DIR"
        return 1
    fi
    
    local blobs_dir="$OLLAMA_MODELS_DIR/blobs"
    local manifests_base_dir="$OLLAMA_MODELS_DIR/manifests"
    
    # 检查manifests基础目录是否存在
    if [[ ! -d "$manifests_base_dir" ]]; then
        log_warning "未找到模型manifest目录，可能没有安装任何模型"
        return 0
    fi
    
    echo ""
    echo "=================================================================================="
    echo "                             已安装的Ollama模型"
    echo "=================================================================================="
    echo ""
    
    local model_count=0
    local total_size=0
    local total_version_count=0
    
    # 递归查找所有 manifest 文件
    local manifest_files=()
    while IFS= read -r -d '' manifest_file; do
        manifest_files+=("$manifest_file")
    done < <(find "$manifests_base_dir" -type f -print0 2>/dev/null)
    
    # 按模型组织 manifest 文件
    declare -A model_manifests
    
    for manifest_file in "${manifest_files[@]}"; do
        # 提取相对于 manifests_base_dir 的路径
        local relative_path="${manifest_file#$manifests_base_dir/}"
        
        # 根据路径结构提取模型名和版本
        local model_name=""
        local version=""
        local full_model_path=""
        
        if [[ "$relative_path" =~ ^registry\.ollama\.ai/library/([^/]+)/(.+)$ ]]; then
            # 传统 Ollama 模型: registry.ollama.ai/library/model_name/version
            model_name="${BASH_REMATCH[1]}"
            version="${BASH_REMATCH[2]}"
            full_model_path="registry.ollama.ai/library/$model_name"
        elif [[ "$relative_path" =~ ^hf\.co/([^/]+)/([^/]+)/(.+)$ ]]; then
            # HF-GGUF 模型: hf.co/user/repo/version
            local user="${BASH_REMATCH[1]}"
            local repo="${BASH_REMATCH[2]}"
            version="${BASH_REMATCH[3]}"
            model_name="hf.co/$user/$repo"
            full_model_path="hf.co/$user/$repo"
        else
            # 其他未知格式，尝试通用解析
            local path_parts
            IFS='/' read -ra path_parts <<< "$relative_path"
            if [[ ${#path_parts[@]} -ge 2 ]]; then
                version="${path_parts[-1]}"
                unset path_parts[-1]
                model_name=$(IFS='/'; echo "${path_parts[*]}")
                full_model_path="$model_name"
            else
                continue
            fi
        fi
        
        # 将 manifest 添加到对应模型组
        if [[ -n "$model_name" && -n "$version" ]]; then
            local key="$model_name"
            if [[ -z "${model_manifests[$key]:-}" ]]; then
                model_manifests[$key]="$manifest_file|$version|$full_model_path"
            else
                model_manifests[$key]="${model_manifests[$key]};;$manifest_file|$version|$full_model_path"
            fi
        fi
    done
    
    # 显示每个模型的信息
    for model_name in "${!model_manifests[@]}"; do
        local model_data="${model_manifests[$model_name]}"
        
        # 解析第一个条目以获取路径信息
        local first_entry="${model_data%%;*}"
        local full_model_path="${first_entry##*|}"
        local model_dir="$manifests_base_dir/$full_model_path"
        
        echo "📦 模型: $model_name"
        echo "   ├─ 位置: $model_dir"
        
        local version_count=0
        
        # 处理所有版本
        IFS=';;' read -ra entries <<< "$model_data"
        for entry in "${entries[@]}"; do
            IFS='|' read -r manifest_file version _ <<< "$entry"
            
            if [[ ! -f "$manifest_file" ]]; then
                continue
            fi
            
            # 对于 hf-gguf 模型，需要提取实际的模型名称进行完整性检查
            local check_model_name="$model_name"
            if [[ "$model_name" =~ ^hf\.co/(.+)$ ]]; then
                check_model_name="${BASH_REMATCH[1]}"
                # 将 / 替换为 _ 来匹配实际的检查逻辑
                check_model_name="${check_model_name//\//_}"
            fi
            
            # 检查模型完整性（使用缓存优化）
            local integrity_status=""
            local check_model_spec="${check_model_name}:${version}"
            if verify_integrity "model" "$check_model_spec" "use_cache:true,check_blobs:true"; then
                integrity_status=" ✓"
            else
                integrity_status=" ⚠️(不完整)"
            fi
            
            echo "   ├─ 版本: $version$integrity_status"
            
            # 读取manifest文件获取blob信息
            if [[ -f "$manifest_file" ]]; then
                local manifest_content
                if manifest_content=$(cat "$manifest_file" 2>/dev/null); then
                    # manifest是JSON格式，解析获取所有层的大小
                    local total_model_size=0
                    local blob_count=0
                    local model_type="未知"
                    
                    # 尝试从JSON中提取模型类型
                    if echo "$manifest_content" | grep -q "application/vnd.ollama.image.model"; then
                        model_type="Ollama模型"
                    fi
                    
                    # 提取config大小
                    local config_size
                    if config_size=$(echo "$manifest_content" | grep -o '"config":{[^}]*"size":[0-9]*' | grep -o '[0-9]*$' 2>/dev/null); then
                        total_model_size=$((total_model_size + config_size))
                        blob_count=$((blob_count + 1))
                    fi
                    
                    # 提取所有layers的大小
                    local layer_sizes
                    if layer_sizes=$(echo "$manifest_content" | grep -o '"size":[0-9]*' | grep -o '[0-9]*' 2>/dev/null); then
                        while IFS= read -r size; do
                            if [[ -n "$size" && "$size" -gt 0 ]]; then
                                total_model_size=$((total_model_size + size))
                                blob_count=$((blob_count + 1))
                            fi
                        done <<< "$layer_sizes"
                    fi
                    
                    # 格式化大小显示
                    local human_size=$(format_bytes "$total_model_size")
                    
                    echo "   ├─ 大小: $human_size"
                    
                    total_size=$((total_size + total_model_size))
                fi
            fi
            
            version_count=$((version_count + 1))
        done
        
        echo "   └─ 版本数量: $version_count"
        echo ""
        model_count=$((model_count + 1))
        total_version_count=$((total_version_count + version_count))
    done
    
    # 显示统计信息
    echo "=================================================================================="
    echo "统计信息:"
    echo "  📊 总模型数: $model_count"
    echo "  🔢 总版本数: $total_version_count"
    
    # 格式化总大小
    local total_human_size=$(format_bytes "$total_size")
    
    echo "  💾 总大小: $total_human_size"
    echo "  📁 目录: $OLLAMA_MODELS_DIR"
    
    # 显示磁盘使用情况
    local disk_usage
    if disk_usage=$(du -sh "$OLLAMA_MODELS_DIR" 2>/dev/null); then
        echo "  🗄️ 磁盘占用: $(echo "$disk_usage" | cut -f1)"
    fi
    
    echo "=================================================================================="
    echo ""
    
    return 0
}

# 备份Ollama模型（直接复制）
backup_ollama_model() {
    local model_spec="$1"
    local backup_dir="$2"
    
    # 初始化缓存以提高完整性检查性能
    ensure_cache_initialized
    
    # 解析模型名称和版本
    local model_name model_version
    if ! parse_model_spec "$model_spec" model_name model_version; then
        return 1
    fi
    
    log_info "备份模型: $model_name:$model_version"
    
    # 检查本地模型完整性
    log_info "检查本地模型完整性..."
    local model_spec="${model_name}:${model_version}"
    if ! verify_integrity "model" "$model_spec" "use_cache:true,check_blobs:true"; then
        log_error "本地模型不完整，取消备份操作"
        return 1
    fi
    
    # 创建备份目录和生成路径
    local model_backup_dir
    model_backup_dir=$(create_model_backup_dir "$model_spec" "$backup_dir") || return 1
    local model_safe_name=$(get_safe_model_name "$model_spec")
    local backup_model_dir="$model_backup_dir/$model_safe_name"
    
    log_info "模型备份目录: $backup_model_dir"
    
    # 检查是否已存在备份目录
    if [[ -d "$backup_model_dir" ]]; then
        log_info "模型备份已存在: $backup_model_dir"
        return 0
    fi
    
    # 确定manifest文件路径
    local manifest_file
    if [[ "$model_name" == hf.co/* ]]; then
        # HuggingFace GGUF模型，如 hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF
        manifest_file="$OLLAMA_MODELS_DIR/manifests/$model_name/$model_version"
    elif [[ "$model_name" == *"/"* ]]; then
        # 用户分享的模型，如 lrs33/bce-embedding-base_v1
        local user_name="${model_name%/*}"
        local repo_name="${model_name#*/}"
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/$user_name/$repo_name/$model_version"
    else
        # 官方模型
        manifest_file="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/library/$model_name/$model_version"
    fi
    
    # 检查manifest文件是否存在
    if [[ ! -f "$manifest_file" ]]; then
        log_error "模型不存在: $model_spec"
        log_error "Manifest文件未找到: $manifest_file"
        return 1
    fi
    
    # 获取blob文件路径
    log_info "解析模型文件..."
    local blob_files
    blob_files=$(get_model_blob_paths "$manifest_file" "$OLLAMA_MODELS_DIR")
    
    if [[ -z "$blob_files" ]]; then
        log_error "未找到模型相关的blob文件"
        return 1
    fi
    
    # 创建备份目录结构
    mkdir -p "$backup_model_dir/manifests"
    mkdir -p "$backup_model_dir/blobs"
    
    log_info "开始复制文件..."
    
    # 复制manifest文件
    local manifest_rel_path="${manifest_file#$OLLAMA_MODELS_DIR/manifests/}"
    local manifest_backup_dir="$backup_model_dir/manifests/$(dirname "$manifest_rel_path")"
    mkdir -p "$manifest_backup_dir"
    if ! cp "$manifest_file" "$manifest_backup_dir/"; then
        log_error "复制manifest文件失败: $manifest_file"
        rm -rf "$backup_model_dir"
        return 1
    fi
    
    # 复制blob文件
    while IFS= read -r blob_file; do
        if [[ -f "$blob_file" ]]; then
            local blob_name=$(basename "$blob_file")
            if ! cp "$blob_file" "$backup_model_dir/blobs/"; then
                log_error "复制blob文件失败: $blob_file"
                rm -rf "$backup_model_dir"
                return 1
            fi
        fi
    done <<< "$blob_files"
    
    # 计算MD5校验
    log_info "计算MD5校验值..."
    local md5_file="${backup_model_dir}.md5"
    if calculate_directory_md5 "$backup_model_dir" "$md5_file"; then
        log_info "MD5校验文件已创建: $md5_file"
    else
        log_warning "MD5校验文件创建失败"
    fi
    
    # 创建备份信息文件
    create_backup_info "$model_spec" "$backup_model_dir" "directory" 1 "ollama"
    
    log_success "模型备份完成: $model_spec"
    return 0
}



# 智能删除模型（自动识别模型类型）
remove_model_smart() {
    local model_input="$1"
    local force_delete="${2:-false}"
    
    log_info "智能删除模型: $model_input"
    
    # 检查输入格式，判断是什么类型的模型
    if [[ "$model_input" =~ ^([^:]+):(.+)$ ]]; then
        local model_name="${BASH_REMATCH[1]}"
        local model_tag_or_quant="${BASH_REMATCH[2]}"
        
        # 先检查是否是Ollama模型（直接格式：model:tag）
        if check_ollama_model "$model_name" "$model_tag_or_quant"; then
            log_info "检测到Ollama模型: ${model_name}:${model_tag_or_quant}"
            if remove_ollama_model "$model_input" "$force_delete"; then
                return 0
            else
                return 1
            fi
        fi
        
        # 检查是否是GGUF模型（生成的Ollama模型名）
        local generated_name=$(generate_ollama_model_name "$model_name" "$model_tag_or_quant")
        if check_ollama_model_exists "$generated_name"; then
            log_info "检测到GGUF模型（存储为Ollama模型）: $generated_name"
        else
            log_info "尝试按GGUF模型格式删除: ${model_name} (量化: ${model_tag_or_quant})"
        fi
        
        # 统一删除处理
        if remove_ollama_model "$generated_name" "$force_delete"; then
            return 0
        else
            return 1
        fi
        
    else
        log_error "模型格式错误，应为 '模型名:版本' 或 '模型名:量化类型'"
        log_error "例如: 'llama2:7b' 或 'microsoft/DialoGPT-small:q4_0'"
        return 1
    fi
}

# 检测备份文件类型




# 恢复Ollama模型（目录备份）
restore_ollama_model() {
    local backup_dir="$1"
    local force_restore="$2"
    
    log_info "恢复Ollama模型: $(basename "$backup_dir")"
    
    # 检查备份目录是否存在
    if [[ ! -d "$backup_dir" ]]; then
        log_error "备份不存在或格式不正确: $backup_dir"
        log_error "只支持目录备份格式"
        return 1
    fi
    
    # 检查备份目录结构
    if [[ ! -d "$backup_dir/manifests" ]] || [[ ! -d "$backup_dir/blobs" ]]; then
        log_error "无效的备份目录结构: $backup_dir"
        return 1
    fi
    
    # MD5校验
    local md5_file="${backup_dir}.md5"
    if [[ -f "$md5_file" ]]; then
        log_info "正在验证MD5校验值..."
        if verify_directory_md5 "$backup_dir" "$md5_file"; then
            log_success "MD5校验通过"
        else
            log_error "MD5校验失败，备份可能已损坏"
            if [[ "$force_restore" != "true" ]]; then
                return 1
            fi
            log_warning "强制恢复模式，继续操作..."
        fi
    else
        log_warning "未找到MD5校验文件，跳过校验"
    fi
    
    # 检查是否需要强制覆盖
    if [[ "$force_restore" != "true" ]]; then
        log_info "检查文件冲突..."
        local conflicts_found=false
        
        # 检查manifests冲突
        if find "$backup_dir/manifests" -type f 2>/dev/null | while read -r manifest_file; do
            local rel_path="${manifest_file#$backup_dir/manifests/}"
            local target_file="$OLLAMA_MODELS_DIR/manifests/$rel_path"
            if [[ -f "$target_file" ]]; then
                echo "conflict"
                break
            fi
        done | grep -q "conflict"; then
            conflicts_found=true
        fi
        
        # 检查blobs冲突
        if find "$backup_dir/blobs" -type f 2>/dev/null | while read -r blob_file; do
            local blob_name=$(basename "$blob_file")
            local target_file="$OLLAMA_MODELS_DIR/blobs/$blob_name"
            if [[ -f "$target_file" ]]; then
                echo "conflict"
                break
            fi
        done | grep -q "conflict"; then
            conflicts_found=true
        fi
        
        if [[ "$conflicts_found" == "true" ]]; then
            log_error "检测到文件冲突，使用 --force 强制覆盖"
            return 1
        fi
    fi
    
    # 使用Docker确保目标目录存在并有正确权限
    ensure_hf_downloader_image || return 1
    
    # 使用Docker创建Ollama目录并设置权限
    if ! docker run --rm --entrypoint="" --user root \
        -v "$OLLAMA_MODELS_DIR:/ollama" \
        "$FULL_IMAGE_NAME" \
        sh -c "mkdir -p /ollama/manifests /ollama/blobs"; then
        log_error "无法创建Ollama目录"
        return 1
    fi
    
    # 复制manifests
    log_info "恢复manifest文件..."
    if ! docker run --rm --entrypoint="" --user root \
        -v "$backup_dir:/backup" \
        -v "$OLLAMA_MODELS_DIR:/ollama" \
        "$FULL_IMAGE_NAME" \
        sh -c "cp -r /backup/manifests/* /ollama/manifests/"; then
        log_error "manifest文件复制失败"
        return 1
    fi
    
    # 复制blobs
    log_info "恢复blob文件..."
    if ! docker run --rm --entrypoint="" --user root \
        -v "$backup_dir:/backup" \
        -v "$OLLAMA_MODELS_DIR:/ollama" \
        "$FULL_IMAGE_NAME" \
        sh -c "cp /backup/blobs/* /ollama/blobs/"; then
        log_error "blob文件复制失败"
        return 1
    fi
    
    log_success "Ollama模型恢复完成"
    return 0
}

# 自动识别备份类型并恢复
# 批量备份模型（根据models.list文件）
backup_models_from_list() {
    local models_file="$1"
    local backup_dir="$2"
    
    log_info "批量备份模型..."
    log_info "模型列表文件: $models_file"
    log_info "备份目录: $backup_dir"
    
    # 解析模型列表
    local models=()
    parse_models_list "$models_file" models
    
    if [[ ${#models[@]} -eq 0 ]]; then
        log_warning "没有找到任何模型进行备份"
        return 1
    fi
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    local total_models=${#models[@]}
    local processed=0
    local success=0
    local failed=0
    
    log_info "共找到 $total_models 个模型进行备份"
    
    # 预先初始化Ollama缓存，避免每个模型都重新初始化
    local has_ollama_models=false
    for model in "${models[@]}"; do
        if [[ "$model" =~ ^ollama: ]] || [[ "$model" =~ ^hf-gguf: ]]; then
            has_ollama_models=true
            break
        fi
    done
    
    if [[ "$has_ollama_models" == "true" ]]; then
        log_info "检测到Ollama模型，预先初始化模型缓存..."
        if ! init_ollama_cache; then
            log_error "Ollama缓存初始化失败，可能影响备份性能"
        fi
    fi
    
    for model in "${models[@]}"; do
        ((processed++))
        log_info "备份模型 [$processed/$total_models]: $model"
        
        # 解析模型条目
        if [[ "$model" =~ ^ollama:([^:]+):(.+)$ ]]; then
            local model_name="${BASH_REMATCH[1]}"
            local model_tag="${BASH_REMATCH[2]}"
            local model_spec="${model_name}:${model_tag}"
            
            log_info "备份Ollama模型: $model_spec"
            
            # 检查模型是否存在
            if check_ollama_model "$model_name" "$model_tag"; then
                if backup_ollama_model "$model_spec" "$backup_dir"; then
                    ((success++))
                    log_success "Ollama模型备份成功: $model_spec"
                else
                    ((failed++))
                    log_error "Ollama模型备份失败: $model_spec"
                fi
            else
                log_warning "Ollama模型不存在，跳过备份: $model_spec"
                ((failed++))
            fi
            
        elif [[ "$model" =~ ^hf-gguf:(.+)$ ]]; then
            local model_full_name="${BASH_REMATCH[1]}"
            
            # 解析HuggingFace GGUF模型名称
            if [[ "$model_full_name" =~ ^(.+):(.+)$ ]]; then
                local model_name="${BASH_REMATCH[1]}"
                local model_tag="${BASH_REMATCH[2]}"
            else
                local model_name="$model_full_name"
                local model_tag="latest"
            fi
            
            local model_spec="${model_name}:${model_tag}"
            log_info "备份HuggingFace GGUF模型: $model_spec"
            
            # 检查HF GGUF模型是否存在
            if check_hf_gguf_model "$model_name" "$model_tag"; then
                if backup_ollama_model "$model_spec" "$backup_dir"; then
                    ((success++))
                    log_success "HuggingFace GGUF模型备份成功: $model_spec"
                else
                    ((failed++))
                    log_error "HuggingFace GGUF模型备份失败: $model_spec"
                fi
            else
                log_warning "HuggingFace GGUF模型不存在，跳过备份: $model_spec"
                ((failed++))
            fi
            
        elif [[ "$model" =~ ^huggingface:([^:]+):(.+)$ ]]; then
            local model_name="${BASH_REMATCH[1]}"
            local quantize_type="${BASH_REMATCH[2]}"
            
            log_info "备份HuggingFace模型: $model_name (量化: $quantize_type)"
            
            # 检查HuggingFace模型是否存在于Ollama中
            if check_huggingface_model_in_ollama "$model_name" "$quantize_type"; then
                local ollama_model_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
                if backup_ollama_model "$ollama_model_name" "$backup_dir"; then
                    ((success++))
                    log_success "HuggingFace模型备份成功: $model_name"
                else
                    ((failed++))
                    log_error "HuggingFace模型备份失败: $model_name"
                fi
            else
                log_warning "HuggingFace模型不存在，跳过备份: $model_name"
                ((failed++))
            fi
            
        else
            log_error "无效的模型条目格式: $model"
            ((failed++))
        fi
        
        echo "" # 添加空行分隔
    done
    
    # 显示备份总结
    log_success "批量备份完成 ($success/$total_models)"
    if [[ $failed -gt 0 ]]; then
        log_warning "备份失败: $failed"
    fi
    
    # 显示备份目录信息
    if [[ -d "$backup_dir" ]]; then
        # 只统计顶级模型目录，排除子目录
        local backup_count=$(find "$backup_dir" -maxdepth 1 -type d ! -path "$backup_dir" | wc -l)
        local total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        log_info "备份目录: $backup_count 个模型，总大小: $total_size"
    fi
    
    # 清理完整性检查缓存
    clear_integrity_cache
    
    if [[ $failed -eq 0 ]]; then
        log_success "全部模型备份完成"
        return 0
    else
        log_warning "部分模型备份失败"
        return 1
    fi
}

# 批量删除模型（根据models.list文件）
remove_models_from_list() {
    local models_file="$1"
    local force_delete="${2:-false}"
    
    log_info "批量删除模型..."
    log_info "模型列表文件: $models_file"
    log_info "强制删除模式: $force_delete"
    
    # 解析模型列表
    local models=()
    parse_models_list "$models_file" models
    
    if [[ ${#models[@]} -eq 0 ]]; then
        log_warning "没有找到任何模型进行删除"
        return 1
    fi
    
    local total_models=${#models[@]}
    local processed=0
    local success=0
    local failed=0
    
    log_info "共找到 $total_models 个模型进行删除"
    
    # 如果不是强制删除，显示要删除的模型列表并请求确认
    if [[ "$force_delete" != "true" ]]; then
        log_warning "即将删除以下模型："
        for model in "${models[@]}"; do
            if [[ "$model" =~ ^ollama:([^:]+):(.+)$ ]]; then
                local model_name="${BASH_REMATCH[1]}"
                local model_tag="${BASH_REMATCH[2]}"
                echo "  - Ollama模型: ${model_name}:${model_tag}"
            elif [[ "$model" =~ ^huggingface:([^:]+):(.+)$ ]]; then
                local model_name="${BASH_REMATCH[1]}"
                local quantize_type="${BASH_REMATCH[2]}"
                echo "  - GGUF模型: $model_name ($quantize_type)"
            elif [[ "$model" =~ ^hf-gguf:(.+)$ ]]; then
                local model_full_name="${BASH_REMATCH[1]}"
                echo "  - HuggingFace GGUF模型: $model_full_name"
            fi
        done
        echo ""
        echo -n "确认删除所有这些模型？[y/N]: "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "取消批量删除操作"
            return 0
        fi
        echo ""
    fi
    
    for model in "${models[@]}"; do
        ((processed++))
        log_info "删除模型 [$processed/$total_models]: $model"
        
        # 解析模型条目
        if [[ "$model" =~ ^ollama:([^:]+):(.+)$ ]]; then
            local model_name="${BASH_REMATCH[1]}"
            local model_tag="${BASH_REMATCH[2]}"
            local model_spec="${model_name}:${model_tag}"
            
            log_info "删除Ollama模型: $model_spec"
            
            if remove_ollama_model "$model_spec" "true"; then
                ((success++))
                log_success "Ollama模型删除成功: $model_spec"
            else
                ((failed++))
                log_error "Ollama模型删除失败: $model_spec"
            fi
            
        elif [[ "$model" =~ ^huggingface:([^:]+):(.+)$ ]]; then
            local model_name="${BASH_REMATCH[1]}"
            local quantize_type="${BASH_REMATCH[2]}"
            
            log_info "删除HuggingFace GGUF模型: $model_name ($quantize_type)"
            
            # 生成对应的Ollama模型名称
            local ollama_model_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
            if remove_ollama_model "$ollama_model_name" "true"; then
                ((success++))
                log_success "GGUF模型删除成功: $model_name ($quantize_type)"
            else
                ((failed++))
                log_error "GGUF模型删除失败: $model_name ($quantize_type)"
            fi
            
        elif [[ "$model" =~ ^hf-gguf:(.+)$ ]]; then
            local model_full_name="${BASH_REMATCH[1]}"
            
            # 解析HuggingFace GGUF模型名称
            if [[ "$model_full_name" =~ ^(.+):(.+)$ ]]; then
                local model_name="${BASH_REMATCH[1]}"
                local model_tag="${BASH_REMATCH[2]}"
            else
                local model_name="$model_full_name"
                local model_tag="latest"
            fi
            
            local model_spec="${model_name}:${model_tag}"
            log_info "删除HuggingFace GGUF模型: $model_spec"
            
            if remove_ollama_model "$model_spec" "true"; then
                ((success++))
                log_success "HuggingFace GGUF模型删除成功: $model_spec"
            else
                ((failed++))
                log_error "HuggingFace GGUF模型删除失败: $model_spec"
            fi
            
        else
            log_error "无效的模型条目格式: $model"
            ((failed++))
        fi
        
        echo "" # 添加空行分隔
    done
    
    # 显示删除总结
    log_success "批量删除完成 ($success/$total_models)"
    if [[ $failed -gt 0 ]]; then
        log_warning "删除失败: $failed"
    fi
    
    if [[ $failed -eq 0 ]]; then
        log_success "全部模型删除完成"
        return 0
    else
        log_warning "部分模型删除失败"
        return 1
    fi
}

# 检查Ollama中是否存在指定模型
# 检查HuggingFace模型是否已存在于Ollama中（智能匹配）
check_huggingface_model_in_ollama() {
    local model_name="$1"
    local quantize_type="$2"
    
    log_info "检查HuggingFace模型: $model_name ($quantize_type)"
    
    # 生成期望的Ollama模型名称（带hf-前缀）
    local expected_ollama_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
    
    # 使用简化的容器检查
    if check_ollama_model_exists "$expected_ollama_name"; then
        log_success "找到匹配的Ollama模型: $expected_ollama_name"
        return 0
    fi
    
    log_info "未找到匹配的Ollama模型: $expected_ollama_name"
    return 1
}

# 从HuggingFace原始备份恢复并重新转换
restore_and_reconvert_hf_model() {
    local model_name="$1"
    local quantize_type="$2"
    
    log_info "从原始备份恢复并重新转换: $model_name ($quantize_type)"
    
    # 生成文件系统安全的模型名称
    local model_safe_name=$(get_safe_model_name "$model_name" "filesystem")
    local model_backup_dir="${ABS_HF_ORIGINAL_BACKUP_DIR}/${model_safe_name}"
    local backup_dir="${model_backup_dir}/${model_safe_name}_original"
    
    # 检查备份目录
    if [[ ! -d "$backup_dir" ]]; then
        log_error "未找到备份目录: $backup_dir"
        return 1
    fi
    
    # MD5校验
    local md5_file="${backup_dir}.md5"
    if [[ -f "$md5_file" ]]; then
        log_info "正在验证MD5校验值..."
        if verify_directory_md5 "$backup_dir" "$md5_file"; then
            log_success "MD5校验通过"
        else
            log_error "MD5校验失败，备份可能已损坏"
            return 1
        fi
    else
        log_warning "未找到MD5校验文件，跳过校验"
    fi
    
    # 创建临时目录进行恢复
    local restore_temp_dir=$(mktemp -d) || { log_error "无法创建临时目录"; return 1; }
    
    cleanup_restore_temp() { [[ -d "${restore_temp_dir:-}" ]] && rm -rf "$restore_temp_dir"; }
    add_cleanup_function "cleanup_restore_temp"
    
    # 直接复制备份目录到临时目录
    log_info "恢复模型文件..."
    local restored_model_dir="$restore_temp_dir/restored_model"
    if ! cp -r "$backup_dir" "$restored_model_dir"; then
        log_error "备份恢复失败"
        cleanup_restore_temp
        remove_cleanup_function "cleanup_restore_temp"
        return 1
    fi
    
    # 将恢复的模型复制到缓存目录供转换脚本使用
    local cache_model_dir="${ABS_HF_DOWNLOAD_CACHE_DIR}/${model_safe_name}"
    
    # 清理旧缓存并复制恢复的模型
    [[ -d "$cache_model_dir" ]] && rm -rf "$cache_model_dir"
    if ! cp -r "$restored_model_dir" "$cache_model_dir"; then
        log_error "模型复制失败"
        cleanup_restore_temp
        remove_cleanup_function "cleanup_restore_temp"
        return 1
    fi
    
    # 构建并执行转换命令，直接使用restore_temp_dir作为输出目录
    local container_name="llm-reconvert-$$"
    local docker_cmd=()
    mapfile -t docker_cmd < <(build_full_docker_cmd "$container_name" "true" "false" \
        --volume "${restore_temp_dir}:/app/models" \
        --volume "${ABS_HF_DOWNLOAD_CACHE_DIR}:/app/download_cache")
    
    [[ ${#docker_cmd[@]} -eq 0 ]] && { log_error "Docker命令构建失败"; return 1; }
    
    docker_cmd+=("${FULL_IMAGE_NAME}" "${model_name}" "--quantize" "${quantize_type}" "--gguf-dir" "/app/models")
    [[ "${VERBOSE}" == "true" ]] && docker_cmd+=("--verbose")
    
    # 执行转换
    local conversion_result=0
    log_info "开始重新转换模型..."
    
    if "${docker_cmd[@]}" >/dev/null 2>&1; then
        # 导入到Ollama，使用restore_temp_dir查找GGUF文件
        if import_gguf_to_ollama_from_temp "$model_name" "$quantize_type" "$restore_temp_dir"; then
            log_success "模型恢复、转换并导入完成: $model_name"
            conversion_result=0
        else
            log_error "转换成功但导入Ollama失败"
            conversion_result=1
        fi
    else
        log_error "模型转换失败: $model_name"
        conversion_result=1
    fi
    
    # 清理缓存
    [[ -d "$cache_model_dir" ]] && rm -rf "$cache_model_dir" 2>/dev/null
    cleanup_restore_temp
    remove_cleanup_function "cleanup_restore_temp"
    
    return $conversion_result
}

# 检查Ollama中是否存在指定模型（通用函数）


# 从临时目录导入GGUF模型到Ollama
import_gguf_to_ollama_from_temp() {
    local model_name="$1"
    local quantize_type="$2"
    local temp_dir="$3"
    
    log_ollama "开始从临时目录导入GGUF模型到Ollama: $model_name ($quantize_type)"
    
    # 查找临时目录中的GGUF文件
    local gguf_file=$(find "$temp_dir" -name "*.gguf" -type f | head -n1)
    if [[ ! -f "$gguf_file" ]]; then
        log_error "在临时目录中未找到GGUF文件: $temp_dir"
        return 1
    fi
    
    log_info "找到GGUF文件: $gguf_file"
    
    # 生成Ollama模型名称（带hf-前缀）
    local ollama_model_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
    log_ollama "Ollama模型名称: $ollama_model_name"
    
    # 检查模型是否已存在于Ollama中
    if check_ollama_model_exists "$ollama_model_name"; then
        log_success "模型已存在于Ollama中，跳过导入: $ollama_model_name"
        return 0
    fi
    
    # 创建临时Modelfile
    local temp_modelfile
    temp_modelfile=$(mktemp) || {
        log_error "无法创建临时Modelfile"
        return 1
    }
    cat > "$temp_modelfile" << EOF
FROM ${gguf_file}
TEMPLATE """{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
"""
PARAMETER stop "<|im_end|>"
PARAMETER temperature 0.7
PARAMETER top_p 0.9
EOF
    
    log_ollama "创建Modelfile: $temp_modelfile"
    
    # 使用临时容器导入GGUF模型
    log_ollama "启动临时容器导入GGUF模型"
    local import_name="ollama-import-$$"
    
    # 定义清理函数
    cleanup_import_container() {
        if docker ps -a --format "{{.Names}}" | grep -q "^${import_name}$"; then
            docker rm -f "$import_name" > /dev/null 2>&1
        fi
        rm -f "$temp_modelfile"
    }
    
    
    # 设置信号处理
    add_cleanup_function "cleanup_import_container"
    
    # 获取绝对路径
    local abs_ollama_dir
    # 对于Ollama容器，需要挂载的是.ollama目录（即data目录），而不是data/models
    abs_ollama_dir="$ABS_OLLAMA_DATA_DIR"
    
    # 启动临时容器
    local import_cmd=("docker" "run" "-d" "--name" "$import_name")
    
    # 添加GPU配置
    import_cmd+=("--gpus" "all")
    
    # 添加卷挂载
    import_cmd+=("-v" "${abs_ollama_dir}:/root/.ollama")
    import_cmd+=("-p" "11434:11434")  # 使用固定端口映射
    import_cmd+=("$DOCKER_IMAGE_OLLAMA")
    
    if ! "${import_cmd[@]}"; then
        log_error "无法启动临时导入容器"
        rm -f "$temp_modelfile"
        return 1
    fi
    
    # 等待服务就绪
    local max_attempts=30
    local attempt=0
    
    while (( attempt < max_attempts )); do
        if docker exec "$import_name" ollama list > /dev/null 2>&1; then
            break
        fi
        sleep 2
        ((attempt++))
    done
    
    if (( attempt >= max_attempts )); then
        log_error "等待导入容器服务超时"
        docker rm -f "$import_name" > /dev/null 2>&1
        rm -f "$temp_modelfile"
        return 1
    fi
    
    # 将GGUF文件和Modelfile复制到容器中
    local container_gguf_path="/tmp/$(basename "$gguf_file")"
    local container_modelfile="/tmp/Modelfile-$$"
    
    if ! docker cp "$gguf_file" "$import_name:$container_gguf_path"; then
        log_error "无法将GGUF文件复制到容器"
        docker rm -f "$import_name" > /dev/null 2>&1
        rm -f "$temp_modelfile"
        return 1
    fi
    
    # 更新Modelfile中的路径为容器内路径
    sed -i "s|FROM .*|FROM $container_gguf_path|" "$temp_modelfile"
    
    if ! docker cp "$temp_modelfile" "$import_name:$container_modelfile"; then
        log_error "无法将Modelfile复制到容器"
        docker rm -f "$import_name" > /dev/null 2>&1
        rm -f "$temp_modelfile"
        return 1
    fi
    
    # 在容器中执行ollama create命令
    log_ollama "执行命令: docker exec $import_name ollama create $ollama_model_name -f $container_modelfile"
    local result=1
    if docker exec "$import_name" ollama create "$ollama_model_name" -f "$container_modelfile"; then
        log_success "GGUF模型已导入Ollama: $ollama_model_name"
        result=0
    else
        log_error "GGUF模型导入失败: $ollama_model_name"
    fi
    
    # 清理容器和临时文件
    cleanup_import_container
    remove_cleanup_function "cleanup_import_container"
    
    return $result
}

# 下载并转换HuggingFace模型
download_huggingface_model() {
    local model_name="$1"
    local quantize_type="$2"
    
    log_docker "开始下载并转换HuggingFace模型: $model_name (量化: $quantize_type)"
    
    # 首先尝试从原始备份恢复并重新转换
    if restore_and_reconvert_hf_model "$model_name" "$quantize_type"; then
        local ollama_model_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
        log_success "从原始备份成功恢复并转换模型: $ollama_model_name"
        return 0
    fi
    
    # 只有在没有备份时才检测最优HuggingFace端点
    detect_optimal_hf_endpoint
    
    # 如果原始备份恢复失败，进行正常的下载流程
    
    # 创建临时目录用于存储GGUF文件
    local temp_dir
    temp_dir=$(mktemp -d) || {
        log_error "无法创建临时目录"
        return 1
    }
    
    # 定义清理函数
    cleanup_temp_dir() {
        if [[ -d "${temp_dir:-}" ]]; then
            log_info "清理临时目录: $temp_dir"
            docker_rm_rf "$temp_dir"
        fi
    }
    
    # 定义容器清理函数
    cleanup_converter_container() {
        local container_name="llm-converter-$$"
        if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
            log_warning "检测到中断，正在停止并清理转换容器: $container_name"
            docker stop "$container_name" > /dev/null 2>&1
            docker rm -f "$container_name" > /dev/null 2>&1
        fi
        cleanup_temp_dir
    }
    
    # 设置信号处理，确保容器被正确清理
    add_cleanup_function "cleanup_converter_container"
    
    # 构建docker run命令，使用指定的容器名
    local container_name="llm-converter-$$"
    mapfile -t docker_cmd < <(build_full_docker_cmd "$container_name" "true" "true" \
        --volume "$temp_dir:/app/models" \
        --volume "${ABS_HF_DOWNLOAD_CACHE_DIR}:/app/download_cache")
    
    
    
    # 镜像和参数
    docker_cmd+=("${FULL_IMAGE_NAME}")
    docker_cmd+=("${model_name}")
    docker_cmd+=("--quantize" "${quantize_type}")
    docker_cmd+=("--gguf-dir" "/app/models")
    
    # 添加verbose参数支持
    if [[ "${VERBOSE}" == "true" ]]; then
        docker_cmd+=("--verbose")
        log_docker "启用GPU支持"
        log_docker "设置HuggingFace访问令牌"
        log_docker "设置HuggingFace镜像端点: ${HF_ENDPOINT}"
        log_docker "设置容器时区: ${HOST_TIMEZONE}"
        log_docker "挂载下载缓存目录: ${ABS_HF_DOWNLOAD_CACHE_DIR}"
        log_docker "启用详细模式，将显示转换和量化的详细日志"
        log_docker "执行命令: ${docker_cmd[*]}"
    fi
    
    # 执行转换命令，使用实时输出
    local conversion_result=0
    log_docker "开始下载并转换，实时输出如下："
    echo "----------------------------------------"
    
    # 使用 unbuffer 或者直接管道输出来确保实时显示
    if "${docker_cmd[@]}" 2>&1 | while IFS= read -r line; do
        echo "[HF-DOCKER] $line"
    done; then
        echo "----------------------------------------"
        log_success "HuggingFace模型下载并转换完成: $model_name"
        
        # 自动导入到Ollama
        log_ollama "开始导入GGUF模型到Ollama..."
        if import_gguf_to_ollama_from_temp "$model_name" "$quantize_type" "$temp_dir"; then
            log_success "模型已成功导入到Ollama: $ollama_model_name"
            
            # 验证导入后的模型完整性
            local final_model_name="${ollama_model_name%:*}"
            local final_model_tag="${ollama_model_name#*:}"
            if verify_model_after_installation "$final_model_name" "$final_model_tag"; then
                log_success "模型完整性验证通过: $ollama_model_name"
            else
                log_error "模型完整性验证失败，模型已被清理: $ollama_model_name"
            fi
            
            # 新流程：在导入成功后进行备份和清理
            # 步骤1: 创建原始模型备份
            log_info "创建原始模型备份..."
            local model_safe_name=$(get_safe_model_name "$model_name" "filesystem")
            local cache_dir="${ABS_HF_DOWNLOAD_CACHE_DIR}/${model_safe_name}"
            
            # 检查是否存在缓存目录
            if [[ -d "$cache_dir" ]]; then
                if backup_hf_original_model "$model_name" "$cache_dir"; then
                    log_success "原始模型备份创建成功"
                    
                    # 步骤2: 删除已备份的原始模型缓存
                    log_info "删除已备份的原始模型缓存..."
                    if docker_rm_rf "$cache_dir"; then
                        log_success "原始模型缓存已清理: $cache_dir"
                    else
                        log_warning "清理原始模型缓存失败，但不影响主要功能"
                    fi
                else
                    log_warning "原始模型备份创建失败，保留缓存目录"
                fi
            else
                log_info "未找到缓存目录，跳过备份和清理"
            fi
        else
            log_warning "GGUF下载转换成功，但导入Ollama失败"
            conversion_result=1
        fi
    else
        echo "----------------------------------------"
        log_error "HuggingFace模型下载转换失败: $model_name"
        conversion_result=1
    fi
    
    # 手动清理并移除清理函数
    cleanup_converter_container
    remove_cleanup_function "cleanup_converter_container"
    
    return $conversion_result
}

# 检查Ollama模型在backups目录中是否有备份
check_ollama_backup_exists() {
    local model_name="$1"
    local model_tag="$2"
    
    # 使用与get_safe_model_name相同的逻辑生成安全名称
    local model_spec="${model_name}:${model_tag}"
    local model_safe_name=$(get_safe_model_name "$model_spec")
    local backup_parent_dir="$BACKUP_OUTPUT_DIR/${model_safe_name}"
    local backup_model_dir="$backup_parent_dir/${model_safe_name}"
    
    # 检查备份目录是否存在
    if [[ -d "$backup_model_dir" ]]; then
        # 检查是否有有效的目录备份结构
        if [[ -d "$backup_model_dir/manifests" ]] && [[ -d "$backup_model_dir/blobs" ]]; then
            echo "$backup_parent_dir"
            return 0
        fi
    fi
    
    return 1
}

# 检查HuggingFace模型在hf_originals目录中是否有备份
check_hf_original_backup_exists() {
    local model_name="$1"
    
    # 使用统一的文件系统安全命名
    local model_safe_name=$(get_safe_model_name "$model_name" "filesystem")
    local backup_dir="$ABS_HF_ORIGINAL_BACKUP_DIR/${model_safe_name}"
    local backup_source_dir="$backup_dir/${model_safe_name}_original"
    
    # 检查备份目录是否存在
    if [[ -d "$backup_dir" ]]; then
        # 检查是否有原始备份目录
        if [[ -d "$backup_source_dir" ]]; then
            echo "$backup_dir"
            return 0
        fi
    fi
    
    return 1
}

# 尝试从备份恢复Ollama模型
try_restore_ollama_from_backup() {
    local model_name="$1"
    local model_tag="$2"
    
    log_info "检查Ollama模型备份: ${model_name}:${model_tag}"
    
    local backup_dir
    if backup_dir=$(check_ollama_backup_exists "$model_name" "$model_tag"); then
        log_info "找到Ollama模型备份: $backup_dir"
        
        # 使用与get_safe_model_name相同的逻辑生成安全名称
        local model_spec="${model_name}:${model_tag}"
        local model_safe_name=$(get_safe_model_name "$model_spec")
        
        # 查找备份目录（新的直接复制格式）
        local backup_model_dir="$backup_dir/$model_safe_name"
        if [[ -d "$backup_model_dir" ]]; then
            # 恢复模型
            log_info "正在从备份恢复模型..."
            if restore_ollama_model "$backup_model_dir" "true"; then
                log_success "从备份成功恢复模型: ${model_name}:${model_tag}"
                return 0
            else
                log_warning "从备份恢复模型失败，将尝试重新下载"
                return 1
            fi
        else
            log_error "未找到有效的备份目录: $backup_model_dir"
            return 1
        fi
    else
        log_info "未找到Ollama模型备份"
        return 1
    fi
}

# 尝试从HuggingFace原始备份恢复模型
try_restore_hf_from_original() {
    local model_name="$1"
    
    log_info "检查HuggingFace原始模型备份: $model_name"
    
    local backup_dir
    if backup_dir=$(check_hf_original_backup_exists "$model_name"); then
        log_info "找到HuggingFace原始模型备份: $backup_dir"
        
        # 使用统一的文件系统安全命名
        local model_safe_name=$(get_safe_model_name "$model_name" "filesystem")
        
        # 查找原始备份目录（新的直接复制格式）
        local backup_source_dir="$backup_dir/${model_safe_name}_original"
        if [[ -d "$backup_source_dir" ]]; then
            # 恢复到缓存目录
            local cache_dir="$ABS_HF_DOWNLOAD_CACHE_DIR/$model_safe_name"
            log_info "正在恢复HuggingFace原始模型到缓存目录..."
            
            # MD5校验
            local md5_file="${backup_source_dir}.md5"
            if [[ -f "$md5_file" ]]; then
                log_info "正在验证MD5校验值..."
                if verify_directory_md5 "$backup_source_dir" "$md5_file"; then
                    log_success "MD5校验通过"
                else
                    log_error "MD5校验失败，备份可能已损坏"
                    return 1
                fi
            else
                log_warning "未找到MD5校验文件，跳过校验"
            fi
            
            # 创建缓存目录
            mkdir -p "$(dirname "$cache_dir")"
            
            # 直接复制备份目录到缓存目录
            if cp -r "$backup_source_dir" "$cache_dir"; then
                log_success "从原始备份成功恢复模型到缓存: $model_name"
                return 0
            else
                log_warning "从原始备份恢复失败"
                return 1
            fi
        else
            log_error "未找到有效的原始备份目录: $backup_source_dir"
            return 1
        fi
    else
        log_info "未找到HuggingFace原始模型备份"
        return 1
    fi
}

# 处理单个模型
process_model() {
    local model_entry="$1"
    local force_download="$2"
    local check_only="$3"
    
    local model_name model_tag quantize_type check_func download_func model_display
    
    # 解析模型条目并设置相应的检查和下载函数
    if [[ "$model_entry" =~ ^ollama:([^:]+):(.+)$ ]]; then
        model_name="${BASH_REMATCH[1]}"
        model_tag="${BASH_REMATCH[2]}"
        model_display="${model_name}:${model_tag} (Ollama)"
        check_func() { check_ollama_model "$model_name" "$model_tag"; }
        download_func() { download_ollama_model "$model_name" "$model_tag"; }
        
    elif [[ "$model_entry" =~ ^huggingface:([^:]+):(.+)$ ]]; then
        model_name="${BASH_REMATCH[1]}"
        quantize_type="${BASH_REMATCH[2]}"
        model_display="$model_name (量化: $quantize_type)"
        check_func() { check_huggingface_model_in_ollama "$model_name" "$quantize_type"; }
        download_func() { download_huggingface_model "$model_name" "$quantize_type"; }
        
    elif [[ "$model_entry" =~ ^hf-gguf:(.+)$ ]]; then
        local model_full_name="${BASH_REMATCH[1]}"
        if [[ "$model_full_name" =~ ^(.+):(.+)$ ]]; then
            model_name="${BASH_REMATCH[1]}"
            model_tag="${BASH_REMATCH[2]}"
        else
            model_name="$model_full_name"
            model_tag="latest"
        fi
        model_display="${model_name}:${model_tag} (HF-GGUF)"
        check_func() { check_hf_gguf_model "$model_name" "$model_tag"; }
        download_func() { download_hf_gguf_model "$model_name" "$model_tag"; }
        
    else
        log_error "无效的模型条目格式: $model_entry"
        return 1
    fi
    
    log_info "处理模型: $model_display"
    
    # 统一的处理逻辑
    if [[ "$force_download" == "true" ]] || ! check_func; then
        if [[ "$check_only" == "true" ]]; then
            log_warning "需要下载: $model_display"
        else
            # 模型不存在，尝试智能恢复
            local restore_success=false
            
            # 1. 首先尝试从Ollama备份恢复（适用于所有模型类型）
            if [[ "$model_entry" =~ ^ollama: ]]; then
                if try_restore_ollama_from_backup "$model_name" "$model_tag"; then
                    restore_success=true
                fi
            elif [[ "$model_entry" =~ ^huggingface: ]]; then
                # 对于HuggingFace模型，先检查是否已经转换并在Ollama中
                local expected_ollama_name=$(generate_ollama_model_name "$model_name" "$quantize_type")
                # 提取模型名称和标签
                local ollama_model_name="${expected_ollama_name%:*}"    # 提取冒号前的部分（包含hf-前缀）
                local ollama_model_tag="${expected_ollama_name#*:}"     # 提取冒号后的部分
                
                if try_restore_ollama_from_backup "$ollama_model_name" "$ollama_model_tag"; then
                    restore_success=true
                fi
            elif [[ "$model_entry" =~ ^hf-gguf: ]]; then
                if try_restore_ollama_from_backup "$model_name" "$model_tag"; then
                    restore_success=true
                fi
            fi
            
            # 2. 如果Ollama备份恢复失败，且是HuggingFace模型，尝试从原始备份恢复
            if [[ "$restore_success" == "false" ]] && [[ "$model_entry" =~ ^huggingface: ]]; then
                if try_restore_hf_from_original "$model_name"; then
                    log_info "HuggingFace原始模型已恢复到缓存，继续转换流程..."
                fi
            fi
            
            # 3. 如果恢复成功，直接返回成功
            if [[ "$restore_success" == "true" ]]; then
                log_success "从备份恢复后模型已可用"
                # 清除缓存，强制下次重新检查
                OLLAMA_CACHE_INITIALIZED="false"
                OLLAMA_MODELS_CACHE=""
                return 0
            fi
            
            # 4. 如果恢复失败，执行正常下载流程
            if download_func; then
                log_success "模型下载完成"
                # 清除缓存，强制下次重新检查
                OLLAMA_CACHE_INITIALIZED="false"
                OLLAMA_MODELS_CACHE=""
                return 0
            else
                log_error "模型下载失败"
                return 1
            fi
        fi
    else
        log_success "模型已存在"
    fi
}

# 主函数
main() {
    # 获取主机时区
    HOST_TIMEZONE=$(get_host_timezone)
    
    # 检查参数
    if [[ "${1:-}" = "--help" || "${1:-}" = "-h" ]]; then
        show_help
        exit 0
    fi
    
    # 默认值
    MODELS_FILE="$MODELS_LIST_FILE"
    CHECK_ONLY="true"
    FORCE_DOWNLOAD="false"
    REBUILD="false"
    HF_TOKEN=""
    BACKUP_MODEL=""
    BACKUP_ALL="false"
    LIST_MODELS="false"
    RESTORE_FILE=""
    GENERATE_COMPOSE="false"
    FORCE_RESTORE="false"
    REMOVE_MODEL=""
    REMOVE_ALL="false"
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --models-file)
                MODELS_FILE="$2"
                shift 2
                ;;
            --ollama-dir)
                # 处理用户指定的Ollama目录
                local user_ollama_dir="$2"
                user_ollama_dir="${user_ollama_dir%/}"  # 移除末尾斜杠
                
                # 设置数据目录和模型目录
                if [[ "$user_ollama_dir" == */models ]]; then
                    OLLAMA_MODELS_DIR="$user_ollama_dir"
                    OLLAMA_DATA_DIR="${user_ollama_dir%/models}"
                else
                    OLLAMA_DATA_DIR="$user_ollama_dir"
                    OLLAMA_MODELS_DIR="$user_ollama_dir/models"
                fi
                shift 2
                ;;
            --hf-backup-dir)
                HF_ORIGINAL_BACKUP_DIR="$2"
                shift 2
                ;;
            --backup)
                BACKUP_MODEL="$2"
                shift 2
                ;;
            --backup-all)
                BACKUP_ALL="true"
                shift
                ;;
            --list)
                LIST_MODELS="true"
                shift
                ;;
            --restore)
                RESTORE_FILE="$2"
                shift 2
                ;;
            --remove)
                REMOVE_MODEL="$2"
                shift 2
                ;;
            --remove-all)
                REMOVE_ALL="true"
                shift
                ;;
            --backup-dir)
                BACKUP_OUTPUT_DIR="$2"
                shift 2
                ;;
            --check-only)
                CHECK_ONLY="true"
                shift
                ;;
            --install)
                CHECK_ONLY="false"
                shift
                ;;
            --force-download)
                FORCE_DOWNLOAD="true"
                CHECK_ONLY="false"  # 强制下载时应该实际执行下载
                shift
                ;;
            --force)
                FORCE_RESTORE="true"
                shift
                ;;
            --hf-token)
                HF_TOKEN="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --rebuild)
                REBUILD="true"
                shift
                ;;
            --generate-compose)
                GENERATE_COMPOSE="true"
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 显示配置
    log_info "=== 配置信息 ==="
    log_info "模型列表文件: $MODELS_FILE"
    log_info "Ollama模型目录: $OLLAMA_MODELS_DIR"
    if [[ -n "$BACKUP_MODEL" ]]; then
        log_info "备份Ollama模型: $BACKUP_MODEL"
        log_info "备份目录: $BACKUP_OUTPUT_DIR"
    elif [[ "$BACKUP_ALL" == "true" ]]; then
        log_info "批量备份所有模型"
        log_info "备份目录: $BACKUP_OUTPUT_DIR"
    elif [[ -n "$RESTORE_FILE" ]]; then
        log_info "恢复模型文件: $RESTORE_FILE"
        log_info "强制覆盖: $FORCE_RESTORE"
    elif [[ -n "$REMOVE_MODEL" ]]; then
        log_info "删除模型: $REMOVE_MODEL"
    elif [[ "$REMOVE_ALL" == "true" ]]; then
        log_info "批量删除所有模型"
    fi
    log_info "仅检查模式: $CHECK_ONLY"
    log_info "强制下载: $FORCE_DOWNLOAD"
    log_info "详细模式: $VERBOSE"
    log_info "HuggingFace镜像: $HF_ENDPOINT"
    log_info "=================="
    
    # 初始化路径
    init_paths
    
    # 检查和创建Ollama模型目录
    if [[ ! -d "$OLLAMA_MODELS_DIR" ]]; then
        log_info "Ollama模型目录不存在，尝试创建: $OLLAMA_MODELS_DIR"
        local ollama_base_dir=$(dirname "$OLLAMA_MODELS_DIR")
        if [[ ! -d "$ollama_base_dir" ]]; then
            log_warning "Ollama数据目录不存在: $ollama_base_dir"
            log_info "请确保容器挂载了正确的数据目录，或手动创建目录"
            # 创建目录（如果可能）
            if mkdir -p "$OLLAMA_MODELS_DIR" 2>/dev/null; then
                log_success "已创建Ollama模型目录: $OLLAMA_MODELS_DIR"
            else
                log_warning "无法创建Ollama模型目录，某些功能可能不可用"
            fi
        else
            # 基础目录存在，创建models子目录
            if mkdir -p "$OLLAMA_MODELS_DIR" 2>/dev/null; then
                log_success "已创建Ollama模型目录: $OLLAMA_MODELS_DIR"
            else
                log_warning "无法创建Ollama模型目录，某些功能可能不可用"
            fi
        fi
    else
        log_success "Ollama模型目录已存在: $OLLAMA_MODELS_DIR"
    fi
    
    # 如果是备份模式，执行备份并退出
    if [[ -n "$BACKUP_MODEL" ]]; then
        log_info "执行Ollama模型备份..."
        
        # 处理不同类型的模型前缀
        local model_to_backup="$BACKUP_MODEL"
        if [[ "$BACKUP_MODEL" =~ ^hf-gguf:(.+)$ ]]; then
            model_to_backup="${BASH_REMATCH[1]}"
        elif [[ "$BACKUP_MODEL" =~ ^ollama:(.+)$ ]]; then
            model_to_backup="${BASH_REMATCH[1]}"
        elif [[ "$BACKUP_MODEL" =~ ^huggingface:([^:]+):(.+)$ ]]; then
            # HuggingFace模型需要转换为Ollama格式
            local model_name="${BASH_REMATCH[1]}"
            local quantize_type="${BASH_REMATCH[2]}"
            model_to_backup=$(generate_ollama_model_name "$model_name" "$quantize_type")
        fi
        
        if backup_ollama_model "$model_to_backup" "$BACKUP_OUTPUT_DIR"; then
            log_success "模型备份完成"
            exit 0
        else
            log_error "模型备份失败"
            exit 1
        fi
    elif [[ "$BACKUP_ALL" == "true" ]]; then
        log_info "执行批量模型备份..."
        if backup_models_from_list "$MODELS_FILE" "$BACKUP_OUTPUT_DIR"; then
            log_success "批量备份完成"
            exit 0
        else
            log_error "批量备份失败"
            exit 1
        fi
    elif [[ "$LIST_MODELS" == "true" ]]; then
        log_info "执行模型列表查询..."
        if list_installed_models; then
            exit 0
        else
            log_error "模型列表查询失败"
            exit 1
        fi
    elif [[ "$GENERATE_COMPOSE" == "true" ]]; then
        log_info "生成docker-compose.yaml文件..."
        if generate_docker_compose; then
            exit 0
        else
            log_error "生成docker-compose.yaml失败"
            exit 1
        fi
    elif [[ -n "$RESTORE_FILE" ]]; then
        log_info "执行模型恢复..."
        
        # 如果恢复文件不是绝对路径，则在BACKUP_OUTPUT_DIR中查找
        local restore_path="$RESTORE_FILE"
        if [[ "$RESTORE_FILE" != /* ]]; then
            restore_path="$BACKUP_OUTPUT_DIR/$RESTORE_FILE"
        fi
        
        if restore_ollama_model "$restore_path" "$FORCE_RESTORE"; then
            log_success "模型恢复完成"
            exit 0
        else
            log_error "模型恢复失败"
            exit 1
        fi
    elif [[ -n "$REMOVE_MODEL" ]]; then
        log_info "执行模型删除..."
        if remove_model_smart "$REMOVE_MODEL" "$FORCE_RESTORE"; then
            log_success "模型删除完成"
            exit 0
        else
            log_error "模型删除失败"
            exit 1
        fi
    elif [[ "$REMOVE_ALL" == "true" ]]; then
        log_info "执行批量模型删除..."
        if remove_models_from_list "$MODELS_FILE" "$FORCE_RESTORE"; then
            log_success "批量删除完成"
            exit 0
        else
            log_error "批量删除失败"
            exit 1
        fi
    fi
    
    # 检查依赖
    check_dependencies
    
    # 解析模型列表
    local models=()
    parse_models_list "$MODELS_FILE" models
    
    if [[ ${#models[@]} -eq 0 ]]; then
        log_warning "没有找到任何模型，退出"
        exit 0
    fi
    
    # 检查是否需要Docker镜像（仅在有HuggingFace模型时）
    local has_hf_models=false
    for model in "${models[@]}"; do
        if [[ "$model" =~ ^huggingface:|^hf-gguf: ]]; then
            has_hf_models=true
            break
        fi
    done
    
    if [[ "$has_hf_models" == "true" ]]; then
        if [[ "$REBUILD" == "true" ]]; then
            build_docker_image
        else
            # 确保Docker镜像存在
            ensure_hf_downloader_image
        fi
    fi
    
    # 处理每个模型
    local total_models=${#models[@]}
    local processed=0
    local failed=0
    
    for model in "${models[@]}"; do
        processed=$((processed + 1))
        log_info "处理模型 [$processed/$total_models]: $model"
        
        # 处理单个模型错误，不中断整个流程
        if ! process_model "$model" "$FORCE_DOWNLOAD" "$CHECK_ONLY"; then
            failed=$((failed + 1))
        fi
    done
    
    # 显示总结
    log_info "=== 处理完成 ==="
    log_info "总模型数: $total_models"
    log_info "已处理: $processed"
    if [[ $failed -gt 0 ]]; then
        log_warning "失败: $failed"
    else
        log_success "全部成功完成"
    fi
    
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "检查模式完成，未执行实际下载"
    fi
}

# ==================================================================================
#                           Docker Compose生成功能
# ==================================================================================

# 生成docker-compose.yaml文件
update_existing_compose() {
    local output_file="$1"
    local custom_models="$2"
    local default_model="$3"
    
    log_info "更新现有docker-compose.yaml文件中的CUSTOM_MODELS配置"
    
    # 创建备份
    local backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$output_file" "$backup_file"
    log_info "已备份现有文件: $backup_file"
    
    # 使用Python脚本更新CUSTOM_MODELS环境变量
    if grep -q "CUSTOM_MODELS=" "$output_file"; then
        # 使用Python来精确处理YAML文件中的多行CUSTOM_MODELS
        # 使用临时文件存储多行内容
        local temp_models_file=$(mktemp)
        echo "$custom_models" > "$temp_models_file"
        
        # 使用纯shell实现替换功能
        update_docker_compose_models() {
            local file_path="$1"
            local models_file="$2"
            local default_model="$3"
            
            # 读取新的模型配置
            local new_models
            new_models=$(cat "$models_file")
            
            # 创建临时文件
            local temp_file=$(mktemp)
            
            # 使用sed和简单的状态机处理多行CUSTOM_MODELS替换
            # 首先标记开始和结束位置
            start_line=$(grep -n '^[[:space:]]*-[[:space:]]*"CUSTOM_MODELS=' "$file_path" | cut -d: -f1)
            end_line=$(tail -n +$((start_line + 1)) "$file_path" | grep -n '"$' | head -1 | cut -d: -f1)
            end_line=$((start_line + end_line))
            
            if [[ -n "$start_line" && -n "$end_line" ]]; then
                # 提取前缀（缩进和"CUSTOM_MODELS="）
                prefix=$(sed -n "${start_line}p" "$file_path" | sed 's/\(^[[:space:]]*-[[:space:]]*"CUSTOM_MODELS=\).*/\1/')
                
                # 构建新文件：头部 + 新行 + 尾部
                head -n $((start_line - 1)) "$file_path" > "$temp_file"
                echo "${prefix}${new_models}\"" >> "$temp_file"
                tail -n +$((end_line + 1)) "$file_path" >> "$temp_file"
            else
                # 如果找不到多行格式，回退到简单替换
                cp "$file_path" "$temp_file"
            fi
            
            # 处理DEFAULT_MODEL替换  
            sed -E "s|(^[[:space:]]*-[[:space:]]*DEFAULT_MODEL=)[^[:space:]#]*(.*)|\\1${default_model}  # 自动设置为models.list第一个模型|" "$temp_file" > "$file_path"
            
            # 清理临时文件
            rm -f "$temp_file"
            return 0
        }
        
        if update_docker_compose_models "$output_file" "$temp_models_file" "$default_model"; then
            echo "SUCCESS"
        else
            echo "ERROR: Failed to update docker-compose.yaml"
            exit 1
        fi
        
        # 清理临时文件
        rm -f "$temp_models_file"
        
        if [[ $? -eq 0 ]]; then
            log_success "成功更新docker-compose.yaml中的CUSTOM_MODELS配置"
            log_info "更新内容: $custom_models"
        else
            log_error "使用Python更新失败，尝试使用sed方法"
            
            # 备用方法：使用sed进行简单替换
            sed -i.tmp "s|CUSTOM_MODELS=[^\"]*|CUSTOM_MODELS=$custom_models|g" "$output_file"
            rm -f "${output_file}.tmp"
            
            log_success "使用sed成功更新CUSTOM_MODELS配置"
        fi
    else
        log_error "未在docker-compose.yaml中找到CUSTOM_MODELS配置"
        return 1
    fi
    
    return 0
}

generate_docker_compose() {
    local output_file="${1:-./docker-compose.yaml}"
    local models_file="${MODELS_FILE:-./models.list}"
    
    # 检查模型列表文件是否存在
    if [[ ! -f "$models_file" ]]; then
        log_error "模型列表文件不存在: $models_file"
        return 1
    fi
    
    # 检查是否已存在docker-compose.yaml文件
    if [[ -f "$output_file" ]]; then
        log_info "检测到现有docker-compose.yaml文件，将更新CUSTOM_MODELS配置"
        
        # 生成CUSTOM_MODELS内容
        local custom_models_content
        custom_models_content=$(generate_custom_models_list "$models_file")
        
        if [[ -z "$custom_models_content" ]]; then
            log_warning "未找到激活的模型，将生成默认配置"
            custom_models_content="-all"
        fi
        
        # 检查是否有可用的模型
        if [[ "$custom_models_content" == "-all" ]]; then
            log_error "错误: models.list 中没有找到可用的模型配置"
            log_error "请确保 models.list 中至少有一个未被注释的模型配置"
            return 1
        fi
        
        # 自动检测默认模型
        local default_model
        default_model=$(detect_default_model "$models_file")
        
        [[ -n "${VERBOSE}" ]] && log_info "生成的CUSTOM_MODELS: $custom_models_content"
        [[ -n "${VERBOSE}" ]] && log_info "检测到的默认模型: $default_model"
        
        # 更新现有文件
        update_existing_compose "$output_file" "$custom_models_content" "$default_model"
    else
        log_info "基于模型列表生成docker-compose.yaml: $models_file"
        
        # 生成CUSTOM_MODELS内容
        local custom_models_content
        custom_models_content=$(generate_custom_models_list "$models_file")
        
        if [[ -z "$custom_models_content" ]]; then
            log_warning "未找到激活的模型，将生成默认配置"
            custom_models_content="-all"
        fi
        
        # 自动检测默认模型
        local default_model
        default_model=$(detect_default_model "$models_file")
        
        # 检查是否有可用的模型 (CUSTOM_MODELS只有-all说明没有激活的模型)
        if [[ "$custom_models_content" == "-all" ]]; then
            log_error "错误: models.list 中没有找到可用的模型配置"
            log_error "请确保 models.list 中至少有一个未被注释的模型配置"
            return 1
        fi
        
        [[ -n "${VERBOSE}" ]] && log_info "生成的CUSTOM_MODELS: $custom_models_content"
        [[ -n "${VERBOSE}" ]] && log_info "检测到的默认模型: $default_model"
        
        # 生成docker-compose.yaml内容
        generate_compose_content "$output_file" "$custom_models_content" "$default_model"
    fi
}

# 生成CUSTOM_MODELS列表
generate_custom_models_list() {
    local models_file="$1"
    local custom_models_entries=()
    
    # 添加 -all 作为第一个条目（隐藏所有默认模型）
    custom_models_entries+=("-all")
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释行和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # 解析行内容
        read -r model_type model_spec quantize_type <<< "$line"
        
        case "$model_type" in
            "ollama")
                if [[ -n "$model_spec" ]]; then
                    local alias=$(generate_model_alias "$model_spec" "ollama")
                    local entry="+${model_spec}@OpenAI=${alias}"
                    custom_models_entries+=("$entry")
                fi
                ;;
            "hf-gguf")
                if [[ -n "$model_spec" ]]; then
                    local alias=$(generate_model_alias "$model_spec" "hf-gguf")
                    local entry="+${model_spec}@OpenAI=${alias}"
                    custom_models_entries+=("$entry")
                fi
                ;;
            "huggingface")
                if [[ -n "$model_spec" && -n "$quantize_type" ]]; then
                    local ollama_name=$(echo "$model_spec" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g')
                    local alias=$(generate_model_alias "${ollama_name}:latest" "huggingface")
                    local entry="+${ollama_name}:latest@OpenAI=${alias}"
                    custom_models_entries+=("$entry")
                fi
                ;;
        esac
    done < "$models_file"
    
    # 输出CUSTOM_MODELS格式
    if [[ ${#custom_models_entries[@]} -gt 1 ]]; then
        printf '%s' "${custom_models_entries[0]}"
        for ((i=1; i<${#custom_models_entries[@]}; i++)); do
            printf ',\\\n        %s' "${custom_models_entries[i]}"
        done
    else
        echo "-all"
    fi
}

# 生成简单的模型别名
generate_model_alias() {
    local model_spec="$1"
    local model_type="$2"
    
    # 根据模型类型提取实际的模型名称
    local model_name=""
    local model_version=""
    
    case "$model_type" in
        "hf-gguf")
            # 对于 hf-gguf 模型，从路径中提取模型名称
            # 格式如: hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
            if [[ "$model_spec" =~ hf\.co/[^/]+/([^/:]+) ]]; then
                model_name="${BASH_REMATCH[1]}"
                # 移除常见的 GGUF 后缀
                model_name=$(echo "$model_name" | sed 's/-GGUF$//' | sed 's/_GGUF$//')
            fi
            ;;
        "huggingface")
            # 对于 huggingface 模型，使用传递的已处理名称
            model_name="$model_spec"
            model_name="${model_name%:*}"
            ;;
        *)
            # 对于 ollama 和其他类型，使用基础名称
            model_name="${model_spec%:*}"
            ;;
    esac
    
    # 从模型规格中提取版本信息
    if [[ "$model_spec" =~ :(.+)$ ]]; then
        model_version="${BASH_REMATCH[1]}"
    fi
    
    # 如果没有提取到模型名称，使用类型作为后备
    if [[ -z "$model_name" ]]; then
        model_name="$model_type"
    fi
    
    # 清理模型名称和版本中的特殊字符
    local clean_name=$(echo "$model_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    
    if [[ -n "$model_version" && "$model_version" != "latest" ]]; then
        local clean_version=$(echo "$model_version" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
        echo "${clean_name}-${clean_version}"
    else
        echo "$clean_name"
    fi
}

# 检测默认模型
detect_default_model() {
    local models_file="$1"
    local first_active_model=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释行和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # 解析行内容
        read -r model_type model_spec quantize_type <<< "$line"
        
        # 找到第一个激活的模型并生成其别名
        if [[ -n "$model_spec" && -z "$first_active_model" ]]; then
            case "$model_type" in
                "ollama")
                    first_active_model=$(generate_model_alias "$model_spec" "ollama")
                    break
                    ;;
                "hf-gguf")
                    first_active_model=$(generate_model_alias "$model_spec" "hf-gguf")
                    break
                    ;;
                "huggingface")
                    if [[ -n "$quantize_type" ]]; then
                        local ollama_name=$(echo "$model_spec" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g')
                        first_active_model=$(generate_model_alias "${ollama_name}:latest" "huggingface")
                        break
                    fi
                    ;;
            esac
        fi
    done < "$models_file"
    
    # 如果没有找到激活的模型，使用默认值
    echo "${first_active_model:-qwen3-14b}"
}

# 生成docker-compose.yaml文件内容
detect_gpus() {
    local gpu_indices=""
    
    if command -v nvidia-smi &>/dev/null; then
        gpu_indices=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$gpu_indices" ]]; then
            echo "$gpu_indices"
        else
            echo "0,1,2,3"
        fi
    else
        echo "0,1,2,3"
    fi
}

generate_compose_content() {
    local output_file="$1"
    local custom_models="$2"
    local default_model="$3"
    
    local cuda_devices
    cuda_devices=$(detect_gpus)
    
    # 获取主机时区
    local host_timezone=$(get_host_timezone)
    [[ -z "$host_timezone" ]] && host_timezone="UTC"
    
    # 如果文件已存在，创建备份
    if [[ -f "$output_file" ]]; then
        local backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$output_file" "$backup_file"
        log_info "已备份现有文件: $backup_file"
    fi
    
    # 生成docker-compose.yaml内容
    cat > "$output_file" << EOF
services:
  ollama:
    image: $DOCKER_IMAGE_OLLAMA
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ./ollama:/root/.ollama
    networks:
      - llms-tools-network
    environment:
      # Ollama优化配置
      - CUDA_VISIBLE_DEVICES=$cuda_devices # 自动检测并使用所有可用GPU
      - OLLAMA_NEW_ENGINE=1 # 新的引擎, ollamarunner
      - OLLAMA_SCHED_SPREAD=1 # 启用多GPU负载均衡
      - OLLAMA_KEEP_ALIVE=5m # 模型在内存中保持加载的时长, 分钟
      - OLLAMA_NUM_PARALLEL=3 # 并发请求数
      - OLLAMA_FLASH_ATTENTION=1 # flash attention, 用于优化注意力计算, 降低显存使用
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [ gpu ]
    command: [ "serve"]
    restart: unless-stopped

  one-api:
    image: $DOCKER_IMAGE_ONE_API
    container_name: one-api
    volumes:
      - ./one-api:/data
    networks:
      - llms-tools-network
    ports:
      - "3001:3001"
    depends_on:
      - ollama
    environment:
      - TZ=${host_timezone}
      - SESSION_SECRET=xxxxxxxxxxxxxxxxxxxxxx  # 修改为随机生成的会话密钥
    command: [ "--port", "3001" ]
    restart: unless-stopped

  prompt-optimizer:
    image: $DOCKER_IMAGE_PROMPT_OPTIMIZER
    container_name: prompt-optimizer
    ports:
      - "8501:80"
    environment:
      - VITE_CUSTOM_API_BASE_URL=http://YOUR_SERVER_IP:3001/v1  # 修改为你的服务器IP地址
      - VITE_CUSTOM_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # 修改为你的API密钥
      - VITE_CUSTOM_API_MODEL=$default_model  # 自动设置为models.list第一个模型
      - ACCESS_USERNAME=admin  # 修改为你的用户名
      - ACCESS_PASSWORD=xxxxxxxxxxxxxxxxxxxxxx  # 修改为你的密码
    networks:
      - llms-tools-network
    depends_on:
      - one-api
    restart: unless-stopped

  chatgpt-next-web:
    image: $DOCKER_IMAGE_CHATGPT_NEXT_WEB
    container_name: chatgpt-next-web
    ports:
      - "3000:3000"
    environment:
      - OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # 修改为你的OpenAI API密钥
      - BASE_URL=http://one-api:3001
      - PROXY_URL=
      - "CUSTOM_MODELS=$custom_models"
      - DEFAULT_MODEL=$default_model  # 自动设置为models.list第一个模型
      - CODE=xxxxxxxxxxxxxxxxxxxxxx  # 修改为你的访问密码
    networks:
      - llms-tools-network
    depends_on:
      - one-api
    restart: unless-stopped

networks:
  llms-tools-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.28.0/24
EOF

    log_success "成功生成docker-compose.yaml文件: $output_file"
    log_info "包含模型配置: $custom_models"
    log_info "默认模型: $default_model"
    log_info "检测到GPU设备: $cuda_devices"
    echo ""
    log_info "⚠️  重要提示: 生成的配置文件中包含占位符，请根据以下说明修改："
    log_info "== 必须修改的配置 =="
    log_info "1. VITE_CUSTOM_API_BASE_URL: 将 YOUR_SERVER_IP 替换为实际服务器IP地址"
    log_info "2. VITE_CUSTOM_API_KEY: 替换为 one-api 中的有效API密钥"
    log_info "3. ACCESS_USERNAME/ACCESS_PASSWORD: 设置 prompt-optimizer 的登录凭据"
    log_info "4. OPENAI_API_KEY: 替换为 one-api 中的有效API密钥"
    log_info "5. SESSION_SECRET: 替换为随机生成的会话密钥（建议32位随机字符串）"
    log_info "6. CODE: 设置 ChatGPT-Next-Web 的访问密码"
    log_info "7. VITE_CUSTOM_API_MODEL/DEFAULT_MODEL: 已自动设置为 $default_model，可根据需要修改"
    echo ""
    log_info "== 可选修改的配置 =="
    log_info "• 端口映射: 如需避免端口冲突，可修改 ports 部分的主机端口"
    log_info "  - Ollama: 11434 -> 自定义端口"
    log_info "  - One-API: 3001 -> 自定义端口" 
    log_info "  - Prompt-Optimizer: 8501 -> 自定义端口"
    log_info "  - ChatGPT-Next-Web: 3000 -> 自定义端口"
    log_info "• Docker镜像: 如需使用特定版本，可修改 image 部分的标签"
    log_info "• 网络配置: 可修改 subnet 以避免IP地址冲突"
    echo ""
    log_info "配置完成后运行: docker-compose up -d 来启动服务"
    
    return 0
}

# 只有在直接运行脚本时才执行main函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
