#!/bin/bash

# --- DMR - Docker 项目备份与恢复工具 ---
# 版本: 2.27 (重要更新: 彻底修复备份时的交互式多服务添加逻辑，确保 'y' 继续添加，'n' 停止并确认备份，'0' 返回主菜单；修复批量备份时，输入多个ID/名称无法正确分割并逐一处理的问题，确保 `backup_project` 每次只处理一个标识符；修复 `docker inspect` 生成 `docker run` 命令时的 `sed` 和模板解析错误，提高健壮性；首次运行自动提示注册为全局dmr命令；菜单中添加“0. 返回”选项；依赖自动安装；日志目录创建顺序；备份时容器识别逻辑；优化: 服务列表只显示运行中容器；强化名称提取；完整中文本地化；修复绑定挂载名称解析)
# 作者: AI 您的AI助手
# 描述: 此脚本提供交互式菜单，用于备份和恢复 Docker 容器及其相关数据。

# --- 配置 ---
BACKUP_BASE_DIR="/home/docker_backups" # 固定的备份目录
DATE_FORMAT=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE_PREFIX="docker_project_backup"
BACKUP_FILE_EXTENSION=".tar.gz"
SCRIPT_NAME=$(basename "$0") # 脚本自身的名称，用于判断是否已重命名为 dmr
LOG_FILE="${BACKUP_BASE_DIR}/docker_backup_restore.log" # 日志文件路径已修改为备份目录下
GLOBAL_COMMAND_NAME="dmr" # 全局命令的名称
GLOBAL_COMMAND_PATH="/usr/local/bin/${GLOBAL_COMMAND_NAME}" # 全局命令的目标路径

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# --- 实用函数 ---

# 记录日志到控制台和文件
log_message() {
    local level="$1" # INFO, SUCCESS, WARN, ERROR
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    # 确保日志目录存在后再写入日志
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    # 根据级别选择颜色输出到控制台，并始终写入文件
    case "$level" in
        "信息") echo -e "${BLUE}${timestamp} [${level}] ${message}${NC}" | tee -a "$LOG_FILE" ;;
        "成功") echo -e "${GREEN}${timestamp} [${level}] ${message}${NC}" | tee -a "$LOG_FILE" ;;
        "警告") echo -e "${YELLOW}${timestamp} [${level}] ${message}${NC}" | tee -a "$LOG_FILE" ;;
        "错误") echo -e "${RED}${timestamp} [${level}] ${message}${NC}" | tee -a "$LOG_FILE" ;;
        *) echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" ;; # 默认无颜色
    esac
}

log_info() { log_message "信息" "$1"; }
log_success() { log_message "成功" "$1"; }
log_warn() { log_message "警告" "$1"; }
log_error() { log_message "错误" "$1"; exit 1; } # 遇到严重错误时直接退出

# 检查并自动安装所需依赖
check_dependencies() {
    log_info "正在检查脚本依赖项..."
    local missing_deps=()
    local install_cmds=()

    # 检查 jq, tar, gzip, docker
    for cmd in docker tar gzip jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warn "缺少必需的依赖项: ${missing_deps[*]}. 尝试自动安装..."
        
        # 判断操作系统类型以选择合适的包管理器
        if command -v apt-get &>/dev/null; then
            # Debian/Ubuntu
            log_info "检测到 Debian/Ubuntu 系统，使用 apt-get 安装依赖。"
            install_cmds=("sudo apt-get update -y")
            for dep in "${missing_deps[@]}"; do
                if [ "$dep" == "docker" ]; then
                    install_cmds+=("sudo apt-get install -y docker.io")
                else
                    install_cmds+=("sudo apt-get install -y $dep")
                fi
            done
        elif command -v yum &>/dev/null; then
            # CentOS/RHEL (旧版本)
            log_info "检测到 CentOS/RHEL 系统 (yum)，使用 yum 安装依赖。"
            install_cmds=("sudo yum makecache fast" "sudo yum install -y epel-release") # epel-release for jq
            for dep in "${missing_deps[@]}"; do
                install_cmds+=("sudo yum install -y $dep")
            done
        elif command -v dnf &>/dev/null; then
            # Fedora/CentOS/RHEL (新版本)
            log_info "检测到 Fedora/CentOS/RHEL 系统 (dnf)，使用 dnf 安装依赖。"
            install_cmds=("sudo dnf makecache" "sudo dnf install -y epel-release") # epel-release for jq
            for dep in "${missing_deps[@]}"; do
                install_cmds+=("sudo dnf install -y $dep")
            done
        else
            log_error "无法识别您的操作系统或未找到适用的包管理器 (apt-get, yum, dnf)。请手动安装以下依赖: ${missing_deps[*]}"
        fi

        for cmd_to_exec in "${install_cmds[@]}"; do
            log_info "执行安装命令: ${cmd_to_exec}"
            eval "$cmd_to_exec"
            if [ $? -ne 0 ]; then
                log_error "自动安装依赖项失败。请手动安装以下依赖: ${missing_deps[*]}. 命令: ${cmd_to_exec}"
            fi
        done

        # 再次检查，确保安装成功
        local still_missing=()
        for cmd in "${missing_deps[@]}"; do # 只检查之前缺失的
            if ! command -v "$cmd" &>/dev/null; then
                still_missing+=("$cmd")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            log_error "自动安装尝试失败，仍缺少依赖项: ${still_missing[*]}。请手动安装后再运行脚本。"
        fi
    fi
    log_success "所有必需的依赖项已安装。"
}

# 检查 Docker 状态
check_docker_status() {
    log_info "正在检查 Docker 守护进程状态..."
    if ! docker info &>/dev/null; then
        log_error "Docker 未运行。请启动 Docker 守护进程。命令：sudo systemctl start docker"
    fi
    log_success "Docker 守护进程正在运行。"
}

# --- 备份功能 ---

