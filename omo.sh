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

#==============================================================================
# 全局配置和变量定义
#==============================================================================
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

#==============================================================================
# 工具函数
#==============================================================================

# 显示容器日志的工具函数
show_container_logs() {
	local container_name="$1"
	log_error "Container logs:"
	docker logs "${container_name}" 2>&1 | tail -10
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

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#==============================================================================
# 任务执行模块
#==============================================================================
# 统一的任务执行函数
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

# 备份单个模型的包装函数
backup_single_model() {
	local backup_model="$1"
	local backup_dir="$2"

	# 处理不同类型的模型前缀
	local model_to_backup="${backup_model}"
	if [[ ${backup_model} =~ ^hf-gguf:(.+)$ ]]; then
		model_to_backup="${BASH_REMATCH[1]}"
	elif [[ ${backup_model} =~ ^ollama:(.+)$ ]]; then
		model_to_backup="${BASH_REMATCH[1]}"
	fi

	backup_ollama_model "${model_to_backup}" "${backup_dir}"
}

# 恢复模型的包装函数
restore_model() {
	local restore_file="$1"
	local force_restore="$2"

	# 如果恢复文件不是绝对路径，则在BACKUP_OUTPUT_DIR中查找
	local restore_path="${restore_file}"
	if [[ ${restore_file} != /* ]]; then
		restore_path="${BACKUP_OUTPUT_DIR}/${restore_file}"
	fi

	restore_ollama_model "${restore_path}" "${force_restore}"
}

# 模型处理器 - 解析模型条目并返回处理函数
parse_model_entry() {
	local model_entry="$1"
	local -n result_ref="$2"

	# 清空结果数组
	result_ref=()

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

# 检查模型是否存在
check_model_exists() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama")
		check_ollama_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	"hf-gguf")
		check_hf_gguf_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		return 1
		;;
	esac
}

# 下载模型
download_model() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama")
		download_ollama_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	"hf-gguf")
		download_hf_gguf_model "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		return 1
		;;
	esac
}

# 尝试从备份恢复模型
try_restore_model() {
	local -n model_info_ref=$1

	case "${model_info_ref[type]}" in
	"ollama")
		try_restore_ollama_from_backup "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	"hf-gguf")
		try_restore_ollama_from_backup "${model_info_ref[name]}" "${model_info_ref[tag]}"
		;;
	*)
		return 1
		;;
	esac
}

#==============================================================================
# 日志系统模块
#==============================================================================
# 日志规则:
# 1. 主流程函数: 使用标准日志函数(log_info, log_success, log_warning, log_error)
#    - 在普通模式和verbose模式下都显示, 用于用户关心的核心操作进度
# 2. 工具函数: 正常追踪日志使用verbose版本(log_verbose, log_verbose_success)
#    - 仅在verbose模式显示, 警告和错误(log_warning, log_error)在任何模式都显示
# 3. 避免日志重复: 工具函数的追踪信息只在verbose模式显示, 主流程保持简洁
#==============================================================================

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

# Verbose-only logging functions
log_verbose() {
	if [[ ${VERBOSE} == "true" ]]; then
		printf "${BLUE}[INFO]${NC} %s\n" "$1"
	fi
	return 0
}

log_verbose_success() {
	[[ ${VERBOSE} == "true" ]] && printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
	return 0
}

log_verbose_warning() {
	[[ ${VERBOSE} == "true" ]] && printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
	return 0
}

# 格式化字节大小为人类可读格式
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

# 验证模型格式是否正确
validate_model_format() {
	local model_spec="$1"
	if [[ ${model_spec} != *":"* ]]; then
		log_error "Invalid model format, should be 'model_name:version', e.g. 'llama2:7b'"
		return 1
	fi
	return 0
}

# 等待Ollama容器就绪
wait_for_ollama_ready() {
	local container_name="$1"
	local max_attempts=120 # 增加到120秒
	local attempt=0

	log_verbose "Waiting for Ollama service to start..."

	while ((attempt < max_attempts)); do
		# 首先检查容器是否还在运行
		if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then
			log_error "Container ${container_name} has stopped running"
			show_container_logs "${container_name}"
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

	log_error "Timeout waiting for Ollama service to be ready (${max_attempts} seconds)"
	show_container_logs "${container_name}"
	return 1
}

# 构建完整的Docker运行命令
build_full_docker_cmd() {
	local container_name="$1"
	local use_gpu="${2:-true}"
	local _include_hf_token="${3:-false}" # Currently unused, reserved for future use
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

	local docker_cmd=("docker" "run" "--name" "${container_name}" "--rm" "-t")

	# GPU支持
	if [[ ${use_gpu} == "true" ]]; then
		docker_cmd+=("--gpus" "all")
	fi

	# 基础环境变量
	docker_cmd+=("-e" "PYTHONUNBUFFERED=1")
	docker_cmd+=("-e" "TERM=xterm-256color")
	docker_cmd+=("-v" "/etc/localtime:/etc/localtime:ro")
	docker_cmd+=("-e" "TZ=${HOST_TIMEZONE:-UTC}")

	# 添加额外的环境变量
	for env_var in "${extra_env[@]}"; do
		docker_cmd+=("-e" "${env_var}")
	done

	# 添加额外的挂载卷
	for volume in "${extra_volumes[@]}"; do
		docker_cmd+=("-v" "${volume}")
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
        local cleanup_items=(${cleanup_items_str})
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
	trap '$cleanup_function' "${signals}"
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

# 全局清理函数管理
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

# 移除清理函数
remove_cleanup_function() {
	local func_name="$1"
	local new_array=()
	local func

	for func in "${GLOBAL_CLEANUP_FUNCTIONS[@]}"; do
		if [[ ${func} != "${func_name}" ]]; then
			new_array+=("${func}")
		fi
	done

	GLOBAL_CLEANUP_FUNCTIONS=("${new_array[@]}")
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
	OLLAMA_MODELS_CACHE=$(execute_ollama_command_with_output "list" | awk 'NR>1 {print $1}' | sort)
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

# 检查Ollama模型是否存在（使用缓存）
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

# 验证模型业务逻辑完整性
validate_model_business_integrity() {
	local backup_file="$1"

	# 创建临时目录提取备份文件
	local temp_dir
	temp_dir=$(mktemp -d) || {
		log_error "Failed to create temporary directory"
		return 1
	}

	# 清理函数
	cleanup_temp_business() {
		[[ -d ${temp_dir-} ]] && docker_rm_rf "${temp_dir}"
	}
	add_cleanup_function "cleanup_temp_business"

	# 提取备份文件到临时目录
	if ! tar -xf "${backup_file}" -C "${temp_dir}" 2>/dev/null; then
		log_error "Unable to extract backup file for business logic verification"
		cleanup_temp_business
		return 1
	fi

	# 查找manifest文件
	local manifest_files=()
	while IFS= read -r -d '' manifest; do
		manifest_files+=("${manifest}")
	done < <(find "${temp_dir}" -path "*/manifests/*" -type f -print0 2>/dev/null || true)

	if [[ ${#manifest_files[@]} -eq 0 ]]; then
		log_error "Manifest file not found in backup"
		cleanup_temp_business
		return 1
	fi

	# 检查每个manifest引用的blob文件
	local missing_blobs=0
	local total_blobs=0

	for manifest_file in "${manifest_files[@]}"; do
		if [[ -f ${manifest_file} ]]; then
			# 解析manifest文件中的blob引用
			local blob_digests
			blob_digests=$(grep -o '"digest":"sha256:[a-f0-9]\{64\}"' "${manifest_file}" 2>/dev/null | sed 's/"digest":"sha256:\([a-f0-9]\{64\}\)"/\1/g')

			for digest in ${blob_digests}; do
				((total_blobs++))
				local blob_path="${temp_dir}/blobs/sha256-${digest}"
				if [[ ! -f ${blob_path} ]]; then
					log_error "Missing blob file: sha256-${digest}"
					((missing_blobs++))
				fi
			done
		fi
	done

	cleanup_temp_business
	remove_cleanup_function "cleanup_temp_business"

	if [[ ${missing_blobs} -gt 0 ]]; then
		log_error "Found ${missing_blobs}/${total_blobs} missing blob files"
		return 1
	fi

	log_verbose_success "Model business logic integrity verification passed (${total_blobs} blob files)"
	return 0
}

# 清理不完整的模型
cleanup_incomplete_model() {
	local model_name="$1"
	local model_tag="$2"
	local full_model_name="${model_name}:${model_tag}"

	log_verbose_warning "Detected incomplete model, cleaning up: ${full_model_name}"

	# 确定manifest文件路径
	local manifest_file
	if [[ ${model_name} == hf.co/* ]]; then
		# HuggingFace GGUF模型
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/${model_name}/${model_tag}"
	elif [[ ${model_name} == *"/"* ]]; then
		# 用户分享的模型
		local user_name="${model_name%/*}"
		local repo_name="${model_name#*/}"
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/${user_name}/${repo_name}/${model_tag}"
	else
		# 官方模型
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${model_name}/${model_tag}"
	fi

	# 删除manifest文件
	if [[ -f ${manifest_file} ]]; then
		if docker_rm_rf "${manifest_file}"; then
			log_verbose "Deleted incomplete manifest file: ${manifest_file}"
		else
			log_warning "Unable to delete manifest file: ${manifest_file}"
		fi
	fi

	# 清除缓存，强制重新检查
	OLLAMA_CACHE_INITIALIZED="false"
	OLLAMA_MODELS_CACHE=""

	log_verbose_success "Incomplete model cleanup completed: ${full_model_name}"
}

# 验证模型安装后的完整性
verify_model_after_installation() {
	local model_name="$1"
	local model_tag="$2"
	local full_model_name="${model_name}:${model_tag}"

	log_verbose "Verifying model installation integrity: ${full_model_name}"

	# 初始化缓存以提高完整性检查性能
	ensure_cache_initialized

	# 等待一下让文件系统同步
	sleep 2

	# 检查模型完整性（使用缓存优化）
	local model_spec="${model_name}:${model_tag}"
	if verify_integrity "model" "${model_spec}" "use_cache:true,check_blobs:true"; then
		log_verbose_success "Model installation integrity verification passed: ${full_model_name}"
		return 0
	else
		log_error "Model installation incomplete, cleaning up: ${full_model_name}"
		cleanup_incomplete_model "${model_name}" "${model_tag}"
		return 1
	fi
}

# 简化的模型检查函数
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

# 解析模型规格（model:version格式）
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

# 初始化绝对路径
init_paths() {
	# 获取绝对路径，如果目录不存在则先创建父目录
	mkdir -p "${OLLAMA_DATA_DIR}" || {
		log_error "Unable to create necessary directories"
		return 1
	}

	ABS_OLLAMA_DATA_DIR="$(realpath "${OLLAMA_DATA_DIR}")"

}

# Docker backup helper functions

# Docker辅助函数 - 重命名分卷文件（从.000,.001,.002格式到.001,.002,.003格式）

# Docker helper function - list tar content directly

# 文件系统操作辅助函数
docker_rm_rf() {
	local target_path="$1"

	# 安全检查：防止删除空路径或根目录
	if [[ -z ${target_path} || ${target_path} == "/" ]]; then
		log_error "Safe delete: path is empty or root directory, deletion refused"
		return 1
	fi

	# 直接使用系统rm命令
	rm -rf "${target_path}" 2>/dev/null
}

docker_mkdir_p() {
	local target_path="$1"

	# 直接使用系统mkdir命令
	mkdir -p "${target_path}" 2>/dev/null
}

# 确保ollama/ollama镜像存在
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

	# 检查本地11434端口是否有服务响应（可能是外部容器）
	if command -v curl >/dev/null 2>&1; then
		if curl -s --connect-timeout 2 http://localhost:11434/api/version >/dev/null 2>&1; then
			# 找到使用11434端口的容器
			local port_container
			port_container=$(docker ps --format "{{.Names}}" --filter "publish=11434")
			if [[ -n ${port_container} ]]; then
				EXISTING_OLLAMA_CONTAINER=$(echo "${port_container}" | head -n1)
				log_verbose "Found Ollama container using port 11434: ${EXISTING_OLLAMA_CONTAINER}"
				return 0
			fi
		fi
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
	cmd+=("-p" "11435:11434") # 使用不同端口避免冲突
	cmd+=("${DOCKER_IMAGE_OLLAMA}")

	# 启动容器
	local start_output
	if start_output=$("${cmd[@]}" 2>&1); then
		log_verbose "Temporary container started successfully, ID: ${start_output:0:12}"

		# 等待服务就绪
		if wait_for_ollama_ready "${TEMP_OLLAMA_CONTAINER}"; then
			log_verbose_success "Temporary Ollama container ready: ${TEMP_OLLAMA_CONTAINER}"
			# 设置清理陷阱
			setup_temp_container_cleanup
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

# 清理临时Ollama容器
cleanup_temp_ollama_container() {
	if [[ -n ${TEMP_OLLAMA_CONTAINER} ]]; then
		log_verbose "Cleaning up temporary Ollama container: ${TEMP_OLLAMA_CONTAINER}"
		docker rm -f "${TEMP_OLLAMA_CONTAINER}" &>/dev/null
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

	log_verbose "Executing Ollama command: ${action} ${args[*]}"

	# 首先查找运行中的Ollama容器
	if find_running_ollama_container; then
		log_verbose "Using existing Ollama container: ${EXISTING_OLLAMA_CONTAINER}"
		log_verbose "Executing command: docker exec ${EXISTING_OLLAMA_CONTAINER} ollama ${action} ${args[*]}"
		if docker exec "${EXISTING_OLLAMA_CONTAINER}" ollama "${action}" "${args[@]}"; then
			return 0
		else
			log_error "Failed to execute Ollama command in existing container: ${action} ${args[*]}"
			return 1
		fi
	else
		# 没有找到运行中的容器，启动临时容器
		log_verbose "No running Ollama container found, starting a temporary container"
		if start_temp_ollama_container; then
			log_verbose "Executing command in temporary container: docker exec ${TEMP_OLLAMA_CONTAINER} ollama ${action} ${args[*]}"
			if docker exec "${TEMP_OLLAMA_CONTAINER}" ollama "${action}" "${args[@]}"; then
				return 0
			else
				log_error "Failed to execute Ollama command in temporary container: ${action} ${args[*]}"
				return 1
			fi
		else
			log_error "Unable to start temporary Ollama container"
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
		docker exec "${EXISTING_OLLAMA_CONTAINER}" ollama "${action}" "${args[@]}" 2>/dev/null
	else
		# 没有找到运行中的容器，启动临时容器
		if start_temp_ollama_container; then
			docker exec "${TEMP_OLLAMA_CONTAINER}" ollama "${action}" "${args[@]}" 2>/dev/null
		else
			return 1
		fi
	fi
}

# 显示使用帮助
show_help() {
	cat <<'EOF'
🤖 OMO - Oh My Ollama / Ollama Models Organizer

使用方法:
  ./omo.sh [OPTIONS]

选项:
  --models-file FILE    指定模型列表文件 (默认: ./models.list)
  --ollama-dir DIR      指定Ollama数据目录 (默认: ./ollama)
  --backup-dir DIR      备份目录 (默认: ./backups)
  --install             安装/下载模型 (覆盖默认的仅检查行为)
  --check-only          仅检查模型状态，不下载 (默认行为)
  --force-download      强制重新下载所有模型 (自动启用安装模式)
  --verbose             显示详细日志
  --list                列出已安装的Ollama模型及详细信息
  --backup MODEL        备份指定模型 (格式: 模型名:版本)
  --backup-all          备份所有模型
  --restore FILE        恢复指定备份文件
  --remove MODEL        删除指定模型
  --remove-all          删除所有模型
  --force               强制操作（跳过确认）
  --generate-compose    生成docker-compose.yaml文件（基于models.list）
  --help                显示帮助信息

模型列表文件格式:
  ollama deepseek-r1:1.5b
  hf-gguf hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:latest

下载缓存:
  HuggingFace GGUF模型下载支持断点续传和缓存复用
  每个模型有独立的缓存子目录
  中断后重新运行脚本将恢复下载，完成后自动缓存

EOF
	cat <<'EOF'

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
		return 0 # 支持GPU
	fi
	return 1 # 不支持GPU
}

check_dependencies() {
	local missing_deps=()

	# 检查 docker
	if ! command_exists docker; then
		missing_deps+=("docker")
		log_error "Docker not installed or not in PATH"
	else
		# 检查 Docker 守护进程是否运行
		if ! docker info &>/dev/null; then
			log_error "Docker is installed but daemon is not running, please start Docker service"
			return 1
		fi
	fi

	# 检查 tar
	if ! command_exists tar; then
		missing_deps+=("tar")
		log_error "tar not installed, required for model file packing/unpacking"
	fi

	# 如果有缺失的依赖，给出提示并退出
	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		log_error "Missing required system dependencies: ${missing_deps[*]}"
		log_error "Please install the missing dependencies and rerun the script"
		return 1
	fi

	# 检查GPU支持（必需项）
	if ! check_gpu_support; then
		log_error "No NVIDIA GPU support detected. This script requires a GPU environment."
		log_error "Please ensure: 1) NVIDIA drivers are installed  2) nvidia-smi tool is installed"
		return 1
	fi

	log_verbose "NVIDIA GPU support detected, GPU acceleration will be enabled"

	# 所有依赖检查通过，静默返回
	return 0
}

# 解析模型列表文件
parse_models_list() {
	local models_file="$1"
	local -n models_array=${2:-models}

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
			if [[ ${model_type} == "ollama" || ${model_type} == "hf-gguf" ]]; then
				# 如果有量化类型，添加到模型信息中
				if [[ -n ${quantization} ]]; then
					models_array+=("${model_type}:${model_name}:${quantization}")
					log_verbose "Added model: ${model_type} -> ${model_name}:${quantization}"
				else
					models_array+=("${model_type}:${model_name}")
					log_verbose "Added model: ${model_type} -> ${model_name}"
				fi
			else
				log_warning "Unknown model type: ${model_type} (line: ${line})"
			fi
		else
			log_warning "Ignoring invalid line: ${line}"
		fi
	done <"${models_file}"

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
		log_warning "  hf-gguf hf.co/MaziyarPanahi/gemma-3-1b-it-GGUF"
		log_warning "====================================================================="
		echo
	else
		log_verbose "Total models parsed: ${#models_array[@]}"
	fi
}

# 检查HuggingFace GGUF模型是否存在（通过Ollama检查）
check_hf_gguf_model() {
	local model_name="$1"
	local model_tag="$2"
	local full_model_name="${model_name}:${model_tag}"

	# 使用容器检查
	if check_ollama_model_exists "${full_model_name}"; then
		log_verbose_success "HuggingFace GGUF model already exists: ${full_model_name}"
		return 0
	fi

	log_verbose_warning "HuggingFace GGUF model does not exist: ${full_model_name}"
	return 1
}

# 下载Ollama模型
download_ollama_model() {
	local model_name="$1"
	local model_tag="$2"

	log_info "Downloading model: ${model_name}:${model_tag}"

	if execute_ollama_command "pull" "${model_name}:${model_tag}"; then
		log_verbose_success "Ollama model download completed: ${model_name}:${model_tag}"

		# 验证下载后的模型完整性
		if verify_model_after_installation "${model_name}" "${model_tag}"; then
			log_verbose_success "Model integrity check passed: ${model_name}:${model_tag}"
			return 0
		else
			log_verbose_warning "Model integrity check failed, model has been removed: ${model_name}:${model_tag}"
			return 1
		fi
	else
		log_error "Failed to download Ollama model: ${model_name}:${model_tag}"
		return 1
	fi
}

# 下载HuggingFace GGUF模型（通过Ollama直接下载）
download_hf_gguf_model() {
	local model_name="$1"
	local model_tag="$2"
	local full_model_name="${model_name}:${model_tag}"

	log_verbose "Starting download of HuggingFace GGUF model: ${full_model_name}"

	if execute_ollama_command "pull" "${full_model_name}"; then
		log_verbose_success "HuggingFace GGUF model download completed: ${full_model_name}"

		# 验证下载后的模型完整性
		if verify_model_after_installation "${model_name}" "${model_tag}"; then
			log_verbose_success "Model integrity check passed: ${full_model_name}"
			return 0
		else
			log_error "Model integrity check failed, model has been removed: ${full_model_name}"
			return 1
		fi
	else
		log_error "Failed to download HuggingFace GGUF model: ${full_model_name}"
		return 1
	fi
}

# 删除Ollama模型
remove_ollama_model() {
	local model_spec="$1"
	local force_delete="${2:-false}"

	# 解析模型名称和版本
	if ! validate_model_format "${model_spec}"; then
		return 1
	fi

	log_verbose "Preparing to remove Ollama model: ${model_spec}"

	# 检查模型是否存在
	local model_name model_version
	if ! parse_model_spec "${model_spec}" model_name model_version; then
		return 1
	fi
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

	if execute_ollama_command "rm" "${model_spec}"; then
		log_verbose_success "Ollama model deleted successfully: ${model_spec}"
		return 0
	else
		log_error "Failed to delete Ollama model: ${model_spec}"
		return 1
	fi
}

# 获取模型相关的blob文件路径
get_model_blob_paths() {
	local manifest_file="$1"
	local models_dir="$2"
	local blob_paths=()

	if [[ ! -f ${manifest_file} ]]; then
		log_error "Model manifest file does not exist: ${manifest_file}"
		return 1
	fi

	# 使用hf_downloader镜像中的jq解析JSON文件
	local layers
	layers=$(docker run --rm --entrypoint="" -v "$(dirname "${manifest_file}"):/data" hf_downloader jq -r '.layers[].digest, .config.digest' "/data/$(basename "${manifest_file}")" 2>/dev/null | sort -u)

	# 构建blob文件路径
	while IFS= read -r digest; do
		if [[ -n ${digest} ]]; then
			# 将 sha256:xxx 格式转换为 sha256-xxx
			local blob_name="${digest//:/-}"
			local blob_file="${models_dir}/blobs/${blob_name}"
			blob_paths+=("${blob_file}")
		fi
	done <<<"${layers}"

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

# 文件大小工具函数
get_file_size() {
	local file_path="$1"
	local format="${2:-mb}" # mb, human

	case "${format}" in
	"mb")
		du -sm "${file_path}" 2>/dev/null | cut -f1
		;;
	"human")
		du -sh "${file_path}" 2>/dev/null | cut -f1
		;;
	*)
		log_error "Unknown format: ${format}. Use 'mb' or 'human'"
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

	if [[ ! -d ${dir_path} ]]; then
		log_error "Directory does not exist: ${dir_path}"
		return 1
	fi

	if [[ ! -f ${md5_file} ]]; then
		log_error "MD5 checksum file does not exist: ${md5_file}"
		return 1
	fi

	log_verbose "Verifying directory MD5 checksum: ${dir_path}"

	# 临时计算当前目录的MD5值
	local temp_md5
	temp_md5=$(mktemp)
	if ! calculate_directory_md5 "${dir_path}" "${temp_md5}"; then
		rm -f "${temp_md5}"
		return 1
	fi

	# 比较MD5文件
	if diff "${md5_file}" "${temp_md5}" >/dev/null 2>&1; then
		log_verbose "MD5 checksum verified"
		rm -f "${temp_md5}"
		return 0
	else
		log_error "MD5 checksum verification failed"
		rm -f "${temp_md5}"
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
	if [[ -n ${MODEL_BLOB_CACHE[${model_spec}]-} ]]; then
		echo "${MODEL_BLOB_CACHE[${model_spec}]}"
		return 0
	fi

	# 解析模型名称和版本
	local model_name model_version
	if ! parse_model_spec "${model_spec}" model_name model_version; then
		return 1
	fi

	# 确定manifest文件路径
	local manifest_file
	if [[ ${model_name} == hf.co/* ]]; then
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/${model_name}/${model_version}"
	elif [[ ${model_name} == *"/"* ]]; then
		local user_name="${model_name%/*}"
		local repo_name="${model_name#*/}"
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/${user_name}/${repo_name}/${model_version}"
	else
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${model_name}/${model_version}"
	fi

	# 获取blob文件列表
	if [[ -f ${manifest_file} ]]; then
		local blobs
		blobs=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}" | sed "s|^${OLLAMA_MODELS_DIR}/||")
		if [[ -n ${blobs} ]]; then
			# 缓存结果
			MODEL_BLOB_CACHE[${model_spec}]="${blobs}"
			echo "${blobs}"
			return 0
		fi
	fi

	return 1
}

