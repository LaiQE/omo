#!/bin/bash
# =============================================================================
# OMO (oh-my-ollama or Ollama Models Organizer)
# =============================================================================
#
# 🤖 功能概览：
#   📥 模型下载：
#       • 从Ollama官方仓库下载模型
#       • 直接下载HuggingFace的GGUF格式模型
#
#   💾 模型备份：
#       • 完整备份Ollama模型（manifest + blobs）
#       • MD5校验确保数据完整性
#       • 生成详细备份信息文件
#
#   🔄 模型恢复：
#       • 从备份恢复Ollama模型
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
#       • 并行处理和缓存优化
#       • 详细日志和错误处理
#
# 📝 支持的模型格式：
#   • ollama [model]:[tag]     - Ollama官方模型
#   • hf-gguf [model]:[tag]    - HuggingFace GGUF模型(直接导入)
#
# 🔧 环境要求：
#   • Docker, nvidia gpu, rsync
#
# 👨‍💻 作者：Chain Lai
# 📖 详细使用说明请运行：./omo.sh --help
# =============================================================================

set -euo pipefail # 启用严格的错误处理

#=============================================
# 1. 全局配置和变量定义 (Global Configuration)
#=============================================
SCRIPT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly SCRIPT_DIR

# 基础路径配置（可在main函数中被覆盖）
MODELS_FILE="${SCRIPT_DIR}/models.list"
OLLAMA_DATA_DIR="${SCRIPT_DIR}/ollama" # .ollama目录
OLLAMA_MODELS_DIR="${OLLAMA_DATA_DIR}/models"
BACKUP_OUTPUT_DIR="${SCRIPT_DIR}/backups"

# 预计算的绝对路径（性能优化）
ABS_OLLAMA_DATA_DIR=""

# Docker镜像配置
readonly DOCKER_IMAGE_OLLAMA="ollama/ollama:latest"
readonly DOCKER_IMAGE_ONE_API="justsong/one-api:latest"
readonly DOCKER_IMAGE_PROMPT_OPTIMIZER="linshen/prompt-optimizer:latest"
readonly DOCKER_IMAGE_CHATGPT_NEXT_WEB="yidadaa/chatgpt-next-web:latest"

# 运行时配置
VERBOSE="false" # 详细模式开关

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 全局缓存变量
declare -A BACKUP_CONTENT_CACHE

# Ollama模型列表缓存
declare -g OLLAMA_MODELS_CACHE=""
declare -g OLLAMA_CACHE_INITIALIZED="false"

# 临时Ollama容器管理
declare -g TEMP_OLLAMA_CONTAINER=""
declare -g EXISTING_OLLAMA_CONTAINER=""

# 全局清理函数管理
declare -g GLOBAL_CLEANUP_FUNCTIONS=()
declare -g GLOBAL_CLEANUP_INITIALIZED="false"

#=============================================
# 2. 基础工具函数模块 (Basic Utilities)
#=============================================

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

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

#=============================================
# 3. 日志系统模块 (Logging System)
#=============================================

log_info() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warning() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
	printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Verbose-only logging functions

log_verbose() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	if [[ ${VERBOSE} == "true" ]]; then
		printf "${BLUE}[INFO]${NC} %s\n" "$1"
	fi
	return 0
}

log_verbose_success() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	[[ ${VERBOSE} == "true" ]] && printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
	return 0
}

log_verbose_warning() {
	[[ ${_LOG_SUPPRESSED} == "true" ]] && return 0
	[[ ${VERBOSE} == "true" ]] && printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
	return 0
}

# 日志屏蔽机制
_LOG_SUPPRESSED="false"

suppress_logging() {
	_LOG_SUPPRESSED="true"
}

restore_logging() {
	_LOG_SUPPRESSED="false"
}

#=============================================
# 4. 文件系统操作模块 (File System Operations)
#=============================================

# 文件大小工具函数
format_bytes() {
	local bytes="$1"

	# 使用单次awk调用减少开销，预定义常量提高可读性
	awk -v b="${bytes}" '
    BEGIN {
        if (b >= 1073741824) printf "%.1fGB", b / 1073741824
        else if (b >= 1048576) printf "%.1fMB", b / 1048576
        else printf "%.1fKB", b / 1024
    }'
}

# 计算目录大小（避免du依赖）
calculate_directory_size() {
	local directory="$1"

	if [[ ! -d ${directory} ]]; then
		echo "0"
		return 1
	fi

	local total_size_bytes=0
	while IFS= read -r -d '' file; do
		if [[ -f ${file} ]]; then
			local file_size
			# 使用POSIX兼容的方式获取文件大小
			if command_exists stat; then
				file_size=$(stat -f%z "${file}" 2>/dev/null || stat -c%s "${file}" 2>/dev/null || echo "0")
			else
				file_size=$(wc -c <"${file}" 2>/dev/null || echo "0")
			fi
			total_size_bytes=$((total_size_bytes + file_size))
		fi
	done < <(find "${directory}" -type f -print0 2>/dev/null || true)

	echo "${total_size_bytes}"
}

# 计算目录的MD5校验值
calculate_directory_md5() {
	local dir_path="$1"
	local md5_file="$2"

	if [[ ! -d ${dir_path} ]]; then
		log_error "Directory does not exist: ${dir_path}"
		return 1
	fi

	log_verbose "Calculating directory MD5 checksum: ${dir_path}"

	# 使用find和md5sum计算所有文件的MD5值，使用相对路径
	# 按文件路径排序以确保结果一致性
	if (cd "${dir_path}" && find . -type f -print0 | sort -z | xargs -0 md5sum) >"${md5_file}" 2>/dev/null; then
		log_verbose "MD5 checksum file generated: ${md5_file}"
		return 0
	else
		log_error "Failed to calculate MD5 checksum"
		return 1
	fi
}

# 验证目录的MD5校验值
verify_directory_md5() {
	local dir_path="$1"
	local md5_file="$2"

	# 参数验证
	[[ -d ${dir_path} ]] || {
		log_error "Directory does not exist: ${dir_path}"
		return 1
	}
	[[ -f ${md5_file} ]] || {
		log_error "MD5 checksum file does not exist: ${md5_file}"
		return 1
	}

	log_verbose "Verifying directory MD5 checksum: ${dir_path}"

	# 创建临时文件并设置自动清理
	local temp_md5
	temp_md5=$(mktemp) || {
		log_error "Unable to create temporary file"
		return 1
	}

	# 定义清理函数避免变量作用域问题
	cleanup_temp_md5() {
		if [[ -n ${temp_md5-} ]]; then
			rm -f "${temp_md5}"
		fi
	}
	trap 'cleanup_temp_md5' RETURN

	# 计算并比较MD5
	calculate_directory_md5 "${dir_path}" "${temp_md5}" || return 1

	if diff "${md5_file}" "${temp_md5}" >/dev/null 2>&1; then
		log_verbose "MD5 checksum verified"
		return 0
	else
		log_error "MD5 checksum verification failed"
		return 1
	fi
}

#=============================================
# 5. 路径管理模块 (Path Management)
#=============================================

get_model_backup_path() {
	local model_name="$1"
	local model_tag="$2"
	local model_spec="${model_name}:${model_tag}"

	# 生成安全的模型名称
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")

	# 返回完整的备份模型目录路径
	local backup_base_dir="${BACKUP_OUTPUT_DIR}/${model_safe_name}"
	local backup_model_dir="${backup_base_dir}/${model_safe_name}"

	echo "${backup_model_dir}"
}