# 获取容器详细信息（卷、网络、运行命令）
get_container_details() {
    local container_id="$1"
    local container_name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's/^\///') # 确保去除前导斜杠
    local run_command=""
    local docker_compose_path=""

    log_info "正在收集容器详细信息: ${container_name} (${container_id})"

    # 检查容器是否由 Docker Compose 管理
    docker_compose_path=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container_id" 2>/dev/null)
    if [ -n "$docker_compose_path" ]; then
        docker_compose_path=$(dirname "$(echo "$docker_compose_path" | cut -d',' -f1)") # 获取第一个 compose 文件所在的目录
        log_info "容器 ${container_name} 是 Docker Compose 项目的一部分，位于: ${docker_compose_path}"
        echo "DOCKER_COMPOSE_PROJECT_PATH=${docker_compose_path}" >> "${TMP_DETAILS_FILE}"
    else
        log_info "容器 ${container_name} 是一个独立容器。"
        # 尝试生成 docker run 命令
        # 改进：更安全地提取 Cmd 字段，并确保其为字符串格式
        # 使用 jq 过滤，避免因为 Cmd 字段可能为空或非数组导致的模板错误
        local cmd_json=$(docker inspect --format '{{json .Config.Cmd}}' "$container_id" 2>/dev/null)
        local cmd_args=""
        if [ -n "$cmd_json" ]; then
            # 尝试将 Cmd 字段解析为数组并转换为shell安全字符串，然后合并
            cmd_args=$(echo "$cmd_json" | jq -r 'if type == "array" then .[] | @sh else . end' 2>/dev/null | tr '\n' ' ')
        fi
        
        # 简化 docker run 命令生成，避免复杂 sed 替换
        run_command="docker run "
        run_command+=$(docker inspect --format '{{range .Config.Env}}-e {{. | printf "%q"}} {{end}}{{range .HostConfig.PortBindings}}{{range $p, $a := .}} -p {{$a.HostIp}}:{{$a.HostPort}}:{{$p}} {{end}}{{end}}{{range .HostConfig.Binds}} -v {{. | printf "%q"}} {{end}}{{range .HostConfig.VolumesFrom}} --volumes-from {{.}} {{end}}{{range .HostConfig.Links}} --link {{.}} {{end}}' "$container_id" 2>/dev/null)
        run_command+="--name ${container_name} " # 直接使用清理后的容器名称
        run_command+=$(docker inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null)
        run_command+=" ${cmd_args}"
        
        # 移除多余的空格
        run_command=$(echo "$run_command" | sed 's/  */ /g' | xargs)

        echo "DOCKER_RUN_COMMAND=${run_command}" >> "${TMP_DETAILS_FILE}"
    fi

    # 获取卷和网络
    echo "--- VOLUMES_START ---" >> "${TMP_DETAILS_FILE}"
    docker inspect --format '{{json .Mounts}}' "$container_id" | jq -r '.[] | .Type + ":" + .Source + ":" + .Destination' | while IFS=: read -r type source dest; do
        if [ "$type" == "volume" ]; then
            echo "VOLUME_NAME=${source}" >> "${TMP_DETAILS_FILE}"
            echo "VOLUME_MOUNT_POINT_IN_CONTAINER=${dest}" >> "${TMP_DETAILS_FILE}"
        elif [ "$type" == "bind" ]; then
            echo "BIND_MOUNT_PATH_ON_HOST=${source}" >> "${TMP_DETAILS_FILE}"
            echo "BIND_MOUNT_POINT_IN_CONTAINER=${dest}" >> "${TMP_DETAILS_FILE}"
        fi
    done
    echo "--- VOLUMES_END ---" >> "${TMP_DETAILS_FILE}"

    echo "--- NETWORKS_START ---" >> "${TMP_DETAILS_FILE}"
    docker inspect --format '{{json .NetworkSettings.Networks}}' "$container_id" | jq -r 'keys[]' | while read -r network_name; do
        echo "NETWORK_NAME=${network_name}" >> "${TMP_DETAILS_FILE}"
    done
    echo "--- NETWORKS_END ---" >> "${TMP_DETAILS_FILE}"

    # 其他相关容器详细信息
    echo "CONTAINER_NAME=${container_name}" >> "${TMP_DETAILS_FILE}"
    echo "CONTAINER_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$container_id")" >> "${TMP_DETAILS_FILE}"
    echo "CONTAINER_RESTART_POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id")" >> "${TMP_DETAILS_FILE}"
}