# 快速检查单文件备份完整性

# 清理完整性检查缓存
clear_integrity_cache() {
	[[ -n ${VERBOSE} ]] && log_verbose "Clearing integrity check cache"
	unset BACKUP_CONTENT_CACHE
	unset MODEL_BLOB_CACHE
	declare -g -A BACKUP_CONTENT_CACHE
	declare -g -A MODEL_BLOB_CACHE
}

# 确保完整性检查缓存已初始化
ensure_cache_initialized() {
	# Initialize cache arrays if they do not exist
	if [[ ! -v BACKUP_CONTENT_CACHE ]] || [[ ! -v MODEL_BLOB_CACHE ]]; then
		declare -g -A BACKUP_CONTENT_CACHE
		declare -g -A MODEL_BLOB_CACHE
		[[ -n ${VERBOSE} ]] && log_verbose "Integrity check cache initialized"
	fi
}

# ==================================================================================
#                           统一完整性验证架构
# ==================================================================================

# 通用完整性验证函数 - 统一所有验证逻辑的入口点
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
		_verify_local_model "${target}" "${use_cache}" "${check_blobs}"
		;;
	"backup")
		_verify_backup_target "${target}" "${model_spec}" "${use_cache}" "${check_blobs}"
		;;
	"backup_file")
		_verify_backup_file "${target}" "${use_cache}"
		;;
	*)
		log_error "Unknown verification type: ${verification_type}"
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
	if [[ ${model_spec} =~ ^(.+):(.+)$ ]]; then
		model_name="${BASH_REMATCH[1]}"
		model_tag="${BASH_REMATCH[2]}"
	else
		log_error "Invalid model spec format: ${model_spec}"
		return 1
	fi

	# 确定manifest文件路径
	local manifest_file
	if [[ ${model_name} == hf.co/* ]]; then
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/${model_name}/${model_tag}"
	elif [[ ${model_name} == *"/"* ]]; then
		local user_name="${model_name%/*}"
		local repo_name="${model_name#*/}"
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/${user_name}/${repo_name}/${model_tag}"
	else
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${model_name}/${model_tag}"
	fi

	# 检查manifest文件是否存在
	[[ ! -f ${manifest_file} ]] && return 1

	# 如果不需要检查blob，只验证manifest存在即可
	[[ ${check_blobs} == "false" ]] && return 0

	# 获取blob文件列表并验证
	local blob_files
	if [[ ${use_cache} == "true" ]]; then
		blob_files=$(get_model_blobs_cached "${model_spec}")
		[[ -z ${blob_files} ]] && return 1

		# 检查每个blob文件
		while IFS= read -r blob_relative_path; do
			[[ -n ${blob_relative_path} && ! -f "${OLLAMA_MODELS_DIR}/${blob_relative_path}" ]] && return 1
		done <<<"${blob_files}"
	else
		blob_files=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}")
		[[ -z ${blob_files} ]] && return 1

		# 检查每个blob文件
		while IFS= read -r blob_file; do
			[[ -n ${blob_file} && ! -f ${blob_file} ]] && return 1
		done <<<"${blob_files}"
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
	if [[ -d ${backup_target} ]]; then
		# Verify directory structure
		if [[ -d "${backup_target}/manifests" ]] && [[ -d "${backup_target}/blobs" ]]; then
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
		else
			log_error "Invalid directory backup structure: ${backup_target}"
			return 1
		fi
	fi

	return 1
}