get_model_manifest_path() {
	local model_name="$1"
	local model_version="$2"

	if [[ ${model_name} == hf.co/* ]]; then
		# HuggingFace GGUF模型，如 hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF
		echo "${OLLAMA_MODELS_DIR}/manifests/${model_name}/${model_version}"
	elif [[ ${model_name} == *"/"* ]]; then
		# 用户分享的模型，如 lrs33/bce-embedding-base_v1
		local user_name="${model_name%/*}"
		local repo_name="${model_name#*/}"
		echo "${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/${user_name}/${repo_name}/${model_version}"
	else
		# 官方模型
		echo "${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${model_name}/${model_version}"
	fi
}

#=============================================
# 6. Docker与Ollama管理模块 (Docker & Ollama)
#=============================================

wait_for_ollama_ready() {
	local container_name="$1"
	local max_attempts=120 # 增加到120秒
	local attempt=0

	log_verbose "Waiting for Ollama service to start..."

	while ((attempt < max_attempts)); do

		# 如果容器意外关闭
		if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then
			log_error "Container ${container_name} has stopped running"
			log_error "Container logs:"
			docker logs "${container_name}" 2>&1 | tail -10
			return 1
		fi

		# 检查ollama服务是否就绪
		if docker exec "${container_name}" ollama list &>/dev/null; then
			log_verbose_success "Ollama service is ready"
			return 0
		fi

		# 每10秒显示一次进度
		if ((attempt % 10 == 0 && attempt > 0)); then
			log_verbose "Waiting... (${attempt}/${max_attempts} seconds)"
		fi

		sleep 1
		((attempt++))
	done

	# 超时
	log_error "Timeout waiting for Ollama service to be ready (${max_attempts} seconds)"
	log_error "Container logs:"
	docker logs "${container_name}" 2>&1 | tail -10
	return 1
}

ensure_ollama_image() {
	if ! docker image inspect "${DOCKER_IMAGE_OLLAMA}" &>/dev/null; then
		log_verbose "Pulling ${DOCKER_IMAGE_OLLAMA} image..."
		if ! docker pull "${DOCKER_IMAGE_OLLAMA}"; then
			log_error "${DOCKER_IMAGE_OLLAMA} image pull failed"
			return 1
		fi
		log_verbose_success "${DOCKER_IMAGE_OLLAMA} image pull completed"
	fi
	return 0
}

# 查找运行中的Ollama容器
find_running_ollama_container() {
	# 检查是否有运行中的 Ollama 容器
	local running_containers
	running_containers=$(docker ps --format "{{.Names}}" --filter "ancestor=ollama/ollama")

	if [[ -n ${running_containers} ]]; then
		# 找到第一个运行中的容器
		EXISTING_OLLAMA_CONTAINER=$(echo "${running_containers}" | head -n1)
		log_verbose "Found running Ollama container: ${EXISTING_OLLAMA_CONTAINER}"
		return 0
	fi

	EXISTING_OLLAMA_CONTAINER=""
	return 1
}

# 启动临时Ollama容器
start_temp_ollama_container() {
	if [[ -n ${TEMP_OLLAMA_CONTAINER} ]]; then
		# 检查临时容器是否还在运行
		if docker ps -q --filter "name=^${TEMP_OLLAMA_CONTAINER}$" | grep -q .; then
			log_verbose "Temporary Ollama container still running: ${TEMP_OLLAMA_CONTAINER}"
			return 0
		else
			log_verbose "Temporary Ollama container stopped, restarting"
			TEMP_OLLAMA_CONTAINER=""
		fi
	fi

	# 确保 Ollama 镜像存在
	ensure_ollama_image || return 1

	TEMP_OLLAMA_CONTAINER="ollama-temp-$$"

	log_verbose "Starting temporary Ollama container: ${TEMP_OLLAMA_CONTAINER}"

	# 构建容器启动命令
	local cmd=("docker" "run" "-d" "--name" "${TEMP_OLLAMA_CONTAINER}")
	cmd+=("--gpus" "all")
	cmd+=("-v" "${ABS_OLLAMA_DATA_DIR}:/root/.ollama")
	cmd+=("${DOCKER_IMAGE_OLLAMA}")

	# 启动容器
	local start_output
	if start_output=$("${cmd[@]}" 2>&1); then
		log_verbose "Temporary container started successfully, ID: ${start_output:0:12}"

		# 等待服务就绪
		if wait_for_ollama_ready "${TEMP_OLLAMA_CONTAINER}"; then
			log_verbose_success "Temporary Ollama container ready: ${TEMP_OLLAMA_CONTAINER}"
			# 设置清理函数
			add_cleanup_function "cleanup_temp_ollama_container"
			return 0
		else
			log_error "Temporary Ollama container startup failed"
			docker rm -f "${TEMP_OLLAMA_CONTAINER}" &>/dev/null
			TEMP_OLLAMA_CONTAINER=""
			return 1
		fi
	else
		log_error "Unable to start temporary Ollama container"
		log_error "Docker startup error: ${start_output}"
		TEMP_OLLAMA_CONTAINER=""
		return 1
	fi
}

execute_ollama_command() {
	local action="$1"
	local with_output="${2:-false}" # 新参数：是否只返回输出
	shift 2
	local args=("$@")

	# 仅在非输出模式下显示详细日志
	[[ ${with_output} != "true" ]] && log_verbose "Executing Ollama command: ${action} ${args[*]}"

	# 确定使用的容器
	local container=""
	if find_running_ollama_container; then
		container="${EXISTING_OLLAMA_CONTAINER}"
		[[ ${with_output} != "true" ]] && log_verbose "Using existing Ollama container: ${container}"
	else
		# 启动临时容器
		[[ ${with_output} != "true" ]] && log_verbose "No running Ollama container found, starting temporary container"
		if start_temp_ollama_container; then
			container="${TEMP_OLLAMA_CONTAINER}"
		else
			[[ ${with_output} != "true" ]] && log_error "Unable to start temporary Ollama container"
			return 1
		fi
	fi

	# 执行命令
	if [[ ${with_output} == "true" ]]; then
		# 只返回输出，不显示错误
		docker exec "${container}" ollama "${action}" "${args[@]}" 2>/dev/null
	else
		# 完整执行带错误处理
		[[ ${with_output} != "true" ]] && log_verbose "Executing: docker exec ${container} ollama ${action} ${args[*]}"
		if docker exec "${container}" ollama "${action}" "${args[@]}"; then
			return 0
		else
			log_error "Failed to execute Ollama command: ${action} ${args[*]}"
			return 1
		fi
	fi
}

#=============================================
# 7. 模型元数据与解析模块 (Model Metadata)
#=============================================

# 模型名称安全化处理
# 统一的模型名称转换函数
# 参数1: 模型名称
# 参数2: 转换类型 (backup|ollama|filesystem)
get_safe_model_name() {
	local model_spec="$1"
	local conversion_type="${2:-backup}"

	case "${conversion_type}" in
	"backup")
		# 用于备份目录命名：/ 和 : → _
		echo "${model_spec}" | sed 's/[\/:]/_/g'
		;;
	"ollama")
		# 用于Ollama模型命名：复杂转换规则（一次性处理）
		local full_name_clean
		full_name_clean=$(echo "${model_spec}" | tr '[:upper:]' '[:lower:]' | sed -e 's/\//_/g' -e 's/[^a-z0-9_-]/_/g' -e 's/__*/_/g' -e 's/--*/-/g' -e 's/^[-_]\+\|[-_]\+$//g')
		# 长度限制
		if [[ ${#full_name_clean} -gt 50 ]]; then
			local prefix="${full_name_clean:0:30}"
			local suffix="${full_name_clean: -15}"
			full_name_clean="${prefix}_${suffix}"
		fi
		echo "${full_name_clean}"
		;;
	"filesystem")
		# 用于文件系统安全命名：/ → _，其他非法字符 → -
		echo "${model_spec}" | sed -e 's/\//_/g' -e 's/[^a-zA-Z0-9._-]/-/g'
		;;
	*)
		# 默认使用backup规则
		echo "${model_spec}" | sed 's/[\/:]/_/g'
		;;
	esac
}

# 验证模型格式是否正确
validate_model_format() {
	local model_spec="$1"
	if [[ ${model_spec} != *":"* ]]; then
		log_error "Invalid model format, should be 'model_name:version', e.g. 'llama2:7b'"
		return 1
	fi
	return 0
}

# 解析模型名字和版本
# shellcheck disable=SC2034  # nameref variables are used by reference
parse_model_spec() {
	local model_spec="$1"
	local -n name_var="$2"
	local -n version_var="$3"

	if ! validate_model_format "${model_spec}"; then
		return 1
	fi

	name_var="${model_spec%:*}"
	version_var="${model_spec#*:}"
	return 0
}

# 解析模型条目信息
parse_model_entry() {
	local model_entry="$1"
	local -n result_ref="$2"

	# 初始化结果关联数组
	result_ref[type]=""
	result_ref[name]=""
	result_ref[tag]=""
	result_ref[display]=""

	if [[ ${model_entry} =~ ^ollama:([^:]+):(.+)$ ]]; then
		result_ref[type]="ollama"
		result_ref[name]="${BASH_REMATCH[1]}"
		result_ref[tag]="${BASH_REMATCH[2]}"
		result_ref[display]="${result_ref[name]}:${result_ref[tag]} (Ollama)"

	elif [[ ${model_entry} =~ ^hf-gguf:(.+)$ ]]; then
		result_ref[type]="hf-gguf"
		local model_full_name="${BASH_REMATCH[1]}"
		if [[ ${model_full_name} =~ ^(.+):(.+)$ ]]; then
			result_ref[name]="${BASH_REMATCH[1]}"
			result_ref[tag]="${BASH_REMATCH[2]}"
		else
			result_ref[name]="${model_full_name}"
			result_ref[tag]="latest"
		fi
		result_ref[display]="${result_ref[name]}:${result_ref[tag]} (HF-GGUF)"
	else
		return 1
	fi

	return 0
}