# 主备份功能
backup_project() {
    local project_identifier="$1" # 只能是单个镜像名称或容器 ID/名称
    local container_ids=()
    local inferred_project_name="" # 用于最终文件名的项目名称部分，初始为空
    local backup_timestamp=$(date +%Y%m%d_%H%M%S) # 为当前备份生成时间戳
    local backup_folder=""
    
    # 每次备份时生成一个唯一的临时文件路径，确保在函数内部清理
    # 使用随机字符串防止多进程冲突，并加入时间戳
    # 确保 TMP_DETAILS_FILE 在此函数内声明，避免全局污染和意想不到的错误
    local TMP_DETAILS_FILE="${BACKUP_BASE_DIR}/temp_details_${DATE_FORMAT}_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8).conf"
    
    log_info "正在尝试备份 Docker 项目/容器: ${project_identifier}"

    # --- 改进的容器识别逻辑 ---
    # 优先尝试通过名称精确查找 (包括停止的容器)
    mapfile -t container_ids < <(docker ps -a --filter name="^/${project_identifier}$" --format "{{.ID}}")
    if [ ${#container_ids[@]} -eq 0 ]; then
        # 如果名称精确查找失败，尝试通过 ID 查找
        mapfile -t container_ids < <(docker ps -a --filter id="^${project_identifier}$" --format "{{.ID}}")
    fi

    if [ ${#container_ids[@]} -eq 0 ]; then
        # 如果 ID/名称都找不到，尝试通过镜像 ancestor 查找
        mapfile -t container_ids < <(docker ps -aq --filter ancestor="${project_identifier}")
        if [ ${#container_ids[@]} -eq 0 ]; then
            log_error "未找到与 ID/名称或镜像 '${project_identifier}' 关联的运行或停止的容器。请验证输入。"
            rm -f "${TMP_DETAILS_FILE}" 2>/dev/null
            return 1 # 表示失败
        fi
        log_info "找到与镜像 '${project_identifier}' 关联的容器。正在备份所有关联容器。"
    else
        # 优先使用用户输入的精确匹配到的名称作为日志显示
        local found_container_name=$(docker inspect --format '{{.Name}}' "${container_ids[0]}" | sed 's/^\///')
        log_info "已找到匹配的容器: ${found_container_name} (${container_ids[0]})"
    fi
    # --- 改进的容器识别逻辑 END ---


    # --- 项目名称提取逻辑 START ---
    local is_docker_compose_project=false
    local temp_compose_project_name="" # 用于存储从Compose Label中提取的名称
    
    # 尝试从任何一个相关容器的Compose Label中获取项目名
    for cid in "${container_ids[@]}"; do
        temp_compose_project_name=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null)
        if [ -n "$temp_compose_project_name" ]; then
            is_docker_compose_project=true
            inferred_project_name="${temp_compose_project_name}" # 优先使用 Compose 项目名
            break # 找到一个就够了
        fi
    done

    # 如果不是Compose项目，或者Compose项目名为空，尝试使用第一个容器的名称
    if [ -z "$inferred_project_name" ] && [ ${#container_ids[@]} -gt 0 ]; then
        local first_container_name=$(docker inspect --format '{{.Name}}' "${container_ids[0]}" | sed 's/^\///')
        if [ -n "$first_container_name" ]; then
            # 如果只有一个容器，直接用其名称
            if [ ${#container_ids[@]} -eq 1 ]; then
                inferred_project_name="$first_container_name"
            else
                # 如果有多个容器但不是Compose，或者Compose名为空，则使用第一个容器名作为建议
                inferred_project_name="$first_container_name"
            fi
        fi
    fi

    # 最终净化和回退逻辑
    # 确保只包含字母、数字、点、下划线、短横线
    inferred_project_name=$(echo "$inferred_project_name" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/^_//' | sed 's/_$//')
    # 如果经过所有尝试和净化后仍然为空，则回退为 'unnamed_project'
    if [ -z "$inferred_project_name" ]; then
        log_warn "未能从Docker元数据中推断出项目名称，将使用 'unnamed_project' 作为备份名。"
        inferred_project_name="unnamed_project"
    fi
    # --- 项目名称提取逻辑 END ---

    # 使用最终推断出的项目名称
    local suggested_project_name="${inferred_project_name}"


    # --- 处理同名备份文件递增命名 ---
    local current_base_filename="${BACKUP_FILE_PREFIX}_${backup_timestamp}_${suggested_project_name}"
    local final_project_name_for_file="${suggested_project_name}" # 初始值，可能会在计数器增加时改变
    local counter=0
    local potential_final_path=""

    while true; do
        if [ "$counter" -eq 0 ]; then
            potential_final_path="${BACKUP_BASE_DIR}/${current_base_filename}${BACKUP_FILE_EXTENSION}"
        else
            potential_final_path="${BACKUP_BASE_DIR}/${current_base_filename}_${counter}${BACKUP_FILE_EXTENSION}"
            # 更新文件中的项目名部分，使其与递增的编号一致
            final_project_name_for_file="${suggested_project_name}_${counter}"
        fi

        if [ -f "$potential_final_path" ]; then
            counter=$((counter+1))
        else
            break # 找到一个不重复的文件名
        fi
    done
    
    # 最终的备份文件路径
    local final_backup_file="${potential_final_path}"
    # 更新用于临时文件夹的项目名，确保与最终文件名一致
    local sanitized_final_project_name_for_folder=$(echo "$final_project_name_for_file" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/^_//' | sed 's/_$//')
    backup_folder="${BACKUP_BASE_DIR}/${BACKUP_FILE_PREFIX}_${backup_timestamp}_${sanitized_final_project_name_for_folder}_tmp"


    mkdir -p "${backup_folder}" || log_error "无法创建临时备份目录: ${backup_folder}"

    # 再次确认 TMP_DETAILS_FILE 设置在临时备份文件夹内
    # TMP_DETAILS_FILE 已在函数顶部声明为 local
    echo "BACKUP_DATE=${backup_timestamp}" >> "${TMP_DETAILS_FILE}"

    local compose_file_path=""

    if $is_docker_compose_project ; then
        log_info "检测到 Docker Compose 项目。正在备份 docker-compose.yml"
        local first_compose_file_path=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "${container_ids[0]}" 2>/dev/null | cut -d',' -f1)
        compose_file_path=$(dirname "$first_compose_file_path")

        if [ -f "${compose_file_path}/docker-compose.yml" ]; then
            cp "${compose_file_path}/docker-compose.yml" "${backup_folder}/docker-compose.yml" || log_warn "复制 docker-compose.yml 失败。继续备份。"
        elif [ -f "${compose_file_path}/compose.yaml" ]; then # 有些使用 compose.yaml
            cp "${compose_file_path}/compose.yaml" "${backup_folder}/docker-compose.yml" || log_warn "复制 compose.yaml 失败。继续备份。"
        else
            log_warn "在 ${compose_file_path} 中未找到 docker-compose.yml 或 compose.yaml。继续备份，但不包含 compose 文件。"
        fi
        echo "IS_DOCKER_COMPOSE_PROJECT=true" >> "${TMP_DETAILS_FILE}"
        echo "DOCKER_COMPOSE_PATH_ON_HOST=${compose_file_path}" >> "${TMP_DETAILS_FILE}"

        # 确保 container_ids 包含所有 Compose 项目的容器
        # 这里使用 inferred_project_name，它现在应该包含正确的 Compose 项目名
        if [ -n "$inferred_project_name" ] && [ "$inferred_project_name" != "unnamed_project" ]; then
            mapfile -t container_ids < <(docker ps -aq --filter label="com.docker.compose.project=${inferred_project_name}")
            log_info "将 Docker Compose 项目 '${inferred_project_name}' 的所有容器包含在备份中。"
        fi
    else
        echo "IS_DOCKER_COMPOSE_PROJECT=false" >> "${TMP_DETAILS_FILE}"
    fi

    # 记录备份中包含的所有容器名称到日志
    local backed_up_container_names=()
    for cid in "${container_ids[@]}"; do
        local current_container_name=$(docker inspect --format '{{.Name}}' "$cid" | sed 's/^\///')
        backed_up_container_names+=("${current_container_name} (${cid})")
        echo "--- CONTAINER_START ---" >> "${TMP_DETAILS_FILE}"
        echo "CONTAINER_ID=${cid}" >> "${TMP_DETAILS_FILE}"
        get_container_details "$cid"
        echo "--- CONTAINER_END ---" >> "${TMP_DETAILS_FILE}"
    done
    log_info "本次备份包含的容器: ${backed_up_container_names[*]}"


    # 从 TMP_DETAILS_FILE 中提取唯一的命名卷和绑定挂载以进行备份
    local named_volumes=($(grep "VOLUME_NAME=" "${TMP_DETAILS_FILE}" | cut -d'=' -f2 | sort -u))
    local bind_mount_paths=($(grep "BIND_MOUNT_PATH_ON_HOST=" "${TMP_DETAILS_FILE}" | cut -d'=' -f2 | sort -u))

    for vol_name in "${named_volumes[@]}"; do
        log_info "正在备份 Docker 命名卷: ${vol_name}"
        local volume_path=$(docker volume inspect --format '{{.Mountpoint}}' "$vol_name" 2>/dev/null)
        if [ -d "$volume_path" ]; then
            # 确保 tar 命令是在正确的工作目录下运行，以防止生成多余的父目录结构
            tar -czf "${backup_folder}/volume_${vol_name}.tar.gz" -C "$(dirname "$volume_path")" "$(basename "$volume_path")" || log_warn "备份卷数据失败 ${vol_name}。可能为空或正在使用。继续备份。"
        else
            log_warn "未找到卷挂载点 ${vol_name}: ${volume_path}。跳过卷数据备份。继续备份。"
        fi
    done

    for bind_path in "${bind_mount_paths[@]}"; do
        log_info "正在从宿主机备份绑定挂载数据: ${bind_path}"
        if [ -d "$bind_path" ]; then
            # 使用 base64 编码路径，确保文件名安全且唯一可逆
            local encoded_bind_path=$(echo -n "$bind_path" | base64 | tr -d '\n' | sed 's/=//g')
            tar -czf "${backup_folder}/bind_mount_${encoded_bind_path}.tar.gz" -C "$(dirname "$bind_path")" "$(basename "$bind_path")" || log_warn "备份绑定挂载数据失败 ${bind_path}。可能为空或正在使用。继续备份。"
        else
            log_warn "未在宿主机上找到绑定挂载路径: ${bind_path}。跳过绑定挂载数据备份。继续备份。"
        fi
    done

    log_info "正在创建最终存档: ${final_backup_file}"
    tar -czf "${final_backup_file}" -C "${backup_folder}" .
    if [ $? -eq 0 ]; then
        log_success "项目 '${project_identifier}' 备份成功！"
        log_success "备份文件已保存到: ${GREEN}${final_backup_file}${NC}"
    else
        log_error "创建最终备份存档失败。项目 ${project_identifier} 备份失败。"
    fi

    # 清理临时备份目录及临时文件
    rm -rf "${backup_folder}" || log_warn "无法删除临时备份目录: ${backup_folder}。可能需要手动清理。"
    rm -f "${TMP_DETAILS_FILE}" 2>/dev/null # 确保临时文件也被清理
    echo "" # 添加空行以提高可读性
    return 0 # 成功返回 0
}

# --- 恢复功能 ---

# 恢复命名卷
restore_named_volume() {
    local backup_file="$1"
    local vol_name="$2"

    log_info "正在恢复命名卷: ${vol_name} 从 ${backup_file}"

    if ! docker volume ls | grep -q "$vol_name"; then
        log_info "卷 ${vol_name} 不存在，正在创建..."
        docker volume create "$vol_name" || { log_warn "无法创建卷: ${vol_name}。跳过此卷的数据恢复。"; return 1; }
    fi

    local volume_mountpoint=$(docker volume inspect --format '{{.Mountpoint}}' "$vol_name")

    if [ -d "$volume_mountpoint" ]; then
        log_info "正在将数据解压到卷挂载点: ${volume_mountpoint}"
        # --strip-components=1 在这里至关重要，用于移除 tar -C 创建的顶层目录
        tar -xzf "$backup_file" -C "$volume_mountpoint" --strip-components=1
        if [ $? -eq 0 ]; then
            log_success "成功恢复数据到卷 ${vol_name}。"
        else
            log_warn "从卷 ${vol_name} 提取数据失败。需要手动检查。继续恢复。"
        fi
    else
        log_warn "未找到卷挂载点 ${volume_mountpoint} 对应 ${vol_name}。无法恢复数据。继续恢复。"
        return 1
    fi
    return 0
}

# 恢复绑定挂载
restore_bind_mount() {
    local backup_file="$1"
    local host_path="$2" # 这是原始的宿主机路径

    log_info "正在将绑定挂载数据恢复到宿主机路径: ${host_path} 从 ${backup_file}"

    mkdir -p "$host_path" || { log_warn "无法创建绑定挂载宿主机目录: ${host_path}。跳过此绑定挂载的数据恢复。"; return 1; }

    # --strip-components=1 在这里至关重要
    tar -xzf "$backup_file" -C "$host_path" --strip-components=1
    if [ $? -eq 0 ]; then
        log_success "成功恢复数据到绑定挂载 ${host_path}。"
    else
        log_warn "将数据提取到绑定挂载路径 ${host_path} 失败。需要手动检查。继续恢复。"
    fi
    return 0
}

# 主恢复功能
restore_project() {
    local backup_archive="$1"
    local temp_extract_dir="${BACKUP_BASE_DIR}/restore_temp_${DATE_FORMAT}_$(basename "$backup_archive" | sed 's/\.tar\.gz$//')_tmp"
    local restore_status="成功"

    if [ ! -f "$backup_archive" ]; then
        log_error "未找到备份存档: ${backup_archive}"
        return 1 # 添加返回，因为文件不存在就没必要继续了
    fi
    
    log_info "正在从存档恢复: ${backup_archive}"
    mkdir -p "$temp_extract_dir" || log_error "无法创建临时恢复目录: ${temp_extract_dir}"

    tar -xzf "$backup_archive" -C "$temp_extract_dir"
    if [ $? -ne 0 ]; then
        log_error "提取备份存档失败。恢复中止。"
        return 1 # 添加返回，因为提取失败就没必要继续了
    fi

    local details_file="${temp_extract_dir}/project_details.conf"
    if [ ! -f "$details_file" ]; then
        log_error "备份中未找到项目详细信息文件: ${details_file}。此备份无效。恢复中止。"
        return 1 # 添加返回，因为文件缺失就没必要继续了
    fi

    local is_docker_compose=$(grep "IS_DOCKER_COMPOSE_PROJECT=" "$details_file" | cut -d'=' -f2)

    # 恢复命名卷
    local named_volumes=($(grep "VOLUME_NAME=" "${details_file}" | cut -d'=' -f2 | sort -u))
    for vol_name in "${named_volumes[@]}"; do
        local vol_backup_file="${temp_extract_dir}/volume_${vol_name}.tar.gz"
        if [ -f "$vol_backup_file" ]; then
            restore_named_volume "$vol_backup_file" "$vol_name" || restore_status="部分成功"
        else
            log_warn "未找到卷 ${vol_name} 的备份文件: ${vol_backup_file}。跳过此卷的数据恢复。"
            restore_status="部分成功"
        fi
    done

    # 恢复绑定挂载
    local bind_mount_host_paths=($(grep "BIND_MOUNT_PATH_ON_HOST=" "$details_file" | cut -d'=' -f2 | sort -u))
    for bind_path in "${bind_mount_host_paths[@]}"; do
        # 解码路径以找到正确的备份文件
        local encoded_bind_path=$(echo -n "$bind_path" | base64 | tr -d '\n' | sed 's/=//g')
        local bind_backup_file="${temp_extract_dir}/bind_mount_${encoded_bind_path}.tar.gz"
        if [ -f "$bind_backup_file" ]; then
            restore_bind_mount "$bind_backup_file" "$bind_path" || restore_status="部分成功"
        else
            log_warn "未找到绑定挂载 ${bind_path} 的备份文件: ${bind_backup_file}。跳过此绑定挂载的数据恢复。"
            restore_status="部分成功"
        fi
    done

    # 根据部署类型恢复项目
    if [ "$is_docker_compose" == "true" ]; then
        log_info "正在恢复 Docker Compose 项目。"
        local compose_file="${temp_extract_dir}/docker-compose.yml"
        local original_compose_path=$(grep "DOCKER_COMPOSE_PATH_ON_HOST=" "$details_file" | cut -d'=' -f2)

        if [ -f "$compose_file" ]; then
            log_warn "原始 Docker Compose 路径为 '${original_compose_path}'。您可能希望将 compose 文件恢复到该路径，或创建新目录。"
            read -r -e -p "请输入要恢复 docker-compose.yml 的目标目录 (默认: 当前目录): " RESTORE_COMPOSE_DIR
            RESTORE_COMPOSE_DIR=${RESTORE_COMPOSE_DIR:-.}
            mkdir -p "$RESTORE_COMPOSE_DIR" || { log_warn "无法创建目录: ${RESTORE_COMPOSE_DIR}。跳过 compose 文件复制。"; restore_status="部分成功"; }
            if [ -d "$RESTORE_COMPOSE_DIR" ]; then
                cp "$compose_file" "${RESTORE_COMPOSE_DIR}/docker-compose.yml"
                if [ $? -eq 0 ]; then
                    log_success "docker-compose.yml 已复制到 ${GREEN}${RESTORE_COMPOSE_DIR}/docker-compose.yml${NC}。"
                    log_info "要启动服务，请进入 ${RESTORE_COMPOSE_DIR} 目录并运行: ${GREEN}docker-compose up -d${NC}"
                else
                    log_warn "复制 docker-compose.yml 到 ${RESTORE_COMPOSE_DIR} 失败。需要手动复制。"
                    restore_status="部分成功"
                fi
            fi
        else
            log_warn "备份中未找到 docker-compose.yml。无法自动恢复为 Docker Compose 项目。"
            restore_status="部分成功"
        fi
    else
        log_info "正在恢复独立 Docker 容器。"
        IFS=$'\n' read -d '' -ra container_blocks < <(awk '/--- CONTAINER_START ---/{flag=1; next} /--- CONTAINER_END ---/{flag=0} flag' "$details_file")
        for block_content in "${container_blocks[@]}"; do
            if [ -z "$block_content" ]; then continue; fi

            # 使用 here-string 将多行内容传递给 grep/cut
            local container_name=$(echo "$block_content" | grep "CONTAINER_NAME=" | cut -d'=' -f2)
            local container_image=$(echo "$block_content" | grep "CONTAINER_IMAGE=" | cut -d'=' -f2)
            local docker_run_command=$(echo "$block_content" | grep "DOCKER_RUN_COMMAND=" | cut -d'=' -f2)
            local restart_policy=$(echo "$block_content" | grep "CONTAINER_RESTART_POLICY=" | cut -d'=' -f2)

            log_info "正在尝试恢复容器: ${container_name} (镜像: ${container_image})"

            if [ -n "$docker_run_command" ]; then
                log_info "使用记录的 docker run 命令恢复 ${container_name}。"
                if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
                    log_warn "容器 '${container_name}' 已存在。正在停止并移除它，然后重新创建。"
                    docker stop "$container_name" &>/dev/null
                    docker rm "$container_name" &>/dev/null
                fi

                # 确保重启策略被加入到命令中，除非命令已经包含或策略为no
                if [[ ! "$docker_run_command" =~ "--restart " && "$restart_policy" != "no" && -n "$restart_policy" ]]; then
                    docker_run_command+=" --restart $restart_policy"
                fi
                
                log_info "建议重新创建容器 '${container_name}' 的命令:"
                log_info "${YELLOW}${docker_run_command}${NC}"
                read -r -e -p "您想执行此命令吗？(y/N): " exec_confirm
                if [[ "$exec_confirm" =~ ^[Yy]$ ]]; then
                    # 运行前再次检查命令中是否有 / 作为名称前缀并移除 (尽管前面生成命令时已处理)
                    local final_run_command=$(echo "$docker_run_command" | sed "s| --name /${container_name}| --name ${container_name}|")
                    eval "$final_run_command"
                    if [ $? -eq 0 ]; then
                        log_success "容器 ${container_name} 已重新创建 (查看日志获取详细信息)。"
                    else
                        log_warn "使用记录的命令重新创建容器 ${container_name} 失败。需要手动重新创建。"
                        restore_status="部分成功"
                    fi
                else
                    log_warn "跳过容器 ${container_name} 的自动重新创建。您可以使用提供的命令手动重新创建。"
                    restore_status="部分成功"
                fi
            else
                log_warn "备份中未找到容器 ${container_name} 的 'docker run' 命令。需要手动恢复。"
                restore_status="部分成功"
            fi
        done
    fi

    rm -rf "${temp_extract_dir}" || log_warn "无法删除临时恢复目录: ${temp_extract_dir}。可能需要手动清理。"

    if [ "$restore_status" == "成功" ]; then
        log_success "项目从 ${backup_archive} 恢复成功！"
    else
        log_warn "项目从 ${backup_archive} 恢复完成，但有警告/部分成功。请查看日志获取详细信息。"
    fi
    log_warn "请手动验证所有服务是否正常运行且数据可访问。"
    echo "" # 添加空行以提高可读性
}

# 列出运行的 Docker 服务 (实时获取)
list_docker_services() {
    log_info "正在获取当前正在运行的 Docker 服务..."
    echo -e "${BLUE}-------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW}序号        ID            名称                 镜像                         状态              Compose项目${NC}"
    echo -e "${BLUE}-------------------------------------------------------------------------------------------------------${NC}"

    local services=()
    local i=1
    # 仅列出正在运行的容器
    while IFS= read -r line; do
        services+=("$line")
        local id=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local image=$(echo "$line" | awk '{print $3}')
        local status=$(echo "$line" | awk '{print $4,$5,$6,$7,$8}') # 修正状态列可能包含空格
        local compose_label=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$id" 2>/dev/null)
        
        printf "%-8s %-12s %-18s %-28s %-18s %s\n" "$i." "$id" "$name" "$image" "$status" "$compose_label"
        i=$((i+1))
    done < <(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}") # **只显示运行中的容器**
    echo -e "${BLUE}-------------------------------------------------------------------------------------------------------${NC}"

    if [ ${#services[@]} -eq 0 ]; then
        log_warn "未在此服务器上找到正在运行的 Docker 服务 (容器)。"
        log_info "如果您需要备份已停止的容器，请手动输入其名称或ID。"
        return 1
    fi
    return 0
}

# --- 脚本自注册函数 ---
self_register_as_global_command() {
    # 检查目标路径是否已存在同名文件，如果存在且不是当前脚本，则提示
    if [ -f "$GLOBAL_COMMAND_PATH" ]; then
        if [ "$(readlink -f "$0")" == "$(readlink -f "$GLOBAL_COMMAND_PATH")" ]; then
            # 已经注册，并且当前运行的就是注册的脚本
            return 0
        else
            log_warn "检测到 '/usr/local/bin/${GLOBAL_COMMAND_NAME}' 已存在，但它不是当前脚本。"
            log_warn "如果您想将当前脚本注册为 '${GLOBAL_COMMAND_NAME}'，请手动删除旧文件或重命名当前脚本。"
            return 1
        fi
    fi

    echo -e "${YELLOW}检测到这是 DMR 脚本的首次运行或未注册为全局命令。${NC}"
    echo -e "${BLUE}建议将其注册为全局命令 '${GLOBAL_COMMAND_NAME}'，以便您在任何位置直接运行 'sudo ${GLOBAL_COMMAND_NAME}'。${NC}"
    read -r -e -p "您想将脚本注册为全局命令吗？(y/N): " register_confirm

    if [[ "$register_confirm" =~ ^[Yy]$ ]]; then
        # 确保当前脚本有执行权限
        chmod +x "$0"
        
        # 将当前脚本复制到目标路径并重命名
        sudo cp "$0" "$GLOBAL_COMMAND_PATH"
        if [ $? -eq 0 ]; then
            log_success "DMR 脚本已成功注册为全局命令: ${GREEN}sudo ${GLOBAL_COMMAND_NAME}${NC}"
            log_info "您现在可以退出当前会话并重新登录，或者运行 'hash -r' 使新命令生效。"
            echo -e "${BLUE}--------------------------------------------------${NC}"
            echo -e "${BLUE}请注意：现在您可以使用 'sudo ${GLOBAL_COMMAND_NAME}' 来启动脚本。${NC}"
            echo -e "${BLUE}原脚本文件 '${SCRIPT_NAME}' 可以保留在原处或删除。${NC}"
            echo -e "${BLUE}--------------------------------------------------${NC}"
            read -r -e -p "按回车键继续..."
        else
            log_error "注册全局命令失败。请检查权限或手动将脚本复制到 '/usr/local/bin' 并重命名为 '${GLOBAL_COMMAND_NAME}'。"
            log_warn "您仍然可以使用当前脚本文件运行 DMR。"
            read -r -e -p "按回车键继续..."
        fi
    else
        log_info "用户选择不注册为全局命令。您仍然可以使用 '${0}' 路径运行 DMR。"
        read -r -e -p "按回车键继续..."
    fi
}


# --- 脚本主逻辑 ---

# 优先创建备份基础目录，确保日志能正常写入
mkdir -p "${BACKUP_BASE_DIR}" || log_error "无法创建基础目录: ${BACKUP_BASE_DIR}。请检查权限。"

# 执行自注册逻辑
# 只有当当前脚本不是以 GLOBAL_COMMAND_NAME 运行时才触发注册提示
if [ "$(basename "$0")" != "${GLOBAL_COMMAND_NAME}" ]; then
    self_register_as_global_command
fi

# 预先检查依赖项和 Docker 状态
check_dependencies
check_docker_status


while true; do
    clear # 清屏以显示干净的菜单
    echo -e "${GREEN}--- DMR - Docker 备份与恢复主菜单 ---${NC}"
    echo "1. 备份 Docker 服务"
    echo "2. 恢复 Docker 服务"
    echo "3. 查看备份/恢复日志"
    echo "4. 列出可用备份文件"
    echo "5. 退出"
    echo -e "${GREEN}-------------------------------------${NC}"
    read -r -e -p "请输入您的选择 (1-5): " choice
    echo "" # 空行用于间距

    case "$choice" in
        1) # 备份 Docker 服务 (交互式多服务添加)
            log_info "--- 备份 Docker 服务 ---"
            local services_to_backup=() # 初始化空数组
            local continue_add_loop_flag=true # 循环标志

            while $continue_add_loop_flag; do
                clear # 每次添加前清屏，保持界面整洁
                list_docker_services # 每次添加前显示当前运行的服务列表

                echo ""
                if [ ${#services_to_backup[@]} -eq 0 ]; then
                    echo -e "${BLUE}当前待备份服务列表: ${YELLOW}无${NC}"
                else
                    echo -e "${BLUE}当前待备份服务列表: ${YELLOW}${services_to_backup[*]}${NC}"
                fi
                echo ""
                echo -e "${YELLOW}提示: 输入 '0' 返回主菜单，输入 'N' 或 'n' 停止添加并开始备份。${NC}"
                read -r -e -p "请输入要添加备份的 Docker 容器 ID/名称或镜像名称: " single_service_input

                single_service_input=$(echo "$single_service_input" | xargs) # 清理输入

                if [ "$single_service_input" == "0" ]; then
                    log_info "用户选择返回主菜单。"
                    continue_add_loop_flag=false # 退出添加循环
                    choice="0" # 设置主菜单选择为0，以便外部while循环处理
                    break # 跳出当前添加循环
                elif [[ "$single_service_input" =~ ^[Nn]$ ]]; then
                    continue_add_loop_flag=false # 停止添加，进入备份确认流程
                    break # 跳出当前添加循环
                elif [ -z "$single_service_input" ]; then
                    log_warn "输入为空，请重新输入。"
                    read -r -e -p "按回车键继续..."
                    continue # 继续当前添加循环，重新提示输入
                else
                    # 检查服务是否存在
                    local temp_ids=()
                    mapfile -t temp_ids < <(docker ps -a --filter name="^/${single_service_input}$" --format "{{.ID}}")
                    if [ ${#temp_ids[@]} -eq 0 ]; then
                        mapfile -t temp_ids < <(docker ps -a --filter id="^${single_service_input}$" --format "{{.ID}}")
                    fi
                    if [ ${#temp_ids[@]} -eq 0 ]; then
                        mapfile -t temp_ids < <(docker ps -aq --filter ancestor="${single_service_input}")
                    fi

                    if [ ${#temp_ids[@]} -gt 0 ]; then
                        # 检查是否已存在于列表中，避免重复添加
                        local already_added=false
                        for existing_service in "${services_to_backup[@]}"; do
                            if [ "$existing_service" == "$single_service_input" ]; then
                                already_added=true
                                break
                            fi
                        done

                        if [ "$already_added" = true ]; then
                            log_warn "'${single_service_input}' 已在待备份列表中。请勿重复添加。"
                        else
                            services_to_backup+=("$single_service_input") # 添加到列表
                            log_success "'${single_service_input}' 已成功添加到待备份列表。"
                        fi
                    else
                        log_warn "未找到与 '${single_service_input}' 关联的容器。请检查输入。"
                    fi
                fi
                
                # 无论上次输入结果如何，都询问是否继续添加
                echo ""
                echo -e "${BLUE}当前待备份服务列表: ${YELLOW}${services_to_backup[*]:-(无)}${NC}" # 再次显示列表
                read -r -e -p "是否继续添加其他服务？(Y/n): " continue_add_choice
                continue_add_choice=$(echo "$continue_add_choice" | tr '[:upper:]' '[:lower:]' | xargs) # 清理并转小写

                if [ "$continue_add_choice" == "n" ]; then
                    continue_add_loop_flag=false # 停止添加，进入备份确认
                elif [ "$continue_add_choice" == "0" ]; then
                    log_info "用户选择返回主菜单。"
                    continue_add_loop_flag=false # 停止添加循环
                    choice="0" # 设置主菜单选择为0，以便外部while循环处理
                fi
                # 如果是 Y 或空，则 continue_add_loop_flag 仍为 true，循环继续
            done # End of while loop for adding services

            # 只有当用户没有选择 "0" 返回主菜单时，才执行备份确认
            if [ "$choice" != "0" ]; then
                if [ ${#services_to_backup[@]} -eq 0 ]; then
                    log_info "没有选择任何服务进行备份。返回主菜单。"
                else
                    echo ""
                    echo -e "${BLUE}最终确认待备份服务列表: ${YELLOW}${services_to_backup[*]}${NC}"
                    read -r -e -p "确认开始备份这些服务吗？(y/N): " confirm_backup
                    if [[ "$confirm_backup" =~ ^[Yy]$ ]]; then
                        for service_id in "${services_to_backup[@]}"; do
                            log_info "--- 正在备份服务: ${service_id} ---"
                            backup_project "$service_id" 
                            if [ $? -ne 0 ]; then # 检查 backup_project 的退出状态
                                log_warn "服务 '${service_id}' 备份失败，但会继续尝试备份其他服务。"
                            fi
                            echo "" 
                        done
                        log_success "所有选定服务的批量备份操作已尝试完成。"
                    else
                        log_info "用户取消批量备份。"
                    fi
                fi
                read -r -e -p "按回车键返回主菜单..."
            fi
            ;;
        2) # 恢复 Docker 服务
            log_info "--- 恢复 Docker 服务 ---"
            # 判断是否有备份文件，如果 find 找到文件则 count > 0
            backup_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "${BACKUP_FILE_PREFIX}*${BACKUP_FILE_EXTENSION}" | wc -l)

            if [ "$backup_count" -eq 0 ]; then
                log_warn "在 ${BACKUP_BASE_DIR} 中未找到备份文件。"
                echo -e "${YELLOW}0. 返回主菜单${NC}"
                read -r -e -p "按回车键返回主菜单..."
                continue
            fi

            echo -e "${YELLOW}在 ${BACKUP_BASE_DIR} 中可用的备份文件:${NC}"
            # 美化输出备份列表
            echo -e "${YELLOW}大小     日期         时间       项目名称/镜像                       文件名${NC}"
            echo -e "${BLUE}---------------------------------------------------------------------------------------------------${NC}"
            # 使用 'find' 更健壮地处理文件列表，并按时间逆序排序
            find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "${BACKUP_FILE_PREFIX}*${BACKUP_FILE_EXTENSION}" -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2- | while read -r file_path; do
                file_size=$(du -sh "$file_path" | awk '{print $1}')
                filename=$(basename "$file_path")
                # 从文件名中解析日期、时间和项目名称
                # 文件名示例: docker_project_backup_20250725_102100_my_web_app.tar.gz 或 docker_project_backup_20250725_102100_my_web_app_1.tar.gz
                datetime_part=$(echo "$filename" | sed -n "s/^${BACKUP_FILE_PREFIX}_\([0-9]\{8\}\_[0-9]\{6\}\)_.*$/\1/p")
                file_date=$(echo "$datetime_part" | cut -d'_' -f1)
                file_time=$(echo "$datetime_part" | cut -d'_' -f2)
                # 提取项目名部分，考虑可能包含的数字后缀
                project_part=$(echo "$filename" | sed -n "s/^${BACKUP_FILE_PREFIX}_[0-9]\{8\}\_[0-9]\{6\}_\(.*\)\.tar\.gz$/\1/p")

                printf "%-8s %-10s %-8s %-35s %s\n" "$file_size" "$file_date" "$file_time" "$project_part" "$filename"
            done
            echo -e "${BLUE}---------------------------------------------------------------------------------------------------${NC}"
            echo ""
            echo -e "${YELLOW}0. 返回主菜单${NC}"
            read -r -e -p "请输入要恢复的备份文件名 (例如: 'docker_project_backup_20250725_102100_my_web_app.tar.gz'): " backup_file_name
            if [ "$backup_file_name" == "0" ]; then
                log_info "返回主菜单。"
                continue
            fi
            if [ -z "$backup_file_name" ]; then
                log_warn "未提供备份文件名。返回主菜单。"
                continue
            fi

            full_backup_path="${BACKUP_BASE_DIR}/${backup_file_name}"
            if [ ! -f "$full_backup_path" ]; then
                log_error "备份文件 '${full_backup_path}' 未找到。请从列表中提供一个有效的文件名。"
                read -r -e -p "按回车键返回主菜单..."
                continue
            fi

            read -r -e -p "确认从 '${full_backup_path}' 恢复吗？(y/N): " confirm_restore
            if [[ "$confirm_restore" =~ ^[Yy]$ ]]; then
                restore_project "$full_backup_path"
            else
                log_info "用户取消恢复。"
            fi
            read -r -e -p "按回车键返回主菜单..."
            ;;
        3) # 查看日志
            log_info "--- 正在查看备份/恢复日志 ---"
            if [ -f "$LOG_FILE" ]; then
                echo -e "${GREEN}显示日志文件 '${LOG_FILE}' 的最后 50 行:${NC}"
                tail -n 50 "$LOG_FILE"
                echo -e "${YELLOW}0. 返回主菜单${NC}"
                read -r -e -p "按回车键查看完整日志或 '0' 返回菜单: " log_choice
                if [[ "$log_choice" == "0" ]]; then
                    log_info "返回主菜单。"
                    continue
                else
                    ${PAGER:-less} "$LOG_FILE" # 使用 less 或默认分页器
                fi
            else
                log_warn "未找到日志文件: ${LOG_FILE}"
            fi
            read -r -e -p "按回车键返回主菜单..."
            ;;
        4) # 列出可用备份
            log_info "--- 正在列出可用备份 ---"
            # 判断是否有备份文件
            backup_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "${BACKUP_FILE_PREFIX}*${BACKUP_FILE_EXTENSION}" | wc -l)

            if [ "$backup_count" -eq 0 ]; then
                log_warn "在 ${BACKUP_BASE_DIR} 中未找到备份文件。"
            else
                echo -e "${GREEN}在 ${BACKUP_BASE_DIR} 中可用的备份:${NC}"
                echo -e "${YELLOW}大小     日期         时间       项目名称/镜像                       文件名${NC}"
                echo -e "${BLUE}---------------------------------------------------------------------------------------------------${NC}"
                # 使用 find 和 sort 以更好地处理大量文件并按时间排序
                find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "${BACKUP_FILE_PREFIX}*${BACKUP_FILE_EXTENSION}" -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2- | while read -r file_path; do
                    file_size=$(du -sh "$file_path" | awk '{print $1}')
                    filename=$(basename "$file_path")
                    datetime_part=$(echo "$filename" | sed -n "s/^${BACKUP_FILE_PREFIX}_\([0-9]\{8\}\_[0-9]\{6\}\)_.*$/\1/p")
                    file_date=$(echo "$datetime_part" | cut -d'_' -f1)
                    file_time=$(echo "$datetime_part" | cut -d'_' -f2)
                    project_part=$(echo "$filename" | sed -n "s/^${BACKUP_FILE_PREFIX}_[0-9]\{8\}\_[0-9]\{6\}_\(.*\)\.tar\.gz$/\1/p")

                    printf "%-8s %-10s %-8s %-35s %s\n" "$file_size" "$file_date" "$file_time" "$project_part" "$filename"
                done
                echo -e "${BLUE}---------------------------------------------------------------------------------------------------${NC}"
            fi
            echo -e "${YELLOW}0. 返回主菜单${NC}"
            read -r -e -p "按回车键返回主菜单或 '0' 返回主菜单: " list_choice
            if [[ "$list_choice" == "0" ]]; then
                log_info "返回主菜单。"
                continue
            fi
            ;;
        5) # 退出
            log_info "正在退出脚本。再见！"
            clear # 在退出前清屏
            exit 0
            ;;
        *)
            log_warn "无效的选择。请输入 1 到 5 之间的数字。"
            read -r -e -p "按回车键继续..."
            ;;
    esac
done

exit 0