# 内部函数：验证模型文件完整性

# 内部函数：验证备份文件（业务逻辑完整性）
_verify_backup_file() {
	local backup_file="$1"
	local use_detailed_check="$2"

	[[ ! -f ${backup_file} ]] && return 1

	# 基本tar文件完整性检查
	if ! docker run --rm --entrypoint="" -v "$(dirname "${backup_file}"):/data" hf_downloader:latest sh -c "
        cd /data && tar -tf '$(basename "${backup_file}")' >/dev/null 2>&1
    "; then
		return 1
	fi

	# 如果需要详细检查，执行业务逻辑验证
	[[ ${use_detailed_check} == "true" ]] && validate_model_business_integrity "${backup_file}"
}

# 删除不完整的备份文件
remove_incomplete_backup() {
	local backup_base="$1"
	local backup_suffix="${2-}"

	log_verbose "Deleting incomplete backup: ${backup_base}${backup_suffix}"

	# 删除目录备份
	local backup_dir="${backup_base}${backup_suffix}"
	if [[ -d ${backup_dir} ]]; then
		rm -rf "${backup_dir}"
		log_verbose "Backup directory deleted: ${backup_dir}"
	fi

	# 删除MD5校验文件
	local md5_file="${backup_dir}.md5"
	if [[ -f ${md5_file} ]]; then
		rm -f "${md5_file}"
		log_verbose "MD5 checksum file deleted: ${md5_file}"
	fi

	# 删除备份信息文件
	local info_file="${backup_base}${backup_suffix}_info.txt"
	if [[ -f ${info_file} ]]; then
		rm -f "${info_file}"
		log_verbose "Backup info file deleted: ${info_file}"
	fi
}