# 从文件中获取模型列表
parse_models_list() {
	local models_file="$1"
	local -n models_array_ref=$2

	if [[ ! -f ${models_file} ]]; then
		log_error "Model list file does not exist: ${models_file}"
		return 1
	fi

	log_verbose "Parsing model list file: ${models_file}"

	while IFS= read -r line || [[ -n ${line} ]]; do
		# 跳过空行和注释行
		[[ -z ${line} || ${line} =~ ^[[:space:]]*# ]] && continue

		# 使用空格分隔解析模型信息: 模型类型 模型名称 [量化类型]
		read -r model_type model_name quantization <<<"${line}"

		if [[ -n ${model_type} && -n ${model_name} ]]; then
			# 构建模型条目字符串
			local model_entry
			if [[ -n ${quantization} ]]; then
				model_entry="${model_type}:${model_name}:${quantization}"
			else
				model_entry="${model_type}:${model_name}"
			fi

			# 使用parse_model_entry验证条目格式
			local -A model_info
			if parse_model_entry "${model_entry}" model_info; then
				models_array_ref+=("${model_entry}")
				log_verbose "Added model: ${model_info[display]}"
			else
				log_warning "Invalid model entry: ${model_entry} (line: ${line})"
			fi
		else
			log_warning "Ignoring invalid line: ${line}"
		fi
	done <"${models_file}"

	# 检查是否找到有效模型
	if [[ ${#models_array_ref[@]} -eq 0 ]]; then
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
		log_warning "  hf-gguf hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF"
		log_warning "====================================================================="
		echo
	else
		log_verbose "Total models parsed: ${#models_array_ref[@]}"
	fi
}

# 从单个manifest文件中提取blob digests
extract_blob_digests_from_manifest() {
	local manifest_file="$1"
	local -n digests_ref="$2"

	if [[ ! -f ${manifest_file} ]]; then
		return 1
	fi

	# 使用grep和sed解析JSON中的blob digests
	local blob_digests
	blob_digests=$(grep -o '"digest":"sha256:[a-f0-9]\{64\}"' "${manifest_file}" 2>/dev/null | sed 's/"digest":"sha256:\([a-f0-9]\{64\}\)"/\1/g')

	# 将结果添加到数组
	while IFS= read -r digest; do
		[[ -n ${digest} ]] && digests_ref+=("${digest}")
	done <<<"${blob_digests}"
}

get_model_blob_paths() {
	local manifest_file="$1"
	local models_dir="$2"
	local blob_paths=()

	if [[ ! -f ${manifest_file} ]]; then
		log_error "Model manifest file does not exist: ${manifest_file}"
		return 1
	fi

	# 使用统一的blob digest提取函数
	local digests=()
	if ! extract_blob_digests_from_manifest "${manifest_file}" digests; then
		log_error "Failed to extract blob digests from manifest: ${manifest_file}"
		return 1
	fi

	# 构建blob文件路径
	for digest in "${digests[@]}"; do
		# digest已经不包含sha256:前缀，构建sha256-xxx格式的文件名
		local blob_name="sha256-${digest}"
		local blob_file="${models_dir}/blobs/${blob_name}"
		blob_paths+=("${blob_file}")
	done

	# 输出路径
	printf '%s\n' "${blob_paths[@]}"
}

#=============================================
# 8. 缓存与清理管理模块 (Cache & Cleanup)
#=============================================

add_cleanup_function() {
	local func_name="$1"
	if [[ -z ${func_name} ]]; then
		log_error "Cleanup function name cannot be empty"
		return 1
	fi

	# 检查函数是否已存在，避免重复添加
	local func
	for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
		if [[ ${func} == "${func_name}" ]]; then
			return 0 # 已存在，直接返回
		fi
	done

	GLOBAL_CLEANUP_FUNCTIONS+=("${func_name}")

	# 如果是第一次添加，设置全局 trap
	if [[ ${GLOBAL_CLEANUP_INITIALIZED} == "false" ]]; then
		trap 'execute_global_cleanup' EXIT INT TERM
		GLOBAL_CLEANUP_INITIALIZED="true"
		log_verbose "Initializing global cleanup mechanism"
	fi
}

# 执行所有清理函数
execute_global_cleanup() {
	local exit_code=$?
	local func

	# 如果是中断信号，显示中断消息
	if [[ ${exit_code} -eq 130 ]]; then # Ctrl+C
		log_warning "Detected interrupt signal (Ctrl+C)"
	elif [[ ${exit_code} -eq 143 ]]; then # SIGTERM
		log_warning "Detected termination signal (SIGTERM)"
	fi

	for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
		if declare -f "${func}" >/dev/null 2>&1; then
			log_verbose "Executing cleanup function: ${func}"
			"${func}"
		fi
	done

	# 如果是中断，退出
	if [[ ${exit_code} -eq 130 || ${exit_code} -eq 143 ]]; then
		exit "${exit_code}"
	fi
}

# 初始化Ollama模型列表缓存
init_ollama_cache() {
	if [[ ${OLLAMA_CACHE_INITIALIZED} == "true" ]]; then
		return 0
	fi

	log_verbose "Initializing Ollama model list cache..."

	# 使用统一的容器逻辑获取模型列表
	log_verbose "Getting Ollama model list..."

	# 获取模型列表并缓存
	OLLAMA_MODELS_CACHE=$(execute_ollama_command "list" "true" | awk 'NR>1 {print $1}' | sort)
	if [[ -n ${OLLAMA_MODELS_CACHE} ]]; then
		OLLAMA_CACHE_INITIALIZED="true"
		log_verbose_success "Ollama model list cache initialization completed"
	else
		log_verbose "Ollama model list is empty"
		OLLAMA_MODELS_CACHE=""
		OLLAMA_CACHE_INITIALIZED="true"
	fi

	return 0
}

cleanup_temp_ollama_container() {
	if [[ -n ${TEMP_OLLAMA_CONTAINER} ]]; then
		log_verbose "Cleaning up temporary Ollama container: ${TEMP_OLLAMA_CONTAINER}"
		docker rm -f "${TEMP_OLLAMA_CONTAINER}" &>/dev/null
		TEMP_OLLAMA_CONTAINER=""
	fi
}

# 确保完整性检查缓存已初始化
ensure_cache_initialized() {
	# Initialize cache arrays if they do not exist
	if [[ ! -v BACKUP_CONTENT_CACHE ]]; then
		declare -g -A BACKUP_CONTENT_CACHE
		[[ -n ${VERBOSE} ]] && log_verbose "Integrity check cache initialized"
	fi
}

#=============================================
# 9. 模型验证模块 (Model Validation)
#=============================================

check_ollama_model_exists() {
	local model_name="$1"

	# 确保缓存已初始化
	if ! init_ollama_cache; then
		log_error "Failed to initialize Ollama model cache"
		return 1
	fi

	# 在缓存中查找模型
	if echo "${OLLAMA_MODELS_CACHE}" | grep -q "^${model_name}$"; then
		return 0
	else
		return 1
	fi
}

check_ollama_model() {
	local model_name="$1"
	local model_tag="$2"
	local full_model_name="${model_name}:${model_tag}"

	# 首先尝试通过Ollama容器检查（最准确）
	if check_ollama_model_exists "${full_model_name}"; then
		log_verbose_success "Ollama model already exists: ${full_model_name}"
		return 0
	fi

	# 如果Ollama容器检查失败，进行完整性检查（使用缓存优化）
	local model_spec="${model_name}:${model_tag}"
	if verify_integrity "model" "${model_spec}" "use_cache:true,check_blobs:true"; then
		log_verbose_success "Ollama model exists (filesystem verification): ${full_model_name}"
		return 0
	else
		log_verbose_warning "Ollama model does not exist or is incomplete: ${full_model_name}"
		return 1
	fi
}

check_model_exists() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama" | "hf-gguf")
		check_ollama_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		log_verbose_warning "Unsupported model type: ${model_info_ref[type]}"
		return 1
		;;
	esac
}

verify_integrity() {
	local verification_type="$1" # model, backup, hf_model
	local target="$2"            # 目标文件/路径/模型规格
	local options="${3-}"        # 附加选项 (use_cache:true, check_blobs:true, etc.)

	# 解析选项
	local use_cache="true"
	local check_blobs="true"
	local model_spec=""

	# 解析选项字符串
	if [[ -n ${options} ]]; then
		while IFS=',' read -ra ADDR; do
			for i in "${ADDR[@]}"; do
				case "${i}" in
				use_cache:*)
					use_cache="${i#*:}"
					;;
				check_blobs:*)
					check_blobs="${i#*:}"
					;;
				model_spec:*)
					model_spec="${i#*:}"
					;;
				*)
					# 忽略未知选项
					;;
				esac
			done
		done <<<"${options}"
	fi

	# 确保缓存已初始化
	[[ ${use_cache} == "true" ]] && ensure_cache_initialized

	# 根据验证类型调用相应的验证逻辑
	case "${verification_type}" in
	"model")
		_verify_local_model "${target}" "${check_blobs}"
		;;
	"backup" | "backup_file")
		_verify_backup_target "${target}"
		;;
	*)
		log_error "Unknown verification type: ${verification_type}"
		return 1
		;;
	esac
}

_verify_local_model() {
	local model_spec="$1"
	local check_blobs="$2"

	# 解析模型规格
	local model_name model_tag
	if [[ ${model_spec} =~ ^(.+):(.+)$ ]]; then
		model_name="${BASH_REMATCH[1]}"
		model_tag="${BASH_REMATCH[2]}"
	else
		log_error "Invalid model spec format: ${model_spec}"
		return 1
	fi

	# 确定manifest文件路径
	local manifest_file
	manifest_file=$(get_model_manifest_path "${model_name}" "${model_tag}")

	# 检查manifest文件是否存在
	[[ ! -f ${manifest_file} ]] && return 1

	# 如果不需要检查blob，只验证manifest存在即可
	[[ ${check_blobs} == "false" ]] && return 0

	# 获取blob文件列表并验证
	local blob_files
	blob_files=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}")
	[[ -z ${blob_files} ]] && return 1

	# 检查每个blob文件
	while IFS= read -r blob_file; do
		[[ -n ${blob_file} && ! -f ${blob_file} ]] && return 1
	done <<<"${blob_files}"

	return 0
}

_verify_backup_target() {
	local backup_target="$1"

	# 检查目录备份
	if [[ ! -d ${backup_target} ]]; then
		return 1
	fi

	# Verify directory structure
	if [[ ! -d "${backup_target}/manifests" ]] || [[ ! -d "${backup_target}/blobs" ]]; then
		log_error "Invalid directory backup structure: ${backup_target}"
		return 1
	fi

	# 检查是否有manifest文件
	if ! find "${backup_target}/manifests" -type f -name "*" | head -1 | read -r; then
		return 1
	fi

	# Verify MD5 checksum
	local md5_file="${backup_target}.md5"
	if [[ -f ${md5_file} ]]; then
		if verify_directory_md5 "${backup_target}" "${md5_file}"; then
			[[ -n ${VERBOSE} ]] && log_info "Directory backup MD5 checksum verified: ${backup_target}"
			return 0
		else
			log_error "Directory backup MD5 checksum failed: ${backup_target}"
			return 1
		fi
	else
		log_warning "MD5 checksum file not found: ${md5_file}"
		return 0 # No MD5 file is still considered valid, but a warning is logged
	fi
}

_parse_model_path() {
	local relative_path="$1"
	local -n name_ref="$2"
	local -n version_ref="$3"
	local -n path_ref="$4"

	if [[ ${relative_path} =~ ^registry\.ollama\.ai/library/([^/]+)/(.+)$ ]]; then
		# 传统 Ollama 模型: registry.ollama.ai/library/model_name/version
		name_ref="${BASH_REMATCH[1]}"
		version_ref="${BASH_REMATCH[2]}"
		path_ref="registry.ollama.ai/library/${name_ref}"
	elif [[ ${relative_path} =~ ^hf\.co/([^/]+)/([^/]+)/(.+)$ ]]; then
		# HF-GGUF 模型: hf.co/user/repo/version
		local user="${BASH_REMATCH[1]}"
		local repo="${BASH_REMATCH[2]}"
		version_ref="${BASH_REMATCH[3]}"
		name_ref="hf.co/${user}/${repo}"
		path_ref="hf.co/${user}/${repo}"
	else
		# 其他未知格式，尝试通用解析
		local path_parts
		IFS='/' read -ra path_parts <<<"${relative_path}"
		if [[ ${#path_parts[@]} -ge 2 ]]; then
			# shellcheck disable=SC2034  # Variables used via nameref
			version_ref="${path_parts[-1]}"
			unset 'path_parts[-1]'
			# shellcheck disable=SC2034  # Variables used via nameref
			name_ref=$(
				IFS='/'
				echo "${path_parts[*]}"
			)
			# shellcheck disable=SC2034  # Variables used via nameref
			path_ref="${name_ref}"
		else
			return 1
		fi
	fi
	return 0
}

list_installed_models() {
	# 屏蔽日志输出以获得清洁的显示
	suppress_logging
	echo "Scanning installed models..."

	# 初始化缓存以提高完整性检查性能
	ensure_cache_initialized

	# 检查Ollama模型目录是否存在
	if [[ ! -d ${OLLAMA_MODELS_DIR} ]]; then
		echo "ERROR: Ollama models directory does not exist: ${OLLAMA_MODELS_DIR}"
		restore_logging
		return 1
	fi

	local manifests_base_dir="${OLLAMA_MODELS_DIR}/manifests"

	# 检查manifests基础目录是否存在
	if [[ ! -d ${manifests_base_dir} ]]; then
		echo "WARNING: No installed models found"
		restore_logging
		return 0
	fi

	echo ""
	echo "============================================================"
	echo "                Installed Ollama Models"
	echo "============================================================"
	echo ""

	local model_count=0
	local total_size=0
	local total_version_count=0

	# 递归查找所有 manifest 文件
	local manifest_files=()
	while IFS= read -r -d '' manifest_file; do
		manifest_files+=("${manifest_file}")
	done < <(find "${manifests_base_dir}" -type f -print0 2>/dev/null || true)

	# 按模型组织 manifest 文件
	declare -A model_manifests

	for manifest_file in "${manifest_files[@]}"; do
		# 提取相对于 manifests_base_dir 的路径
		local relative_path="${manifest_file#"${manifests_base_dir}"/}"

		# 解析模型路径获取名称和版本
		local model_name version full_model_path
		if ! _parse_model_path "${relative_path}" model_name version full_model_path; then
			continue
		fi

		# 将 manifest 添加到对应模型组
		if [[ -n ${model_name} && -n ${version} ]]; then
			local key="${model_name}"
			if [[ -z ${model_manifests[${key}]-} ]]; then
				model_manifests[${key}]="${manifest_file}|${version}|${full_model_path}"
			else
				model_manifests[${key}]="${model_manifests[${key}]};;${manifest_file}|${version}|${full_model_path}"
			fi
		fi
	done

	# 显示每个模型的信息
	for model_name in "${!model_manifests[@]}"; do
		local model_data="${model_manifests[${model_name}]}"

		# 解析第一个条目以获取路径信息
		local first_entry="${model_data%%;*}"
		local full_model_path="${first_entry##*|}"
		local model_dir="${manifests_base_dir}/${full_model_path}"

		echo "📦 Model: ${model_name}"
		[[ ${VERBOSE} == "true" ]] && echo "   ├─ Location: ${model_dir}"

		local version_count=0

		# 处理所有版本
		IFS=';;' read -ra entries <<<"${model_data}"
		for entry in "${entries[@]}"; do
			IFS='|' read -r manifest_file version _ <<<"${entry}"

			if [[ ! -f ${manifest_file} ]]; then
				continue
			fi

			# 检查模型完整性
			local integrity_status=""
			if check_ollama_model "${model_name}" "${version}"; then
				integrity_status=" ✓(complete)"
			else
				integrity_status=" ⚠️(incomplete)"
			fi

			echo "   ├─ Version: ${version}${integrity_status}"

			# 计算模型文件大小
			if [[ ${VERBOSE} == "true" ]] && [[ -f ${manifest_file} ]]; then
				local blob_paths
				if blob_paths=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}"); then
					local total_model_size=0
					local blob_count=0

					# 计算所有blob文件的实际大小
					while IFS= read -r blob_file; do
						if [[ -f ${blob_file} ]]; then
							local file_size
							# 使用更兼容的方式获取文件大小
							if command_exists stat; then
								file_size=$(stat -f%z "${blob_file}" 2>/dev/null || stat -c%s "${blob_file}" 2>/dev/null || echo "0")
							else
								file_size=$(wc -c <"${blob_file}" 2>/dev/null || echo "0")
							fi
							total_model_size=$((total_model_size + file_size))
							blob_count=$((blob_count + 1))
						fi
					done <<<"${blob_paths}"

					# 格式化大小显示
					local human_size
					human_size=$(format_bytes "${total_model_size}")

					echo "   ├─ Size: ${human_size}"

					total_size=$((total_size + total_model_size))
				fi
			fi

			version_count=$((version_count + 1))
		done

		echo "   └─ Version count: ${version_count}"
		echo ""
		model_count=$((model_count + 1))
		total_version_count=$((total_version_count + version_count))
	done

	# 显示统计信息
	echo "============================================================"
	echo "Statistics:"
	echo "  📊 Total models: ${model_count}"
	echo "  🔢 Total versions: ${total_version_count}"

	# 格式化总大小
	if [[ ${VERBOSE} == "true" ]]; then
		local total_human_size
		total_human_size=$(format_bytes "${total_size}")
		echo "  💾 Size: ${total_human_size}"
	fi
	echo "  📁 Directory: ${OLLAMA_MODELS_DIR}"

	echo "============================================================"
	echo ""

	# 恢复日志输出
	restore_logging
	return 0
}

#=============================================
# 10. 模型下载模块 (Model Download)
#=============================================

download_model() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama" | "hf-gguf")
		download_ollama_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		log_error "Unsupported model type: ${model_info_ref[type]}"
		return 1
		;;
	esac
}

# 下载Ollama模型
download_ollama_model() {
	local model_name="$1"
	local model_tag="$2"

	local full_model_name="${model_name}:${model_tag}"

	log_info "Downloading: ${full_model_name}"

	if execute_ollama_command "pull" "false" "${full_model_name}"; then
		log_verbose_success "Downloaded: ${full_model_name}"

		# 验证下载后的模型完整性
		if verify_integrity "model" "${model_name}:${model_tag}" "use_cache:true,check_blobs:true"; then
			log_verbose_success "Verified: ${full_model_name}"
			return 0
		else
			log_error "Verification failed: ${full_model_name}"
			return 1
		fi
	else
		log_error "Download failed: ${full_model_name}"
		return 1
	fi
}

process_model() {
	local model_entry="$1"
	local force_download="$2"
	local check_only="$3"

	# 解析模型条目
	local -A model_info
	if ! parse_model_entry "${model_entry}" model_info; then
		log_error "Invalid model entry format: ${model_entry}"
		return 1
	fi

	log_info "Processing model: ${model_info[display]}"

	# 检查模型是否存在
	if [[ ${force_download} != "true" ]] && check_model_exists model_info; then
		log_success "Model already exists"
		return 0
	fi

	# 模型不存在或强制下载
	if [[ ${check_only} == "true" ]]; then
		log_warning "Download needed: ${model_info[display]}"
		return 0
	fi

	# 清理缓存的辅助函数
	_clear_ollama_cache() {
		OLLAMA_CACHE_INITIALIZED="false"
		OLLAMA_MODELS_CACHE=""
	}

	# 尝试从备份恢复
	if try_restore_model model_info; then
		log_success "Successfully restored from backup"
		_clear_ollama_cache
		return 0
	fi

	# 执行下载
	if download_model model_info; then
		log_success "Model download completed"
		_clear_ollama_cache
		return 0
	else
		log_error "Model processing failed: ${model_info[display]}"
		return 1
	fi
}

#=============================================
# 11. 模型备份模块 (Model Backup)
#=============================================

backup_ollama_model() {
	local model_name="$1"
	local model_version="$2"

	# 初始化缓存以提高完整性检查性能
	ensure_cache_initialized

	log_verbose "Backing up model: ${model_name}:${model_version}"

	# 构造model_spec用于完整性验证
	local model_spec="${model_name}:${model_version}"

	# 验证本地模型完整性
	if ! verify_integrity "model" "${model_spec}" "use_cache:true,check_blobs:true"; then
		log_error "Local model is incomplete, canceling backup operation"
		return 1
	fi

	# 获取备份目录路径
	local backup_model_dir
	backup_model_dir=$(get_model_backup_path "${model_name}" "${model_version}")

	# 检查是否已存在备份目录
	if [[ -d ${backup_model_dir} ]]; then
		log_success "Model backup already exists"
		return 0
	fi

	# 创建备份目录
	if ! mkdir -p "${backup_model_dir}"; then
		log_error "Unable to create backup directory: ${backup_model_dir}"
		return 1
	fi

	# 确定manifest文件路径
	local manifest_file
	manifest_file=$(get_model_manifest_path "${model_name}" "${model_version}")

	# 检查manifest文件是否存在
	if [[ ! -f ${manifest_file} ]]; then
		log_error "Model does not exist: ${model_spec}"
		rm -rf "${model_backup_dir}"
		return 1
	fi

	# 获取blob文件路径
	local blob_files
	blob_files=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}")

	if [[ -z ${blob_files} ]]; then
		log_error "No model-related blob files found"
		rm -rf "${model_backup_dir}"
		return 1
	fi

	# 创建备份目录结构
	mkdir -p "${backup_model_dir}/manifests" "${backup_model_dir}/blobs"

	log_verbose "Starting file copy..."

	# 复制manifest文件
	local manifest_rel_path="${manifest_file#"${OLLAMA_MODELS_DIR}"/manifests/}"
	local manifest_backup_dir
	manifest_backup_dir="${backup_model_dir}/manifests/$(dirname "${manifest_rel_path}")"
	mkdir -p "${manifest_backup_dir}"
	if ! cp "${manifest_file}" "${manifest_backup_dir}/"; then
		log_error "Failed to copy manifest file: ${manifest_file}"
		rm -rf "${model_backup_dir}"
		return 1
	fi

	# 复制blob文件
	while IFS= read -r blob_file; do
		if [[ -f ${blob_file} ]]; then
			if ! cp "${blob_file}" "${backup_model_dir}/blobs/"; then
				log_error "Failed to copy blob file: ${blob_file}"
				rm -rf "${model_backup_dir}"
				return 1
			fi
		fi
	done <<<"${blob_files}"

	# 设置备份目录权限为755
	chmod -R 755 "${backup_model_dir}" || log_warning "Failed to set directory permissions"

	# 计算MD5校验
	log_verbose "Calculating MD5 checksums..."
	local md5_file="${backup_model_dir}.md5"
	if calculate_directory_md5 "${backup_model_dir}" "${md5_file}"; then
		log_verbose "MD5 checksum file created: ${md5_file}"
		# 设置MD5文件权限为644
		chmod 644 "${md5_file}" || log_warning "Failed to set MD5 file permissions"
	else
		log_warning "Failed to create MD5 checksum file"
	fi

	# 创建备份信息文件
	create_backup_info "${model_spec}" "${backup_model_dir}" "directory" 1 "ollama"

	log_verbose_success "Model backup completed: ${model_spec}"
	return 0
}
# 备份单个模型的包装函数

backup_single_model() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama" | "hf-gguf")
		backup_ollama_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		log_error "Unsupported model type for backup: ${model_info_ref[type]}"
		return 1
		;;
	esac
}