# 安全的临时文件创建
create_temp_file() {
	local prefix="${1:-temp}"
	local temp_file
	temp_file=$(mktemp) || {
		log_error "Unable to create temporary file"
		return 1
	}
	echo "${temp_file}"
}

# 创建模型备份目录
create_model_backup_dir() {
	local model_spec="$1"
	local base_backup_dir="$2"
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")
	local model_backup_dir="${base_backup_dir}/${model_safe_name}"

	# 创建备份目录
	if ! mkdir -p "${model_backup_dir}"; then
		log_error "Unable to create backup directory: ${model_backup_dir}"
		return 1
	fi
	echo "${model_backup_dir}"
}

# 生成备份基础路径
get_backup_base_path() {
	local model_spec="$1"
	local backup_dir="$2"
	local suffix="${3-}"
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")
	echo "${backup_dir}/${model_safe_name}${suffix}"
}

# 备份信息和管理函数

# 创建备份信息文件
create_backup_info() {
	local model_spec="$1"
	local backup_base="$2"
	local backup_type="$3"   # "directory", "single" 或 "split"
	local _volume_count="$4" # Reserved for future use
	local backup_extension="${5:-original}"

	local info_file="${backup_base}_info.txt"
	local current_time
	current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")

	# 使用临时文件创建备份信息
	local temp_info
	temp_info=$(mktemp)
	cat >"${temp_info}" <<EOF
================================================================================
                           模型备份信息
================================================================================

备份基本信息:
  模型规格: ${model_spec}
  备份名称: ${model_safe_name}
  备份类型: ${backup_type}
  创建时间: ${current_time}

备份文件信息:
EOF

	# 根据备份类型添加具体的文件信息和MD5
	if [[ ${backup_type} == "directory" ]]; then
		local backup_dir="${backup_base}_${backup_extension}"
		# 对于ollama备份，backup_base已经是完整路径，不需要添加后缀
		if [[ ${backup_extension} == "ollama" ]]; then
			backup_dir="${backup_base}"
		fi
		local backup_size
		backup_size=$(get_file_size_human "${backup_dir}" || echo "未知")
		local md5_file="${backup_dir}.md5"
		local md5_status="有效"

		if [[ ! -f ${md5_file} ]]; then
			md5_status="缺失"
		fi

		cat >>"${temp_info}" <<EOF
  备份方式: 目录复制
  备份目录: $(basename "${backup_dir}")
  备份大小: ${backup_size}
  MD5校验文件: ${md5_status}

文件列表:
EOF

		# 添加文件列表
		if [[ -d ${backup_dir} ]]; then
			find "${backup_dir}" -type f -exec basename {} \; | sort >>"${temp_info}"
		fi

		cat >>"${temp_info}" <<EOF

MD5校验信息:
EOF

		# 添加MD5校验信息
		if [[ -f ${md5_file} ]]; then
			cat "${md5_file}" >>"${temp_info}"
		else
			{
				echo "  MD5校验文件创建失败或不存在"
				echo "  文件路径: ${md5_file}"
				echo "  建议: 重新运行备份以生成MD5校验文件"
			} >>"${temp_info}"
		fi

		cat >>"${temp_info}" <<EOF

恢复命令:
  # 使用omo.sh恢复
  ./omo.sh --restore "$(basename "${backup_dir}")"
  
  # 手动恢复（Ollama模型）
  cp -r "$(basename "${backup_dir}")/manifests/"* "\$OLLAMA_MODELS_DIR/manifests/"
  cp "$(basename "${backup_dir}")/blobs/"* "\$OLLAMA_MODELS_DIR/blobs/"
  

EOF
	else
		log_error "不支持的备份类型: ${backup_type}"
		rm -f "${temp_info}"
		return 1
	fi

	cat >>"${temp_info}" <<EOF
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

备份特性:
   - 直接复制: 极快的备份和恢复速度，无需压缩/解压缩
   - MD5校验: 确保文件完整性和一致性
   - 简化管理: 备份文件可直接访问和检查

使用说明:
- 此备份包含模型的完整文件结构
- 恢复后可直接使用，无需额外处理
- 支持增量备份和差异检查

生成时间: ${current_time}
================================================================================
EOF

	# 直接写入信息文件
	if mv "${temp_info}" "${info_file}"; then
		log_verbose_success "Backup info file created: $(basename "${info_file}")"
	else
		log_error "Unable to write backup info file: ${info_file}"
		rm -f "${temp_info}"
		return 1
	fi
}