# 自动识别备份类型并恢复
# 批量备份模型（根据models.list文件）
backup_models_from_list() {
	local models_file="$1"

	log_verbose "Batch backup models..."
	log_verbose "Models list file: ${models_file}"
	log_verbose "Backup directory: ${BACKUP_OUTPUT_DIR}"

	# 解析模型列表
	local models=()
	parse_models_list "${models_file}" models

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "No models found for backup"
		return 1
	fi

	# 创建备份目录
	mkdir -p "${BACKUP_OUTPUT_DIR}"

	local -i total_models=${#models[@]} processed=0 success=0 failed=0

	log_verbose "Found ${total_models} models for backup"

	# 预先初始化Ollama缓存以提高性能
	log_verbose "Pre-initializing Ollama cache..."
	if ! init_ollama_cache; then
		log_error "Ollama cache initialization failed, may affect backup performance"
	fi

	# 处理单个模型的内部函数
	_process_backup_entry() {
		local model="$1"
		local -A model_info

		if ! parse_model_entry "${model}" model_info; then
			log_error "Invalid model entry format: ${model}"
			return 1
		fi

		if ! check_model_exists model_info; then
			log_warning "Model does not exist: ${model_info[display]}"
			return 1
		fi

		backup_single_model model_info
	}

	for model in "${models[@]}"; do
		((processed++))
		log_info "Backing up model [${processed}/${total_models}]: ${model}"

		if _process_backup_entry "${model}"; then
			((success++))
		else
			((failed++))
		fi

		echo "" # 添加空行分隔
	done

	# 清理完整性检查缓存
	if [[ -n ${VERBOSE} ]]; then
		log_verbose "Clearing integrity check cache"
		unset BACKUP_CONTENT_CACHE
		declare -g -A BACKUP_CONTENT_CACHE
	fi

	# 显示备份目录信息
	if [[ ${VERBOSE} == "true" && -d ${BACKUP_OUTPUT_DIR} ]]; then
		local backup_count total_size_bytes total_size
		backup_count=$(find "${BACKUP_OUTPUT_DIR}" -maxdepth 1 -type d ! -path "${BACKUP_OUTPUT_DIR}" | wc -l)
		total_size_bytes=$(calculate_directory_size "${BACKUP_OUTPUT_DIR}")
		total_size=$(format_bytes "${total_size_bytes}")
		log_info "Backup directory contains: ${backup_count} models, total size: ${total_size}"
	fi

	# 显示备份总结并返回结果
	if [[ ${failed} -eq 0 ]]; then
		log_verbose_success "All models backup completed (${success}/${total_models})"
		return 0
	else
		log_warning "Backup completed with failures: ${success} succeeded, ${failed} failed"
		return 1
	fi
}
# 创建备份信息文件

create_backup_info() {
	local model_spec="$1"
	local backup_base="$2"
	local backup_type="$3"   # "directory", "single" or "split"
	local _volume_count="$4" # Reserved for future use
	local backup_extension="${5:-original}"

	local info_file="${backup_base}_info.txt"
	local current_time
	current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")

	# Use temporary file to create backup information
	local temp_info
	temp_info=$(mktemp)
	cat >"${temp_info}" <<EOF
================================================================================
                        Model Backup Information
================================================================================

Basic Backup Information:
  Model Specification: ${model_spec}
  Backup Name: ${model_safe_name}
  Backup Type: ${backup_type}
  Creation Time: ${current_time}

Backup File Information:
EOF

	# Add specific file information and MD5 based on backup type
	if [[ ${backup_type} == "directory" ]]; then
		local backup_dir="${backup_base}_${backup_extension}"
		# For ollama backups, backup_base is already the complete path
		if [[ ${backup_extension} == "ollama" ]]; then
			backup_dir="${backup_base}"
		fi

		local backup_size="Unknown"
		if [[ -d ${backup_dir} ]]; then
			local total_bytes
			total_bytes=$(calculate_directory_size "${backup_dir}")
			if [[ ${total_bytes} -gt 0 ]]; then
				backup_size=$(format_bytes "${total_bytes}")
			fi
		fi
		local md5_file="${backup_dir}.md5"
		local md5_status="Valid"
		if [[ ! -f ${md5_file} ]]; then
			md5_status="Missing"
		fi

		cat >>"${temp_info}" <<EOF
  Backup Method: Directory Copy
  Backup Directory: $(basename "${backup_dir}")
  Backup Size: ${backup_size}
  MD5 Checksum File: ${md5_status}

File List:
EOF

		# Add file list
		if [[ -d ${backup_dir} ]]; then
			find "${backup_dir}" -type f -exec basename {} \; | sort >>"${temp_info}"
		fi

		cat >>"${temp_info}" <<EOF

MD5 Checksum Information:
EOF

		# Add MD5 checksum information
		if [[ -f ${md5_file} ]]; then
			cat "${md5_file}" >>"${temp_info}"
		else
			{
				echo "  MD5 checksum file creation failed or does not exist"
				echo "  File path: ${md5_file}"
				echo "  Recommendation: Re-run backup to generate MD5 checksum file"
			} >>"${temp_info}"
		fi

		cat >>"${temp_info}" <<EOF

Restore Commands:
  # Using omo.sh restore
  ./omo.sh --restore "$(basename "${backup_dir}")"
  
  # Manual restore (Ollama models)
  cp -r "$(basename "${backup_dir}")/manifests/"* "\$OLLAMA_MODELS_DIR/manifests/"
  cp "$(basename "${backup_dir}")/blobs/"* "\$OLLAMA_MODELS_DIR/blobs/"
  

EOF
	else
		log_error "Unsupported backup type: ${backup_type}"
		rm -f "${temp_info}"
		return 1
	fi

	cat >>"${temp_info}" <<EOF
================================================================================
                            Verification Information
================================================================================

Backup Verification:
1. Check file integrity:
   - Use MD5 checksum file to verify integrity of each file
   - md5sum -c $(basename "${backup_dir}.md5")

2. Check backup structure:
   - Ensure backup directory contains complete file structure
   - For Ollama models: manifests/ and blobs/ directories

Backup Features:
   - Direct Copy: Extremely fast backup and restore speed, no compression/decompression needed
   - MD5 Checksums: Ensures file integrity and consistency
   - Simplified Management: Backup files can be directly accessed and inspected

Usage Instructions:
- This backup contains the complete file structure of the model
- Can be used directly after restoration, no additional processing required
- Supports incremental backup and difference checking

Generated Time: ${current_time}
================================================================================
EOF

	# Write to info file directly
	if mv "${temp_info}" "${info_file}"; then
		# Set backup info file permissions to 644
		chmod 644 "${info_file}" || log_warning "Failed to set backup info file permissions"
		log_verbose_success "Backup info file created: $(basename "${info_file}")"
	else
		log_error "Unable to write backup info file: ${info_file}"
		rm -f "${temp_info}"
		return 1
	fi
}

#=============================================
# 12. 模型恢复模块 (Model Restore)
#=============================================
#
# 模型恢复逻辑说明：
#
# 1. 恢复流程：
#    ├── 备份结构验证 (_validate_backup_structure)
#    │   ├── 检查备份目录存在性
#    │   ├── 验证manifests/blobs目录结构
#    │   └── 确认包含实际文件（非空备份）
#    ├── 备份完整性验证 (_verify_backup_integrity)
#    │   ├── 检查MD5校验文件存在性
#    │   ├── 计算当前备份目录的MD5值
#    │   └── 对比验证文件完整性
#    ├── 冲突检查 (_check_restore_conflicts)
#    │   ├── 检查目标文件是否已存在
#    │   └── 在非强制模式下防止意外覆盖
#    └── 文件恢复 (_perform_files_restore)
#        ├── 启动Docker容器（确保权限一致性）
#        ├── 在容器内创建目标目录
#        ├── 复制manifests文件到容器内Ollama目录
#        └── 复制blobs文件到容器内Ollama目录
#
# 2. 恢复模式区别：
#    ┌─────────────────┬──────────────────┬──────────────────┐
#    │ 恢复类型        │ 自动恢复         │ 手动恢复         │
#    ├─────────────────┼──────────────────┼──────────────────┤
#    │ 触发方式        │ --install        │ --restore        │
#    │ MD5验证失败     │ 严格停止恢复     │ 可用--force跳过  │
#    │ 文件冲突        │ 自动覆盖         │ 默认阻止，可强制 │
#    │ 失败后行为      │ 回退到下载模式   │ 直接报错退出     │
#    └─────────────────┴──────────────────┴──────────────────┘
#
# 3. 安全机制：
#    - 完整性检查：防止损坏备份的错误恢复
#    - 冲突检测：避免意外覆盖现有模型文件
#    - 权限管理：通过Docker容器处理文件权限问题
#    - 错误恢复：提供清晰的错误信息和解决建议
#    - 详细日志：记录每个步骤的执行状态
#

restore_model() {
	local restore_file="$1"
	local force_restore="${2:-false}"

	# 处理路径解析
	local restore_path="${restore_file}"
	if [[ ${restore_file} != /* ]]; then
		restore_path="${BACKUP_OUTPUT_DIR}/${restore_file}"
	fi

	# 检查路径是否存在
	if [[ ! -d ${restore_path} ]]; then
		log_error "Backup directory does not exist: ${restore_path}"
		return 1
	fi

	# 直接调用Ollama恢复实现（使用Docker进行文件操作）
	_restore_ollama_implementation "${restore_path}" "${force_restore}"
}

# 尝试从备份自动恢复模型（从模型信息恢复）

try_restore_model() {
	local -n model_info_ref=$1

	# 所有模型类型都使用相同的Ollama恢复机制
	_auto_restore_from_backup "${model_info_ref[name]}" "${model_info_ref[tag]}"
}

# 内部函数：自动恢复实现

_auto_restore_from_backup() {
	local model_name="$1"
	local model_tag="$2"
	local model_spec="${model_name}:${model_tag}"

	log_verbose "Checking for model backup: ${model_spec}"

	# 获取备份路径并验证
	local backup_model_dir
	backup_model_dir=$(get_model_backup_path "${model_name}" "${model_tag}")

	if [[ ! -d ${backup_model_dir} ]]; then
		log_verbose "No backup found: ${backup_model_dir}"
		return 1
	fi

	log_verbose_success "Found model backup: ${backup_model_dir}"
	log_verbose "Restoring model from backup..."

	# 调用Ollama恢复实现（自动恢复：允许冲突覆盖，但严格执行完整性检查）
	if _restore_ollama_implementation "${backup_model_dir}" "true" "true"; then
		log_success "Successfully restored model from backup: ${model_spec}"
		return 0
	else
		log_warning "Failed to restore model from backup"
		return 1
	fi
}

# 内部函数：Ollama模型恢复的核心实现

_restore_ollama_implementation() {
	local backup_dir="$1"
	local force_restore="${2:-false}"
	local auto_restore="${3:-false}" # 新参数：是否为自动恢复

	log_info "Restoring model: $(basename "${backup_dir}")"

	# 验证备份结构、完整性、冲突检查和文件恢复的统一流程
	log_verbose "Step 1: Validating backup structure..."
	if ! _validate_backup_structure "${backup_dir}"; then
		log_error "Backup structure validation failed"
		return 1
	fi
	log_verbose_success "Backup structure validation passed"

	log_verbose "Step 2: Verifying backup integrity..."
	# 自动恢复时不允许忽略完整性检查失败，手动恢复时允许
	local allow_skip_integrity="true"
	if [[ ${auto_restore} == "true" ]]; then
		allow_skip_integrity="false"
	fi
	if ! _verify_backup_integrity "${backup_dir}" "${force_restore}" "${allow_skip_integrity}"; then
		log_error "Backup integrity verification failed"
		return 1
	fi
	log_verbose_success "Backup integrity verification passed"

	log_verbose "Step 3: Checking restore conflicts..."
	if ! _check_restore_conflicts "${backup_dir}" "${force_restore}"; then
		log_error "Restore conflict check failed"
		return 1
	fi
	log_verbose_success "Restore conflict check passed"

	log_verbose "Step 4: Performing files restore..."
	if ! _perform_files_restore "${backup_dir}"; then
		log_error "Files restore failed"
		return 1
	fi
	log_verbose_success "Files restore completed"

	log_verbose_success "Model restore completed"
	return 0
}

# 内部函数：验证备份结构

_validate_backup_structure() {
	local backup_dir="$1"

	if [[ ! -d ${backup_dir} ]]; then
		log_error "Backup directory does not exist: ${backup_dir}"
		return 1
	fi

	# 检查必需的子目录并验证至少有一个文件
	local manifests_dir="${backup_dir}/manifests"
	local blobs_dir="${backup_dir}/blobs"

	if [[ ! -d ${manifests_dir} ]] || [[ ! -d ${blobs_dir} ]]; then
		log_error "Invalid backup structure: missing manifests or blobs directory"
		return 1
	fi

	# 优化：一次检查两个目录是否有文件
	local has_files
	has_files=$(find "${manifests_dir}" "${blobs_dir}" -type f -print -quit 2>/dev/null || true)
	if [[ -z ${has_files} ]]; then
		log_error "Backup appears to be empty: no files found in manifests or blobs"
		return 1
	fi

	return 0
}

# 内部函数：验证备份完整性

_verify_backup_integrity() {
	local backup_dir="$1"
	local force_restore="$2"
	local allow_skip_integrity="${3:-false}" # 新参数：是否允许忽略MD5失败

	local md5_file="${backup_dir}.md5"
	if [[ ! -f ${md5_file} ]]; then
		log_warning "Skipping integrity check: MD5 file not found"
		return 0
	fi

	log_info "Verifying backup integrity..."
	if verify_directory_md5 "${backup_dir}" "${md5_file}"; then
		log_verbose_success "MD5 verification passed"
		return 0
	else
		log_error "Backup integrity check failed"
		if [[ ${allow_skip_integrity} == "true" && ${force_restore} == "true" ]]; then
			log_warning "Force restore mode, ignoring integrity check failure..."
			return 0
		else
			log_error "Cannot restore corrupted backup. Use --force to override (not recommended)"
			return 1
		fi
	fi
}

# 内部函数：检查恢复冲突

_check_restore_conflicts() {
	local backup_dir="$1"
	local force_restore="$2"

	if [[ ${force_restore} == "true" ]]; then
		return 0
	fi

	log_info "Checking for file conflicts..."
	# More efficient conflict detection
	for backup_subdir in manifests blobs; do
		while IFS= read -r -d '' backup_file; do
			local rel_path="${backup_file#"${backup_dir}/${backup_subdir}/"}"
			local target_file="${OLLAMA_MODELS_DIR}/${backup_subdir}/${rel_path}"
			if [[ -f ${target_file} ]]; then
				log_error "File conflicts detected, use --force to override"
				return 1
			fi
		done < <(find "${backup_dir}/${backup_subdir}" -type f -print0 2>/dev/null || true)
	done

	return 0
}

# Docker容器复制工具函数
# 使用Docker容器进行文件复制操作，确保权限一致性和操作可靠性
_docker_copy_files() {
	local src_path="$1"
	local dest_path="$2"
	local operation_name="$3"

	log_verbose "Using Docker to copy ${operation_name} files"

	# 确定使用的容器
	local container=""
	if find_running_ollama_container; then
		container="${EXISTING_OLLAMA_CONTAINER}"
	else
		log_verbose "Starting temporary container for file copy operation"
		if start_temp_ollama_container; then
			container="${TEMP_OLLAMA_CONTAINER}"
		else
			log_error "Unable to start Ollama container for file copy"
			return 1
		fi
	fi

	# 确保目标目录在容器中存在
	if ! docker exec "${container}" mkdir -p "${dest_path}"; then
		log_error "Failed to create target directory in container: ${dest_path}"
		return 1
	fi

	# 使用docker cp进行复制
	if docker cp "${src_path}/." "${container}:${dest_path}/"; then
		log_verbose "Docker copy completed for ${operation_name}"
		return 0
	else
		log_error "Docker copy failed for ${operation_name}"
		return 1
	fi
}

# 内部函数：恢复单个目录（使用Docker）
_restore_single_directory() {
	local src_dir="$1"
	local dest_dir="$2"
	local dir_name="$3"

	# 检查源目录是否有文件
	local dir_contents
	dir_contents=$(find "${src_dir}" -mindepth 1 -maxdepth 1 2>/dev/null || true)
	if [[ ! -d ${src_dir} ]] || [[ -z ${dir_contents} ]]; then
		log_verbose "No ${dir_name} files to restore"
		return 0
	fi

	log_verbose "Restoring ${dir_name} using Docker..."
	_docker_copy_files "${src_dir}" "${dest_dir}" "${dir_name}"
}

# 内部函数：执行文件恢复
_perform_files_restore() {
	local backup_dir="$1"

	# 检查Docker可用性（统一检查）
	if ! command_exists docker; then
		log_error "Docker is required for model restoration but not available"
		return 1
	fi

	# 创建目标目录
	if ! mkdir -p "${OLLAMA_MODELS_DIR}/manifests" "${OLLAMA_MODELS_DIR}/blobs"; then
		log_error "Failed to create Ollama directories"
		return 1
	fi

	# 恢复manifest和blob文件（使用容器内路径）
	_restore_single_directory "${backup_dir}/manifests" "/root/.ollama/models/manifests" "manifest" || return 1
	_restore_single_directory "${backup_dir}/blobs" "/root/.ollama/models/blobs" "blob" || return 1

	return 0
}

#=============================================
# 13. 模型管理操作模块 (Model Management)
#=============================================

remove_ollama_model() {
	local model_spec="$1"
	local force_delete="${2:-false}"

	# 解析并验证模型格式（一次性完成验证和解析）
	local model_name model_version
	if ! parse_model_spec "${model_spec}" model_name model_version; then
		return 1
	fi

	log_verbose "Preparing to remove Ollama model: ${model_spec}"

	# 检查模型是否存在
	if ! check_ollama_model "${model_name}" "${model_version}"; then
		log_warning "Model does not exist, no need to delete: ${model_spec}"
		return 0
	fi

	# 如果不是强制删除，询问用户确认
	if [[ ${force_delete} != "true" ]]; then
		log_warning "About to delete model: ${model_spec}"
		echo -n "Confirm deletion? [y/N]: "
		read -r confirm
		if [[ ${confirm} != "y" && ${confirm} != "Y" ]]; then
			log_verbose "Delete operation cancelled"
			return 0
		fi
	fi

	# 执行删除
	if execute_ollama_command "rm" "false" "${model_spec}"; then
		log_verbose_success "Model deleted successfully: ${model_spec}"
		return 0
	else
		log_error "Failed to delete model: ${model_spec}"
		return 1
	fi
}

# 批量删除模型（根据models.list文件）

remove_models_from_list() {
	local models_file="$1"
	local force_delete="${2:-false}"

	log_verbose "Batch deleting models from: ${models_file}"

	# 解析模型列表
	local models=()
	if ! parse_models_list "${models_file}" models; then
		return 1
	fi

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "No models found for deletion"
		return 1
	fi

	local total_models=${#models[@]}
	log_verbose "Found ${total_models} models for deletion"

	# 预解析所有模型（避免重复解析）
	local -a parsed_models=()
	local invalid_count=0
	for model in "${models[@]}"; do
		local model_info
		declare -A model_info
		if parse_model_entry "${model}" model_info; then
			# 存储解析结果（格式：type|name|tag|display）
			parsed_models+=("${model_info[type]}|${model_info[name]}|${model_info[tag]}|${model_info[display]}")
		else
			log_error "Invalid model format, skipping: ${model}"
			((invalid_count++))
		fi
	done

	local valid_models=$((total_models - invalid_count))
	if [[ ${valid_models} -eq 0 ]]; then
		log_error "No valid models available for deletion"
		return 1
	fi

	# 如果不是强制删除，显示要删除的模型列表并请求确认
	if [[ ${force_delete} != "true" ]]; then
		log_warning "The following models will be deleted:"
		for parsed_model in "${parsed_models[@]}"; do
			IFS='|' read -r type name tag display <<<"${parsed_model}"
			echo "  - ${display}"
		done
		echo ""
		echo -n "Confirm deletion of ${valid_models} models? [y/N]: "
		read -r confirm
		if [[ ${confirm} != "y" && ${confirm} != "Y" ]]; then
			log_info "Cancelled batch delete operation"
			return 2 # 特殊退出码表示用户取消
		fi
		echo ""
	fi

	# 执行批量删除
	local processed=0
	local success=0
	local failed=0

	for parsed_model in "${parsed_models[@]}"; do
		((processed++))
		IFS='|' read -r model_type model_name model_tag model_display <<<"${parsed_model}"
		local model_spec="${model_name}:${model_tag}"
		log_info "Deleting model [${processed}/${valid_models}]: ${model_display}"

		# 批量删除时强制执行（跳过个别确认）
		if remove_ollama_model "${model_spec}" "true"; then
			((success++))
			log_verbose_success "Deleted successfully: ${model_spec}"
		else
			((failed++))
			log_error "Failed to delete: ${model_spec}"
		fi
	done

	# 显示删除总结
	log_info "Batch deletion completed: ${success} succeeded, ${failed} failed"
	if [[ ${failed} -eq 0 ]]; then
		log_verbose_success "All models deleted successfully"
		return 0
	else
		log_warning "Some models failed to delete"
		return 1
	fi
}

#=============================================
# 14. compose生成模块 (Docker Compose File)
#=============================================

# 生成docker-compose.yaml文件
update_existing_compose() {
	local output_file="$1"
	local custom_models="$2"
	local default_model="$3"

	log_info "Updating CUSTOM_MODELS configuration in existing docker-compose.yaml file"

	# Confirm overwrite with user
	log_warning "The file ${output_file} will be overwritten."
	printf "Do you want to continue? (y/N): "
	read -r confirmation
	if [[ ! ${confirmation} =~ ^[Yy]$ ]]; then
		log_info "Operation cancelled by user"
		return 1
	fi

	# Check if CUSTOM_MODELS exists in the file
	if ! grep -q "CUSTOM_MODELS=" "${output_file}"; then
		log_error "CUSTOM_MODELS configuration not found in docker-compose.yaml"
		return 1
	fi

	# Create temporary file for processing
	local temp_file
	temp_file=$(mktemp) || {
		log_error "Failed to create temporary file"
		return 1
	}

	# Update CUSTOM_MODELS line - use line-by-line processing
	local found_custom_models=false

	while IFS= read -r line; do
		if [[ ${line} =~ ^[[:space:]]*-[[:space:]]*\"?CUSTOM_MODELS= ]]; then
			# Found CUSTOM_MODELS line, replace it completely
			echo "      - \"CUSTOM_MODELS=${custom_models}\""
			found_custom_models=true
		elif [[ ${found_custom_models} == true ]] && [[ ${line} =~ ^[[:space:]]+[^-] ]] && [[ ! ${line} =~ ^[[:space:]]*-[[:space:]]* ]]; then
			# Skip continuation lines of previous CUSTOM_MODELS (indented lines that are not new env vars)
			continue
		else
			# Regular line - output as is
			echo "${line}"
		fi
	done <"${output_file}" >"${temp_file}"

	if [[ ${found_custom_models} != true ]]; then
		log_error "CUSTOM_MODELS configuration not found in docker-compose.yaml"
		return 1
	fi

	# Update DEFAULT_MODEL line
	if ! sed -E "s|(^[[:space:]]*-[[:space:]]*DEFAULT_MODEL=)[^[:space:]#]*(.*)|\\1${default_model}  # Auto-set to first model from models.list|" "${temp_file}" >"${output_file}"; then
		log_error "Failed to update DEFAULT_MODEL configuration"
		return 1
	fi

	log_success "Successfully updated docker-compose.yaml configuration"
	log_verbose "Updated models: ${custom_models}"
	log_verbose "Updated default model: ${default_model}"

	# Clean up temporary file
	rm -f "${temp_file}"

	return 0
}

generate_docker_compose() {
	local output_file="${1:-./docker-compose.yaml}"
	local models_file="${MODELS_FILE:-./models.list}"

	# Check if model list file exists
	if [[ ! -f ${models_file} ]]; then
		log_error "Model list file not found: ${models_file}"
		return 1
	fi

	# Parse models configuration in one pass
	local custom_models_content default_model
	parse_models_configuration "${models_file}" custom_models_content default_model

	# Validate generated configuration
	if [[ -z ${custom_models_content} ]]; then
		log_error "No active models found in ${models_file}"
		log_error "Please ensure at least one model is uncommented in the file"
		return 1
	fi

	log_verbose "Generated CUSTOM_MODELS: ${custom_models_content}"
	log_verbose "Detected default model: ${default_model}"

	# Handle existing vs new file
	if [[ -f ${output_file} && -s ${output_file} ]]; then
		log_info "Updating existing docker-compose.yaml configuration"
		update_existing_compose "${output_file}" "${custom_models_content}" "${default_model}"
	else
		log_info "Generating new docker-compose.yaml from model list: ${models_file}"
		generate_compose_content "${output_file}" "${custom_models_content}" "${default_model}"
	fi
}

# Parse models file and generate both custom models list and default model
parse_models_configuration() {
	local models_file="$1"
	local -n custom_models_ref=$2
	local -n default_model_ref=$3

	# Use existing parse_models_list function to get validated model entries
	# Suppress verbose logging during compose generation
	local models_array=()
	local was_suppressed="${_LOG_SUPPRESSED}"
	suppress_logging
	local parse_result
	parse_models_list "${models_file}" models_array
	parse_result=$?
	[[ ${was_suppressed} != "true" ]] && restore_logging

	if [[ ${parse_result} -ne 0 ]]; then
		custom_models_ref=""
		default_model_ref="qwen3-14b"
		return 1
	fi

	local custom_models_entries=("-all") # Start with -all to hide default models
	local first_active_model=""

	# Process each validated model entry
	for model_entry in "${models_array[@]}"; do
		local -A model_info
		if parse_model_entry "${model_entry}" model_info; then
			# Generate alias and custom model entry
			local model_spec="${model_info[name]}:${model_info[tag]}"
			local alias
			alias=$(generate_model_alias "${model_spec}" "${model_info[type]}")
			custom_models_entries+=("+${model_spec}@OpenAI=${alias}")

			# Set first active model as default if not set
			[[ -z ${first_active_model} ]] && first_active_model="${alias}"
		fi
	done

	# Generate custom models output
	if [[ ${#custom_models_entries[@]} -gt 1 ]]; then
		custom_models_ref="${custom_models_entries[0]}"
		for ((i = 1; i < ${#custom_models_entries[@]}; i++)); do
			custom_models_ref+=",\\
        ${custom_models_entries[i]}"
		done
	else
		custom_models_ref="" # No active models found
	fi

	# Set default model (passed by reference)
	# shellcheck disable=SC2034
	default_model_ref="${first_active_model:-qwen3-14b}"
}

# 生成简单的模型别名
generate_model_alias() {
	local model_spec="$1"
	local model_type="$2"

	# 根据模型类型提取实际的模型名称
	local model_name=""
	local model_version=""

	case "${model_type}" in
	"hf-gguf")
		# 对于 hf-gguf 模型，从路径中提取模型名称
		# 格式如: hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest
		if [[ ${model_spec} =~ hf\.co/[^/]+/([^/:]+) ]]; then
			model_name="${BASH_REMATCH[1]}"
			# 移除常见的 GGUF 后缀
			model_name=$(echo "${model_name}" | sed 's/-GGUF$//' | sed 's/_GGUF$//')
		fi
		;;
	*)
		# 对于 ollama 和其他类型，使用基础名称
		model_name="${model_spec%:*}"
		;;
	esac

	# 从模型规格中提取版本信息
	if [[ ${model_spec} =~ :(.+)$ ]]; then
		model_version="${BASH_REMATCH[1]}"
	fi

	# 如果没有提取到模型名称，使用类型作为后备
	if [[ -z ${model_name} ]]; then
		model_name="${model_type}"
	fi

	# 清理模型名称和版本中的特殊字符
	local clean_name
	clean_name=$(echo "${model_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

	if [[ -n ${model_version} && ${model_version} != "latest" ]]; then
		local clean_version
		clean_version=$(echo "${model_version}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
		echo "${clean_name}-${clean_version}"
	else
		echo "${clean_name}"
	fi
}

# Detect available GPU devices
detect_gpus() {
	local gpu_indices=""

	if command -v nvidia-smi &>/dev/null; then
		gpu_indices=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | tr '\n' ',' | sed 's/,$//')
		if [[ -n ${gpu_indices} ]]; then
			echo "${gpu_indices}"
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

	local cuda_devices host_timezone
	cuda_devices=$(detect_gpus)
	host_timezone=$(get_host_timezone)
	[[ -z ${host_timezone} ]] && host_timezone="UTC"

	# Generate docker-compose.yaml content
	cat >"${output_file}" <<EOF
services:
  ollama:
    image: ${DOCKER_IMAGE_OLLAMA}
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ./ollama:/root/.ollama
    networks:
      - llms-tools-network
    environment:
      # Ollama optimization configuration
      - CUDA_VISIBLE_DEVICES=${cuda_devices} # Auto-detect and use all available GPUs
      - OLLAMA_NEW_ENGINE=1 # New engine, ollamarunner
      - OLLAMA_SCHED_SPREAD=1 # Enable multi-GPU load balancing
      - OLLAMA_KEEP_ALIVE=5m # Model keep-alive duration in memory, minutes
      - OLLAMA_NUM_PARALLEL=3 # Number of concurrent requests
      - OLLAMA_FLASH_ATTENTION=1 # Flash attention for optimized attention computation, reducing VRAM usage
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
    image: ${DOCKER_IMAGE_ONE_API}
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
      - SESSION_SECRET=random_string
    command: [ "--port", "3001" ]
    restart: unless-stopped

  prompt-optimizer:
    image: ${DOCKER_IMAGE_PROMPT_OPTIMIZER}
    container_name: prompt-optimizer
    ports:
      - "8501:80"
    environment:
      - VITE_CUSTOM_API_BASE_URL=http://YOUR_SERVER_IP:3001/v1  # Replace with your server IP
      - VITE_CUSTOM_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # Replace with your API key
      - VITE_CUSTOM_API_MODEL=${default_model}  # Auto-set to first model from models.list
      - ACCESS_USERNAME=admin  # Replace with your username
      - ACCESS_PASSWORD=xxxxxxxxxxxxxxxxxxxxxx  # Replace with your password
    networks:
      - llms-tools-network
    depends_on:
      - one-api
    restart: unless-stopped

  chatgpt-next-web:
    image: ${DOCKER_IMAGE_CHATGPT_NEXT_WEB}
    container_name: chatgpt-next-web
    ports:
      - "3000:3000"
    environment:
      - OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # Replace with your OpenAI API key
      - BASE_URL=http://one-api:3001
      - PROXY_URL=
      - "CUSTOM_MODELS=${custom_models}"
      - DEFAULT_MODEL=${default_model}  # Auto-set to first model from models.list
      - CODE=xxxxxxxxxxxxxxxxxxxxxx  # Replace with your access password
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

	log_success "Successfully generated docker-compose.yaml: ${output_file}"
	log_verbose "Model configuration: ${custom_models}"
	log_verbose "Default model: ${default_model}"
	log_verbose "Detected GPU devices: ${cuda_devices}"
	echo ""
	log_info "⚠️  Important: The generated configuration contains placeholders that require modification:"
	log_info "== Required Configuration Changes =="
	log_info "1. VITE_CUSTOM_API_BASE_URL: Replace YOUR_SERVER_IP with actual server IP"
	log_info "2. VITE_CUSTOM_API_KEY: Replace with valid API key from one-api"
	log_info "3. ACCESS_USERNAME/ACCESS_PASSWORD: Set login credentials for prompt-optimizer"
	log_info "4. OPENAI_API_KEY: Replace with valid API key from one-api"
	log_info "5. CODE: Set access password for ChatGPT-Next-Web"
	log_info "6. VITE_CUSTOM_API_MODEL/DEFAULT_MODEL: Auto-set to ${default_model}, modify as needed"
	echo ""
	log_info "== Optional Configuration Changes =="
	log_info "• Port mappings: Modify host ports to avoid conflicts"
	log_info "  - Ollama: 11434 -> custom port"
	log_info "  - One-API: 3001 -> custom port"
	log_info "  - Prompt-Optimizer: 8501 -> custom port"
	log_info "  - ChatGPT-Next-Web: 3000 -> custom port"
	log_info "• Docker images: Modify image tags to use specific versions"
	log_info "• Network configuration: Modify subnet to avoid IP conflicts"
	echo ""
	log_info "After configuration, run: docker compose up -d"

	return 0
}
#=============================================
# 15. 系统检查与初始化模块 (System Check)
#=============================================

check_gpu_support() {
	# 检查是否支持NVIDIA GPU
	if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
		return 0 # 支持GPU
	fi
	return 1 # 不支持GPU
}

check_dependencies() {
	local missing_deps=()

	# Check Docker - the only critical external dependency
	if ! command_exists docker; then
		missing_deps+=("docker")
		log_error "Docker not installed or not in PATH"
	else
		log_verbose "Docker found, checking daemon status..."
		if ! docker info &>/dev/null; then
			log_error "Docker is installed but daemon is not running"
			log_error "Please start Docker service and try again"
			return 1
		fi
		log_verbose "Docker daemon is running"
	fi

	# Check for MD5 calculation capability (system-specific)
	if ! command_exists md5sum && ! command_exists md5; then
		log_verbose "Warning: Neither md5sum nor md5 command found, backup integrity checks may be limited"
	fi

	# Report missing critical dependencies
	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		log_error "Missing required dependencies: ${missing_deps[*]}"
		log_error ""
		log_error "Installation suggestions:"
		log_error "  Ubuntu/Debian: sudo apt-get install docker.io"
		log_error "  RHEL/CentOS:   sudo yum install docker"
		log_error "  macOS:         brew install docker"
		log_error ""
		log_error "Please install the missing dependencies and rerun the script"
		return 1
	fi

	# Check GPU support (optional)
	if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
		log_verbose "NVIDIA GPU support detected, GPU acceleration will be enabled"
	else
		log_verbose "No NVIDIA GPU support detected, running in CPU-only mode"
	fi

	log_verbose "Dependency check completed successfully"
	return 0
}

#=============================================
# 16. 任务执行与主程序模块 (Main Program)
#=============================================

execute_task() {
	local task_name="$1"
	local task_function="$2"
	shift 2
	local task_args=("$@")

	log_info "Executing ${task_name}..."
	if "${task_function}" "${task_args[@]}"; then
		log_success "${task_name} completed"
		exit 0
	else
		local exit_code=$?
		if [[ ${exit_code} -eq 2 ]]; then
			# 用户取消操作，不显示错误信息
			exit 0
		else
			log_error "${task_name} failed"
			exit 1
		fi
	fi
}

# 模型处理器 - 解析模型条目并返回处理函数

show_help() {
	cat <<'EOF'
🤖 OMO - Oh-My-Ollama or Ollama-Models-Organizer

Docker-based tool for managing Ollama models with backup and compose generation.

USAGE:
  ./omo.sh [OPTIONS]

OPTIONS:
  --models-file FILE      Model list file (default: ./models.list)
  --ollama-dir DIR        Ollama data directory (default: ./ollama)
  --backup-dir DIR        Backup directory (default: ./backups)
  --verbose               Enable verbose logging
  --force                 Skip confirmations
  --help                  Show this help

  --install               Download missing models
  --check-only            Check status only (default)
  --force-download        Force re-download all models
  --list                  List installed models

  --backup MODEL          Backup model (format: name:version)
  --backup-all            Backup all models
  --restore FILE          Restore from backup

  --remove MODEL          Remove model (format: name:version)
  --remove-all            Remove all models

  --generate-compose      Generate docker-compose.yaml

MODEL FORMATS:
  ollama deepseek-r1:1.5b
  hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest

EXAMPLES:
  ./omo.sh --install                    # Download missing models
  ./omo.sh --list                       # List installed models
  ./omo.sh --backup qwen3:8b            # Backup specific model
  ./omo.sh --generate-compose           # Generate docker-compose.yaml

DEPENDENCIES:
  - Docker (required)
  - nvidia-smi (optional, for GPU support)

GitHub: https://github.com/LaiQE/omo
EOF
}
# 主函数

main() {
	# 检查参数 - 支持help在任何位置
	for arg in "$@"; do
		if [[ ${arg} == "--help" || ${arg} == "-h" ]]; then
			show_help
			exit 0
		fi
	done

	# 默认值
	CHECK_ONLY="true"
	FORCE_DOWNLOAD="false"
	BACKUP_MODEL=""
	BACKUP_ALL="false"
	LIST_MODELS="false"
	RESTORE_FILE=""
	GENERATE_COMPOSE="false"
	FORCE="false" # 通用强制标志
	REMOVE_MODEL=""
	REMOVE_ALL="false"

	# 解析命令行参数
	while [[ $# -gt 0 ]]; do
		case $1 in
		--models-file)
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--models-file requires a file path"
				show_help
				exit 1
			fi
			MODELS_FILE="$2"
			shift 2
			;;
		--ollama-dir)
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--ollama-dir requires a directory path"
				show_help
				exit 1
			fi
			# 处理用户指定的Ollama目录
			local user_ollama_dir="$2"
			user_ollama_dir="${user_ollama_dir%/}" # 移除末尾斜杠

			# 设置数据目录和模型目录
			if [[ ${user_ollama_dir} == */models ]]; then
				OLLAMA_MODELS_DIR="${user_ollama_dir}"
				OLLAMA_DATA_DIR="${user_ollama_dir%/models}"
			else
				OLLAMA_DATA_DIR="${user_ollama_dir}"
				OLLAMA_MODELS_DIR="${user_ollama_dir}/models"
			fi
			shift 2
			;;
		--backup)
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--backup requires a model specification"
				show_help
				exit 1
			fi
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
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--restore requires a backup file path"
				show_help
				exit 1
			fi
			RESTORE_FILE="$2"
			shift 2
			;;
		--remove)
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--remove requires a model specification"
				show_help
				exit 1
			fi
			REMOVE_MODEL="$2"
			shift 2
			;;
		--remove-all)
			REMOVE_ALL="true"
			shift
			;;
		--backup-dir)
			if [[ $# -lt 2 || -z $2 ]]; then
				log_error "--backup-dir requires a directory path"
				show_help
				exit 1
			fi
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
			CHECK_ONLY="false" # 强制下载时应该实际执行下载
			shift
			;;
		--force)
			FORCE="true"
			shift
			;;
		--verbose)
			VERBOSE="true"
			shift
			;;
		--generate-compose)
			GENERATE_COMPOSE="true"
			shift
			;;
		*)
			log_error "Unknown parameter: $1"
			show_help
			exit 1
			;;
		esac
	done

	# 确定并显示当前任务
	local current_task="Install/download models" # 默认任务
	if [[ -n ${BACKUP_MODEL} ]]; then
		current_task="Backup model: ${BACKUP_MODEL}"
	elif [[ ${BACKUP_ALL} == "true" ]]; then
		current_task="Batch backup all models"
	elif [[ -n ${RESTORE_FILE} ]]; then
		current_task="Restore model: ${RESTORE_FILE}"
	elif [[ -n ${REMOVE_MODEL} ]]; then
		current_task="Remove model: ${REMOVE_MODEL}"
	elif [[ ${REMOVE_ALL} == "true" ]]; then
		current_task="Batch remove all models"
	elif [[ ${LIST_MODELS} == "true" ]]; then
		current_task="List installed models"
	elif [[ ${GENERATE_COMPOSE} == "true" ]]; then
		current_task="Generate Docker Compose configuration"
	elif [[ ${CHECK_ONLY} == "true" ]]; then
		current_task="Check model status"
	fi

	log_info "🚀 Task: ${current_task}"
	log_verbose "Model list file: ${MODELS_FILE}"
	log_verbose "Ollama directory: ${OLLAMA_MODELS_DIR}"
	[[ -n ${BACKUP_OUTPUT_DIR} ]] && log_verbose "Backup directory: ${BACKUP_OUTPUT_DIR}"

	# 初始化所有必要的目录
	if ! mkdir -p "${OLLAMA_DATA_DIR}" "${OLLAMA_MODELS_DIR}" 2>/dev/null; then
		log_error "Unable to create necessary directories"
		return 1
	fi
	ABS_OLLAMA_DATA_DIR="$(realpath "${OLLAMA_DATA_DIR}")"

	# 执行特定任务并退出
	# shellcheck disable=SC2317  # Commands are reachable when conditions are met
	if [[ -n ${BACKUP_MODEL} ]]; then
		# 解析模型信息
		local -A model_info
		if parse_model_entry "${BACKUP_MODEL}" model_info; then
			execute_task "model backup" backup_single_model model_info && exit 0 || exit 1
		else
			log_error "Invalid model format: ${BACKUP_MODEL}"
			exit 1
		fi
	elif [[ ${BACKUP_ALL} == "true" ]]; then
		execute_task "batch backup" backup_models_from_list "${MODELS_FILE}" && exit 0 || exit 1
	elif [[ ${LIST_MODELS} == "true" ]]; then
		execute_task "model list" list_installed_models && exit 0 || exit 1
	elif [[ ${GENERATE_COMPOSE} == "true" ]]; then
		execute_task "Docker configuration generation" generate_docker_compose && exit 0 || exit 1
	elif [[ -n ${RESTORE_FILE} ]]; then
		execute_task "model restore" restore_model "${RESTORE_FILE}" "${FORCE}" && exit 0 || exit 1
	elif [[ -n ${REMOVE_MODEL} ]]; then
		execute_task "model removal" remove_ollama_model "${REMOVE_MODEL}" "${FORCE}" && exit 0 || exit 1
	elif [[ ${REMOVE_ALL} == "true" ]]; then
		execute_task "batch delete" remove_models_from_list "${MODELS_FILE}" "${FORCE}" && exit 0 || exit 1
	fi

	# 对于需要模型列表的操作，检查依赖和解析模型列表
	# 不需要模型列表的操作已在上面退出
	if ! check_dependencies; then
		log_error "Dependency check failed"
		exit 1
	fi

	# 解析模型列表
	local models=()
	if ! parse_models_list "${MODELS_FILE}" models; then
		log_error "Failed to parse models list from: ${MODELS_FILE}"
		exit 1
	fi

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "No models found, exiting"
		exit 0
	fi

	# 处理每个模型
	local total_models=${#models[@]}
	local processed=0
	local failed=0

	for model in "${models[@]}"; do
		processed=$((processed + 1))
		log_verbose "Processing model [${processed}/${total_models}]: ${model}"

		# 处理单个模型错误，不中断整个流程
		if ! process_model "${model}" "${FORCE_DOWNLOAD}" "${CHECK_ONLY}"; then
			failed=$((failed + 1))
		fi
	done

	# 显示总结
	log_info "=== Processing Complete ==="
	log_info "Total models: ${total_models}"
	log_info "Processed: ${processed}"
	if [[ ${failed} -gt 0 ]]; then
		log_warning "Failed: ${failed}"
	else
		log_success "All completed successfully"
	fi

	if [[ ${CHECK_ONLY} == "true" ]]; then
		log_info "Check mode completed, no actual downloads performed"
	fi
}

# 只有在直接运行脚本时才执行main函数
if [[ ${BASH_SOURCE[0]:-$0} == "${0}" ]]; then
	main "$@"
fi