# 列出已安装的Ollama模型及详细信息
list_installed_models() {
	log_info "扫描已安装的模型..."

	# 初始化缓存以提高完整性检查性能
	ensure_cache_initialized

	# 检查Ollama模型目录是否存在
	if [[ ! -d ${OLLAMA_MODELS_DIR} ]]; then
		log_error "Ollama模型目录不存在: ${OLLAMA_MODELS_DIR}"
		return 1
	fi

	local manifests_base_dir="${OLLAMA_MODELS_DIR}/manifests"

	# 检查manifests基础目录是否存在
	if [[ ! -d ${manifests_base_dir} ]]; then
		log_warning "未发现已安装的模型"
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
		manifest_files+=("${manifest_file}")
	done < <(find "${manifests_base_dir}" -type f -print0 2>/dev/null || true)

	# 按模型组织 manifest 文件
	declare -A model_manifests

	for manifest_file in "${manifest_files[@]}"; do
		# 提取相对于 manifests_base_dir 的路径
		local relative_path="${manifest_file#"${manifests_base_dir}"/}"

		# 根据路径结构提取模型名和版本
		local model_name=""
		local version=""
		local full_model_path=""

		if [[ ${relative_path} =~ ^registry\.ollama\.ai/library/([^/]+)/(.+)$ ]]; then
			# 传统 Ollama 模型: registry.ollama.ai/library/model_name/version
			model_name="${BASH_REMATCH[1]}"
			version="${BASH_REMATCH[2]}"
			full_model_path="registry.ollama.ai/library/${model_name}"
		elif [[ ${relative_path} =~ ^hf\.co/([^/]+)/([^/]+)/(.+)$ ]]; then
			# HF-GGUF 模型: hf.co/user/repo/version
			local user="${BASH_REMATCH[1]}"
			local repo="${BASH_REMATCH[2]}"
			version="${BASH_REMATCH[3]}"
			model_name="hf.co/${user}/${repo}"
			full_model_path="hf.co/${user}/${repo}"
		else
			# 其他未知格式，尝试通用解析
			local path_parts
			IFS='/' read -ra path_parts <<<"${relative_path}"
			if [[ ${#path_parts[@]} -ge 2 ]]; then
				version="${path_parts[-1]}"
				unset 'path_parts[-1]'
				model_name=$(
					IFS='/'
					echo "${path_parts[*]}"
				)
				full_model_path="${model_name}"
			else
				continue
			fi
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

		echo "📦 模型: ${model_name}"
		[[ ${VERBOSE} == "true" ]] && echo "   ├─ 位置: ${model_dir}"

		local version_count=0

		# 处理所有版本
		IFS=';;' read -ra entries <<<"${model_data}"
		for entry in "${entries[@]}"; do
			IFS='|' read -r manifest_file version _ <<<"${entry}"

			if [[ ! -f ${manifest_file} ]]; then
				continue
			fi

			# 检查模型完整性（使用缓存优化）
			local integrity_status=""
			local check_model_spec="${model_name}:${version}"
			if verify_integrity "model" "${check_model_spec}" "use_cache:true,check_blobs:true"; then
				integrity_status=" ✓(完整)"
			else
				integrity_status=" ⚠️(不完整)"
			fi

			echo "   ├─ 版本: ${version}${integrity_status}"

			# 读取manifest文件获取blob信息
			if [[ ${VERBOSE} == "true" ]] && [[ -f ${manifest_file} ]]; then
				local manifest_content
				if manifest_content=$(cat "${manifest_file}" 2>/dev/null); then
					# manifest是JSON格式，解析获取所有层的大小
					local total_model_size=0
					local blob_count=0
					local model_type="未知"

					# 尝试从JSON中提取模型类型
					if echo "${manifest_content}" | grep -q "application/vnd.ollama.image.model"; then
						model_type="Ollama模型"
					fi

					# 提取config大小
					local config_size
					if config_size=$(echo "${manifest_content}" | grep -o '"config":{[^}]*"size":[0-9]*' | grep -o '[0-9]*$' 2>/dev/null); then
						total_model_size=$((total_model_size + config_size))
						blob_count=$((blob_count + 1))
					fi

					# 提取所有layers的大小
					local layer_sizes
					if layer_sizes=$(echo "${manifest_content}" | grep -o '"size":[0-9]*' | grep -o '[0-9]*' 2>/dev/null); then
						while IFS= read -r size; do
							if [[ -n ${size} && ${size} -gt 0 ]]; then
								total_model_size=$((total_model_size + size))
								blob_count=$((blob_count + 1))
							fi
						done <<<"${layer_sizes}"
					fi

					# 格式化大小显示
					local human_size
					human_size=$(format_bytes "${total_model_size}")

					echo "   ├─ 大小: ${human_size}"

					total_size=$((total_size + total_model_size))
				fi
			fi

			version_count=$((version_count + 1))
		done

		echo "   └─ 版本数量: ${version_count}"
		echo ""
		model_count=$((model_count + 1))
		total_version_count=$((total_version_count + version_count))
	done

	# 显示统计信息
	echo "=================================================================================="
	echo "统计信息:"
	echo "  📊 总模型数: ${model_count}"
	echo "  🔢 总版本数: ${total_version_count}"

	# 格式化总大小
	if [[ ${VERBOSE} == "true" ]]; then
		local total_human_size
		total_human_size=$(format_bytes "${total_size}")
		echo "  💾 大小: ${total_human_size}"
	fi
	echo "  📁 目录: ${OLLAMA_MODELS_DIR}"

	# 显示磁盘使用情况
	local disk_usage
	if disk_usage=$(du -sh "${OLLAMA_MODELS_DIR}" 2>/dev/null || true); then
		local disk_size
		disk_size=$(echo "${disk_usage}" | cut -f1)
		echo "  🗄️ Disk usage: ${disk_size}"
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
	if ! parse_model_spec "${model_spec}" model_name model_version; then
		return 1
	fi

	log_verbose "备份模型: ${model_name}:${model_version}"
	local model_spec="${model_name}:${model_version}"
	if ! verify_integrity "model" "${model_spec}" "use_cache:true,check_blobs:true"; then
		log_error "本地模型不完整，取消备份操作"
		return 1
	fi

	# 创建备份目录和生成路径
	local model_backup_dir
	model_backup_dir=$(create_model_backup_dir "${model_spec}" "${backup_dir}") || return 1
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")
	local backup_model_dir="${model_backup_dir}/${model_safe_name}"

	# 检查是否已存在备份目录
	if [[ -d ${backup_model_dir} ]]; then
		log_success "模型备份已存在"
		return 0
	fi

	# 确定manifest文件路径
	local manifest_file
	if [[ ${model_name} == hf.co/* ]]; then
		# HuggingFace GGUF模型，如 hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/${model_name}/${model_version}"
	elif [[ ${model_name} == *"/"* ]]; then
		# 用户分享的模型，如 lrs33/bce-embedding-base_v1
		local user_name="${model_name%/*}"
		local repo_name="${model_name#*/}"
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/${user_name}/${repo_name}/${model_version}"
	else
		# 官方模型
		manifest_file="${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${model_name}/${model_version}"
	fi

	# 检查manifest文件是否存在
	if [[ ! -f ${manifest_file} ]]; then
		log_error "模型不存在: ${model_spec}"
		return 1
	fi

	# 获取blob文件路径
	local blob_files
	blob_files=$(get_model_blob_paths "${manifest_file}" "${OLLAMA_MODELS_DIR}")

	if [[ -z ${blob_files} ]]; then
		log_error "未找到模型相关的blob文件"
		return 1
	fi

	# 创建备份目录结构
	mkdir -p "${backup_model_dir}/manifests"
	mkdir -p "${backup_model_dir}/blobs"

	log_verbose "开始复制文件..."

	# 复制manifest文件
	local manifest_rel_path="${manifest_file#"${OLLAMA_MODELS_DIR}"/manifests/}"
	local manifest_backup_dir
	manifest_backup_dir="${backup_model_dir}/manifests/$(dirname "${manifest_rel_path}")"
	mkdir -p "${manifest_backup_dir}"
	if ! cp "${manifest_file}" "${manifest_backup_dir}/"; then
		log_error "复制manifest文件失败: ${manifest_file}"
		rm -rf "${backup_model_dir}"
		return 1
	fi

	# 复制blob文件
	while IFS= read -r blob_file; do
		if [[ -f ${blob_file} ]]; then
			local blob_name
			blob_name=$(basename "${blob_file}")
			if ! cp "${blob_file}" "${backup_model_dir}/blobs/"; then
				log_error "复制blob文件失败: ${blob_file}"
				rm -rf "${backup_model_dir}"
				return 1
			fi
		fi
	done <<<"${blob_files}"

	# 计算MD5校验
	log_verbose "计算MD5校验值..."
	local md5_file="${backup_model_dir}.md5"
	if calculate_directory_md5 "${backup_model_dir}" "${md5_file}"; then
		log_verbose "MD5校验文件已创建: ${md5_file}"
	else
		log_warning "MD5校验文件创建失败"
	fi

	# 创建备份信息文件
	create_backup_info "${model_spec}" "${backup_model_dir}" "directory" 1 "ollama"

	log_verbose_success "模型备份完成: ${model_spec}"
	return 0
}

# 智能删除模型（自动识别模型类型）
remove_model_smart() {
	local model_input="$1"
	local force_delete="${2:-false}"

	log_info "删除模型: ${model_input}"

	# 检查输入格式，判断是什么类型的模型
	if [[ ${model_input} =~ ^([^:]+):(.+)$ ]]; then
		local model_name="${BASH_REMATCH[1]}"
		local model_tag_or_quant="${BASH_REMATCH[2]}"

		# 先检查是否是Ollama模型（直接格式：model:tag）
		if check_ollama_model "${model_name}" "${model_tag_or_quant}"; then
			if remove_ollama_model "${model_input}" "${force_delete}"; then
				return 0
			else
				return 1
			fi
		fi

		# Model not found
		log_error "Model not found or unsupported format: ${model_input}"
		return 1

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

	log_info "恢复模型: $(basename "${backup_dir}")"

	# 检查备份目录是否存在
	if [[ ! -d ${backup_dir} ]]; then
		log_error "备份文件不存在: ${backup_dir}"
		return 1
	fi

	# 检查备份目录结构
	if [[ ! -d "${backup_dir}/manifests" ]] || [[ ! -d "${backup_dir}/blobs" ]]; then
		log_error "备份文件损坏或格式错误"
		return 1
	fi

	# MD5校验
	local md5_file="${backup_dir}.md5"
	if [[ -f ${md5_file} ]]; then
		log_info "校验备份文件..."
		if verify_directory_md5 "${backup_dir}" "${md5_file}"; then
			log_verbose_success "MD5校验通过"
		else
			log_error "备份文件校验失败，可能已损坏"
			if [[ ${force_restore} != "true" ]]; then
				return 1
			fi
			log_warning "强制恢复模式，继续操作..."
		fi
	else
		log_warning "跳过完整性校验"
	fi

	# 检查是否需要强制覆盖
	if [[ ${force_restore} != "true" ]]; then
		log_info "检查模型冲突..."
		local conflicts_found=false

		# 检查manifests冲突
		if find "${backup_dir}/manifests" -type f 2>/dev/null | while read -r manifest_file; do
			local rel_path="${manifest_file#"${backup_dir}"/manifests/}"
			local target_file="${OLLAMA_MODELS_DIR}/manifests/${rel_path}"
			if [[ -f ${target_file} ]]; then
				echo "conflict"
				break
			fi
		done | grep -q "conflict"; then
			conflicts_found=true
		fi

		# 检查blobs冲突
		if find "${backup_dir}/blobs" -type f 2>/dev/null | while read -r blob_file; do
			local blob_name
			blob_name=$(basename "${blob_file}")
			local target_file="${OLLAMA_MODELS_DIR}/blobs/${blob_name}"
			if [[ -f ${target_file} ]]; then
				echo "conflict"
				break
			fi
		done | grep -q "conflict"; then
			conflicts_found=true
		fi

		if [[ ${conflicts_found} == "true" ]]; then
			log_error "检测到文件冲突，使用 --force 强制覆盖"
			return 1
		fi
	fi

	# 创建Ollama目录并设置权限
	if ! mkdir -p "${OLLAMA_MODELS_DIR}/manifests" "${OLLAMA_MODELS_DIR}/blobs"; then
		log_error "Unable to创建Ollama目录"
		return 1
	fi

	# 复制manifests
	log_verbose "恢复模型信息..."
	if ! cp -r "${backup_dir}/manifests/"* "${OLLAMA_MODELS_DIR}/manifests/"; then
		log_error "manifest文件复制失败"
		return 1
	fi

	# 复制blobs
	log_verbose "恢复模型数据..."
	if ! cp "${backup_dir}/blobs/"* "${OLLAMA_MODELS_DIR}/blobs/"; then
		log_error "blob文件复制失败"
		return 1
	fi

	log_verbose_success "模型恢复完成"
	return 0
}

# 自动识别备份类型并恢复
# 批量备份模型（根据models.list文件）
backup_models_from_list() {
	local models_file="$1"
	local backup_dir="$2"

	log_verbose "批量备份模型..."
	log_verbose "模型列表文件: ${models_file}"
	log_verbose "备份目录: ${backup_dir}"

	# 解析模型列表
	local models=()
	parse_models_list "${models_file}" models

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "没有找到任何模型进行备份"
		return 1
	fi

	# 创建备份目录
	mkdir -p "${backup_dir}"

	local total_models=${#models[@]}
	local processed=0
	local success=0
	local failed=0

	log_verbose "共找到 ${total_models} 个模型进行备份"

	# 预先初始化Ollama缓存，避免每个模型都重新初始化
	local has_ollama_models=false
	for model in "${models[@]}"; do
		if [[ ${model} =~ ^ollama: ]] || [[ ${model} =~ ^hf-gguf: ]]; then
			has_ollama_models=true
			break
		fi
	done

	if [[ ${has_ollama_models} == "true" ]]; then
		log_verbose "检测到Ollama模型，预先初始化模型缓存..."
		if ! init_ollama_cache; then
			log_error "Ollama缓存初始化失败，可能影响备份性能"
		fi
	fi

	for model in "${models[@]}"; do
		((processed++))
		log_info "备份模型 [${processed}/${total_models}]: ${model}"

		# 解析模型条目
		if [[ ${model} =~ ^ollama:([^:]+):(.+)$ ]]; then
			local model_name="${BASH_REMATCH[1]}"
			local model_tag="${BASH_REMATCH[2]}"
			local model_spec="${model_name}:${model_tag}"

			# 检查模型是否存在
			if check_ollama_model "${model_name}" "${model_tag}"; then
				if backup_ollama_model "${model_spec}" "${backup_dir}"; then
					((success++))
				else
					((failed++))
				fi
			else
				((failed++))
			fi

		elif [[ ${model} =~ ^hf-gguf:(.+)$ ]]; then
			local model_full_name="${BASH_REMATCH[1]}"

			# 解析HuggingFace GGUF模型名称
			if [[ ${model_full_name} =~ ^(.+):(.+)$ ]]; then
				local model_name="${BASH_REMATCH[1]}"
				local model_tag="${BASH_REMATCH[2]}"
			else
				local model_name="${model_full_name}"
				local model_tag="latest"
			fi

			local model_spec="${model_name}:${model_tag}"

			# 检查HF GGUF模型是否存在
			if check_hf_gguf_model "${model_name}" "${model_tag}"; then
				if backup_ollama_model "${model_spec}" "${backup_dir}"; then
					((success++))
				else
					((failed++))
				fi
			else
				((failed++))
			fi

		else
			log_error "无效的模型条目格式: ${model}"
			((failed++))
		fi

		echo "" # 添加空行分隔
	done

	# 显示备份总结
	log_verbose_success "批量备份完成 (${success}/${total_models})"
	if [[ ${failed} -gt 0 ]]; then
		log_warning "备份失败: ${failed}"
		return 1
	fi

	# 显示备份目录信息
	if [[ ${VERBOSE} == "true" ]] && [[ -d ${backup_dir} ]]; then
		# 只统计顶级模型目录，排除子目录
		local backup_count
		backup_count=$(find "${backup_dir}" -maxdepth 1 -type d ! -path "${backup_dir}" | wc -l)
		local total_size
		total_size=$(du -sh "${backup_dir}" 2>/dev/null | cut -f1)
		log_info "备份目录下共有: ${backup_count} 个模型，总大小: ${total_size}"
	fi

	# 清理完整性检查缓存
	clear_integrity_cache

	if [[ ${failed} -eq 0 ]]; then
		log_verbose_success "全部模型备份完成"
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

	log_verbose "Batch deleting models..."
	log_verbose "Model list file: ${models_file}"
	log_info "Force delete mode: ${force_delete}"

	# 解析模型列表
	local models=()
	parse_models_list "${models_file}" models

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "No models found for deletion"
		return 1
	fi

	local total_models=${#models[@]}
	local processed=0
	local success=0
	local failed=0

	log_verbose "共找到 ${total_models} 个模型进行删除"

	# 如果不是强制删除，显示要删除的模型列表并请求确认
	if [[ ${force_delete} != "true" ]]; then
		log_warning "The following models will be deleted:"
		for model in "${models[@]}"; do
			if [[ ${model} =~ ^ollama:([^:]+):(.+)$ ]]; then
				local model_name="${BASH_REMATCH[1]}"
				local model_tag="${BASH_REMATCH[2]}"
				echo "  - Ollama模型: ${model_name}:${model_tag}"
			elif [[ ${model} =~ ^hf-gguf:(.+)$ ]]; then
				local model_full_name="${BASH_REMATCH[1]}"
				echo "  - HuggingFace GGUF模型: ${model_full_name}"
			fi
		done
		echo ""
		echo -n "Confirm deletion of all these models? [y/N]: "
		read -r confirm
		if [[ ${confirm} != "y" && ${confirm} != "Y" ]]; then
			log_info "Cancelled batch delete operation"
			return 2 # 特殊退出码表示用户取消
		fi
		echo ""
	fi

	for model in "${models[@]}"; do
		((processed++))
		log_info "Deleting model [${processed}/${total_models}]: ${model}"

		# 解析模型条目
		if [[ ${model} =~ ^ollama:([^:]+):(.+)$ ]]; then
			local model_name="${BASH_REMATCH[1]}"
			local model_tag="${BASH_REMATCH[2]}"
			local model_spec="${model_name}:${model_tag}"

			log_verbose "删除Ollama模型: ${model_spec}"

			if remove_ollama_model "${model_spec}" "true"; then
				((success++))
				log_verbose_success "Ollama模型删除成功: ${model_spec}"
			else
				((failed++))
				log_error "Ollama模型删除失败: ${model_spec}"
			fi

		elif [[ ${model} =~ ^hf-gguf:(.+)$ ]]; then
			local model_full_name="${BASH_REMATCH[1]}"

			# 解析HuggingFace GGUF模型名称
			if [[ ${model_full_name} =~ ^(.+):(.+)$ ]]; then
				local model_name="${BASH_REMATCH[1]}"
				local model_tag="${BASH_REMATCH[2]}"
			else
				local model_name="${model_full_name}"
				local model_tag="latest"
			fi

			local model_spec="${model_name}:${model_tag}"
			log_verbose "删除HuggingFace GGUF模型: ${model_spec}"

			if remove_ollama_model "${model_spec}" "true"; then
				((success++))
				log_verbose_success "HuggingFace GGUF模型删除成功: ${model_spec}"
			else
				((failed++))
				log_error "HuggingFace GGUF模型删除失败: ${model_spec}"
			fi

		else
			log_error "无效的模型条目格式: ${model}"
			((failed++))
		fi

		echo "" # 添加空行分隔
	done

	# 显示删除总结
	log_verbose_success "批量删除完成 (${success}/${total_models})"
	if [[ ${failed} -gt 0 ]]; then
		log_warning "删除失败: ${failed}"
	fi

	if [[ ${failed} -eq 0 ]]; then
		log_verbose_success "全部模型删除完成"
		return 0
	else
		log_warning "部分模型删除失败"
		return 1
	fi
}

# 检查Ollama中是否存在指定模型

# 检查Ollama中是否存在指定模型（通用函数）

# 检查Ollama模型在backups目录中是否有备份
check_ollama_backup_exists() {
	local model_name="$1"
	local model_tag="$2"

	# 使用与get_safe_model_name相同的逻辑生成安全名称
	local model_spec="${model_name}:${model_tag}"
	local model_safe_name
	model_safe_name=$(get_safe_model_name "${model_spec}")
	local backup_parent_dir="${BACKUP_OUTPUT_DIR}/${model_safe_name}"
	local backup_model_dir="${backup_parent_dir}/${model_safe_name}"

	# 检查备份目录是否存在
	if [[ -d ${backup_model_dir} ]]; then
		# 检查是否有有效的目录备份结构
		if [[ -d "${backup_model_dir}/manifests" ]] && [[ -d "${backup_model_dir}/blobs" ]]; then
			echo "${backup_parent_dir}"
			return 0
		fi
	fi

	return 1
}

# 尝试从备份恢复Ollama模型
try_restore_ollama_from_backup() {
	local model_name="$1"
	local model_tag="$2"

	log_verbose "检查Ollama模型备份: ${model_name}:${model_tag}"

	local backup_dir
	if backup_dir=$(check_ollama_backup_exists "${model_name}" "${model_tag}"); then
		log_verbose_success "找到Ollama模型备份: ${backup_dir}"

		# 使用与get_safe_model_name相同的逻辑生成安全名称
		local model_spec="${model_name}:${model_tag}"
		local model_safe_name
		model_safe_name=$(get_safe_model_name "${model_spec}")

		# 查找备份目录（新的直接复制格式）
		local backup_model_dir="${backup_dir}/${model_safe_name}"
		if [[ -d ${backup_model_dir} ]]; then
			# 恢复模型
			log_info "正在从备份恢复模型..."
			if restore_ollama_model "${backup_model_dir}" "true"; then
				log_success "从备份成功恢复模型: ${model_name}:${model_tag}"
				return 0
			else
				log_warning "从备份恢复模型失败，将尝试重新下载"
				return 1
			fi
		else
			log_error "未找到有效的备份目录: ${backup_model_dir}"
			return 1
		fi
	else
		log_verbose "未找到Ollama模型备份"
		return 1
	fi
}

# 处理单个模型
process_model() {
	local model_entry="$1"
	local force_download="$2"
	local check_only="$3"

	# 解析模型条目
	local -A model_info
	if ! parse_model_entry "${model_entry}" model_info; then
		log_error "无效的模型条目格式: ${model_entry}"
		return 1
	fi

	log_verbose "处理模型: ${model_info[display]}"

	# 检查模型是否存在
	if [[ ${force_download} != "true" ]] && check_model_exists model_info; then
		log_success "模型已存在"
		return 0
	fi

	# 模型不存在或强制下载
	if [[ ${check_only} == "true" ]]; then
		log_warning "需要下载: ${model_info[display]}"
		return 0
	fi

	# 尝试从备份恢复
	if try_restore_model model_info; then
		log_success "从备份恢复成功"
		# 清除缓存，强制重新检查
		OLLAMA_CACHE_INITIALIZED="false"
		OLLAMA_MODELS_CACHE=""
		return 0
	fi

	# 执行下载
	if download_model model_info; then
		log_success "模型下载完成"
		# 清除缓存，强制重新检查
		OLLAMA_CACHE_INITIALIZED="false"
		OLLAMA_MODELS_CACHE=""
		return 0
	else
		log_error "模型处理失败: ${model_info[display]}"
		return 1
	fi
}

# 主函数
main() {
	# 获取主机时区
	HOST_TIMEZONE=$(get_host_timezone)

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
			CHECK_ONLY="false" # 强制下载时应该实际执行下载
			shift
			;;
		--force)
			FORCE_RESTORE="true"
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
			log_error "未知参数: $1"
			show_help
			exit 1
			;;
		esac
	done

	# 显示当前任务（简化）
	local current_task=""
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
	else
		current_task="Install/download models"
	fi

	log_info "🚀 Task: ${current_task}"
	log_verbose "Model list file: ${MODELS_FILE}"
	log_verbose "Ollama directory: ${OLLAMA_MODELS_DIR}"
	[[ -n ${BACKUP_OUTPUT_DIR} ]] && log_verbose "Backup directory: ${BACKUP_OUTPUT_DIR}"

	# 初始化路径
	init_paths

	# 确保Ollama目录存在
	if [[ ! -d ${OLLAMA_MODELS_DIR} ]]; then
		log_verbose "创建Ollama模型目录..."
		if ! mkdir -p "${OLLAMA_MODELS_DIR}" 2>/dev/null; then
			log_warning "无法创建Ollama模型目录，某些功能可能不可用"
		fi
	fi

	# 执行特定任务并退出
	if [[ -n ${BACKUP_MODEL} ]]; then
		execute_task "model backup" backup_single_model "${BACKUP_MODEL}" "${BACKUP_OUTPUT_DIR}"
	elif [[ ${BACKUP_ALL} == "true" ]]; then
		execute_task "batch backup" backup_models_from_list "${MODELS_FILE}" "${BACKUP_OUTPUT_DIR}"
	elif [[ ${LIST_MODELS} == "true" ]]; then
		execute_task "model list" list_installed_models
	elif [[ ${GENERATE_COMPOSE} == "true" ]]; then
		execute_task "Docker configuration generation" generate_docker_compose
	elif [[ -n ${RESTORE_FILE} ]]; then
		execute_task "model restore" restore_model "${RESTORE_FILE}" "${FORCE_RESTORE}"
	elif [[ -n ${REMOVE_MODEL} ]]; then
		execute_task "model removal" remove_model_smart "${REMOVE_MODEL}" "${FORCE_RESTORE}"
	elif [[ ${REMOVE_ALL} == "true" ]]; then
		execute_task "batch delete" remove_models_from_list "${MODELS_FILE}" "${FORCE_RESTORE}"
	fi

	# 检查依赖
	check_dependencies

	# 解析模型列表
	local models=()
	parse_models_list "${MODELS_FILE}" models

	if [[ ${#models[@]} -eq 0 ]]; then
		log_warning "没有找到任何模型，退出"
		exit 0
	fi

	# HuggingFace GGUF models are downloaded directly through Ollama, no Docker images needed

	# 处理每个模型
	local total_models=${#models[@]}
	local processed=0
	local failed=0

	for model in "${models[@]}"; do
		processed=$((processed + 1))
		log_verbose "处理模型 [${processed}/${total_models}]: ${model}"

		# 处理单个模型错误，不中断整个流程
		if ! process_model "${model}" "${FORCE_DOWNLOAD}" "${CHECK_ONLY}"; then
			failed=$((failed + 1))
		fi
	done

	# 显示总结
	log_info "=== 处理完成 ==="
	log_info "总模型数: ${total_models}"
	log_info "已处理: ${processed}"
	if [[ ${failed} -gt 0 ]]; then
		log_warning "失败: ${failed}"
	else
		log_success "全部成功完成"
	fi

	if [[ ${CHECK_ONLY} == "true" ]]; then
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
	local backup_file
	backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
	cp "${output_file}" "${backup_file}"
	log_info "已备份所有文件: ${backup_file}"

	# 使用Python脚本更新CUSTOM_MODELS环境变量
	if grep -q "CUSTOM_MODELS=" "${output_file}"; then
		# 使用Python来精确处理YAML文件中的多行CUSTOM_MODELS
		# 使用临时文件存储多行内容
		local temp_models_file
		temp_models_file=$(mktemp)
		echo "${custom_models}" >"${temp_models_file}"

		# 使用纯shell实现替换功能
		update_docker_compose_models() {
			local file_path="$1"
			local models_file="$2"
			local default_model="$3"

			# 读取新的模型配置
			local new_models
			new_models=$(cat "${models_file}")

			# 创建临时文件
			local temp_file
			temp_file=$(mktemp)

			# 简单替换CUSTOM_MODELS行
			if grep -q 'CUSTOM_MODELS=' "${file_path}"; then
				# 使用sed进行简单的行替换
				sed "s|CUSTOM_MODELS=.*|CUSTOM_MODELS=${new_models}\"|" "${file_path}" >"${temp_file}"
				cp "${temp_file}" "${file_path}"
			fi

			# 处理DEFAULT_MODEL替换
			sed -E "s|(^[[:space:]]*-[[:space:]]*DEFAULT_MODEL=)[^[:space:]#]*(.*)|\\1${default_model}  # 自动设置为models.list第一个模型|" "${file_path}" >"${temp_file}"
			cp "${temp_file}" "${file_path}"

			# 清理临时文件
			rm -f "${temp_file}"
			return 0
		}

		if update_docker_compose_models "${output_file}" "${temp_models_file}" "${default_model}"; then
			echo "SUCCESS"
		else
			echo "ERROR: Failed to update docker-compose.yaml"
			exit 1
		fi

		# 清理临时文件
		rm -f "${temp_models_file}"

		log_success "成功更新docker-compose.yaml中的CUSTOM_MODELS配置"
		log_info "更新内容: ${custom_models}"
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
	if [[ ! -f ${models_file} ]]; then
		log_error "模型列表文件不存在: ${models_file}"
		return 1
	fi

	# 检查是否已存在docker-compose.yaml文件
	if [[ -f ${output_file} ]]; then
		log_info "检测到现有docker-compose.yaml文件，将更新CUSTOM_MODELS配置"

		# 生成CUSTOM_MODELS内容
		local custom_models_content
		custom_models_content=$(generate_custom_models_list "${models_file}")

		if [[ -z ${custom_models_content} ]]; then
			log_warning "未找到激活的模型，将生成默认配置"
			custom_models_content="-all"
		fi

		# 检查是否有可用的模型
		if [[ ${custom_models_content} == "-all" ]]; then
			log_error "错误: models.list 中没有找到可用的模型配置"
			log_error "请确保 models.list 中至少有一个未被注释的模型配置"
			return 1
		fi

		# 自动检测默认模型
		local default_model
		default_model=$(detect_default_model "${models_file}")

		[[ -n ${VERBOSE} ]] && log_info "Generated CUSTOM_MODELS content"
		[[ -n ${VERBOSE} ]] && log_info "Detected default model: ${default_model}"

		# 更新现有文件
		update_existing_compose "${output_file}" "${custom_models_content}" "${default_model}"
	else
		log_info "Generating docker-compose.yaml based on model list: ${models_file}"

		# 生成CUSTOM_MODELS内容
		local custom_models_content
		custom_models_content=$(generate_custom_models_list "${models_file}")

		if [[ -z ${custom_models_content} ]]; then
			log_warning "未找到激活的模型，将生成默认配置"
			custom_models_content="-all"
		fi

		# 自动检测默认模型
		local default_model
		default_model=$(detect_default_model "${models_file}")

		# 检查是否有可用的模型 (CUSTOM_MODELS只有-all说明没有激活的模型)
		if [[ ${custom_models_content} == "-all" ]]; then
			log_error "错误: models.list 中没有找到可用的模型配置"
			log_error "请确保 models.list 中至少有一个未被注释的模型配置"
			return 1
		fi

		[[ -n ${VERBOSE} ]] && log_info "Generated CUSTOM_MODELS content"
		[[ -n ${VERBOSE} ]] && log_info "Detected default model: ${default_model}"

		# 生成docker-compose.yaml内容
		generate_compose_content "${output_file}" "${custom_models_content}" "${default_model}"
	fi
}

# 生成CUSTOM_MODELS列表
generate_custom_models_list() {
	local models_file="$1"
	local custom_models_entries=()

	# 添加 -all 作为第一个条目（隐藏所有默认模型）
	custom_models_entries+=("-all")

	while IFS= read -r line || [[ -n ${line} ]]; do
		# 跳过注释行和空行
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		[[ -z ${line// /} ]] && continue

		# 解析行内容
		read -r model_type model_spec _ <<<"${line}"

		case "${model_type}" in
		"ollama")
			if [[ -n ${model_spec} ]]; then
				local alias
				alias=$(generate_model_alias "${model_spec}" "ollama")
				local entry="+${model_spec}@OpenAI=${alias}"
				custom_models_entries+=("${entry}")
			fi
			;;
		"hf-gguf")
			if [[ -n ${model_spec} ]]; then
				local alias
				alias=$(generate_model_alias "${model_spec}" "hf-gguf")
				local entry="+${model_spec}@OpenAI=${alias}"
				custom_models_entries+=("${entry}")
			fi
			;;
		*)
			# 忽略未知的模型类型
			;;
		esac
	done <"${models_file}"

	# 输出CUSTOM_MODELS格式
	if [[ ${#custom_models_entries[@]} -gt 1 ]]; then
		printf '%s' "${custom_models_entries[0]}"
		for ((i = 1; i < ${#custom_models_entries[@]}; i++)); do
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

# 检测默认模型
detect_default_model() {
	local models_file="$1"
	local first_active_model=""

	while IFS= read -r line || [[ -n ${line} ]]; do
		# 跳过注释行和空行
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		[[ -z ${line// /} ]] && continue

		# 解析行内容
		read -r model_type model_spec _ <<<"${line}"

		# 找到第一个激活的模型并生成其别名
		if [[ -n ${model_spec} && -z ${first_active_model} ]]; then
			case "${model_type}" in
			"ollama")
				first_active_model=$(generate_model_alias "${model_spec}" "ollama")
				break
				;;
			"hf-gguf")
				first_active_model=$(generate_model_alias "${model_spec}" "hf-gguf")
				break
				;;
			*)
				# 忽略未知的模型类型
				;;
			esac
		fi
	done <"${models_file}"

	# 如果没有找到激活的模型，使用默认值
	echo "${first_active_model:-qwen3-14b}"
}

# 生成docker-compose.yaml文件内容
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

	local cuda_devices
	cuda_devices=$(detect_gpus)

	# 获取主机时区
	local host_timezone
	host_timezone=$(get_host_timezone)
	[[ -z ${host_timezone} ]] && host_timezone="UTC"

	# 如果文件已存在，创建备份
	if [[ -f ${output_file} ]]; then
		local backup_file
		backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
		cp "${output_file}" "${backup_file}"
		log_info "已备份所有文件: ${backup_file}"
	fi

	# 生成docker-compose.yaml内容
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
      # Ollama优化配置
      - CUDA_VISIBLE_DEVICES=${cuda_devices} # 自动检测并使用所有可用GPU
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
      - VITE_CUSTOM_API_BASE_URL=http://YOUR_SERVER_IP:3001/v1  # 修改为你的服务器IP地址
      - VITE_CUSTOM_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # 修改为你的API密钥
      - VITE_CUSTOM_API_MODEL=${default_model}  # 自动设置为models.list第一个模型
      - ACCESS_USERNAME=admin  # 修改为你的用户名
      - ACCESS_PASSWORD=xxxxxxxxxxxxxxxxxxxxxx  # 修改为你的密码
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
      - OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # 修改为你的OpenAI API密钥
      - BASE_URL=http://one-api:3001
      - PROXY_URL=
      - "CUSTOM_MODELS=${custom_models}"
      - DEFAULT_MODEL=${default_model}  # 自动设置为models.list第一个模型
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

	log_success "成功生成docker-compose.yaml文件: ${output_file}"
	log_info "包含模型配置: ${custom_models}"
	log_info "默认模型: ${default_model}"
	log_info "检测到GPU设备: ${cuda_devices}"
	echo ""
	log_info "⚠️  重要提示: 生成的配置文件中包含占位符，请根据以下说明修改："
	log_info "== 必须修改的配置 =="
	log_info "1. VITE_CUSTOM_API_BASE_URL: 将 YOUR_SERVER_IP 替换为实际服务器IP地址"
	log_info "2. VITE_CUSTOM_API_KEY: 替换为 one-api 中的有效API密钥"
	log_info "3. ACCESS_USERNAME/ACCESS_PASSWORD: 设置 prompt-optimizer 的登录凭据"
	log_info "4. OPENAI_API_KEY: 替换为 one-api 中的有效API密钥"
	log_info "5. CODE: 设置 ChatGPT-Next-Web 的访问密码"
	log_info "6. VITE_CUSTOM_API_MODEL/DEFAULT_MODEL: 已自动设置为 ${default_model}，可根据需要修改"
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
	log_info "配置完成后运行: docker compose up -d 来启动服务"

	return 0
}

# 只有在直接运行脚本时才执行main函数
if [[ ${BASH_SOURCE[0]:-$0} == "${0}" ]]; then
	main "$@"
fi
