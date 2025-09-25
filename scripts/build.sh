#!/bin/bash
#
# OpenWrt固件编译脚本
# 支持多分支多配置编译
#

# 设置严格模式
set -euo pipefail

# 导入配置
source ./scripts/scripts.sh

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[INFO] $1" >> "${LOG_DIR}/build.log"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "[SUCCESS] $1" >> "${LOG_DIR}/build.log"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $1" >> "${LOG_DIR}/build.log"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $1" >> "${LOG_DIR}/build.log"
}

# 错误处理函数
error_exit() {
    log_error "$1"
    # 输出错误前1000行日志
    log_info "输出错误前1000行日志:"
    tail -1000 "${LOG_DIR}/build.log" 2>&1 | while read line; do
        echo "$line" >> "${LOG_DIR}/error_context.log"
    done
    exit 1
}

# 检查必要环境变量
check_env() {
    log_info "检查环境变量..."
    
    if [[ -z "${TARGET_CHIP:-}" ]]; then
        error_exit "环境变量 TARGET_CHIP 未设置"
    fi
    
    if [[ -z "${BUILD_DIR:-}" ]]; then
        error_exit "环境变量 BUILD_DIR 未设置"
    fi
    
    if [[ -z "${TEMP_DIR:-}" ]]; then
        error_exit "环境变量 TEMP_DIR 未设置"
    fi
    
    log_success "环境变量检查完成"
}

# 初始化工作目录
init_workspace() {
    log_info "初始化工作空间..."
    
    mkdir -p "${BUILD_DIR}" "${TEMP_DIR}" "${LOG_DIR}" "${CCACHE_DIR}" "${DL_DIR}" "${STAGING_DIR}"
    
    log_success "工作空间初始化完成"
}

# 恢复缓存
restore_cache() {
    log_info "恢复缓存..."
    
    # 检查并设置缓存目录
    if [[ -d "${CCACHE_DIR}" ]]; then
        export CCACHE_DIR="${CCACHE_DIR}"
        log_info "CCache目录: ${CCACHE_DIR}"
    fi
    
    if [[ -d "${DL_DIR}" ]]; then
        export DL_DIR="${DL_DIR}"
        log_info "DL目录: ${DL_DIR}"
    fi
    
    if [[ -d "${STAGING_DIR}" ]]; then
        export STAGING_DIR="${STAGING_DIR}"
        log_info "Staging目录: ${STAGING_DIR}"
    fi
    
    log_success "缓存恢复完成"
}

# 克隆源码
clone_source() {
    local repo_url="${1:-}"
    local repo_branch="${2:-}"
    local repo_name="${3:-}"
    
    log_info "开始克隆${repo_name}源码..."
    log_info "仓库: ${repo_url}"
    log_info "分支: ${repo_branch}"
    
    if [[ -d "${BUILD_DIR}" ]] && [[ -n "$(ls -A ${BUILD_DIR})" ]]; then
        log_warning "构建目录非空，清理后重新克隆"
        rm -rf "${BUILD_DIR}"/*
    fi
    
    git clone --depth 1 --branch "${repo_branch}" "${repo_url}" "${BUILD_DIR}"
    
    if [[ $? -ne 0 ]]; then
        error_exit "克隆${repo_name}源码失败"
    fi
    
    log_success "${repo_name}源码克隆完成"
}

# 初始化feeds
init_feeds() {
    log_info "初始化feeds..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    ./scripts/feeds update -a || error_exit "更新feeds失败"
    ./scripts/feeds install -a || error_exit "安装feeds失败"
    
    log_success "feeds初始化完成"
}

# 准备配置文件
prepare_config() {
    local config_type="${1:-}"
    local repo_short="${2:-}"
    
    log_info "准备${repo_short}的${config_type}配置..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    # 清空现有配置
    > .config
    
    # 按优先级合并配置文件
    if [[ -f "${GITHUB_WORKSPACE}/configs/${TARGET_CHIP}_base.config" ]]; then
        cat "${GITHUB_WORKSPACE}/configs/${TARGET_CHIP}_base.config" >> .config
        log_info "已添加芯片基础配置"
    fi
    
    if [[ -f "${GITHUB_WORKSPACE}/configs/${repo_short}_base.config" ]]; then
        cat "${GITHUB_WORKSPACE}/configs/${repo_short}_base.config" >> .config
        log_info "已添加${repo_short}分支基础配置"
    fi
    
    if [[ -f "${GITHUB_WORKSPACE}/configs/${config_type}.config" ]]; then
        cat "${GITHUB_WORKSPACE}/configs/${config_type}.config" >> .config
        log_info "已添加${config_type}软件包配置"
    fi
    
    # 保存原始配置用于调试
    cp .config "${LOG_DIR}/${repo_short}-${TARGET_CHIP}-raw-${config_type}.config"
    
    log_success "${repo_short}的${config_type}配置准备完成"
}

# 获取设备列表
get_devices() {
    log_info "获取设备列表..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    # 从配置文件中提取设备名称
    local devices=()
    while IFS= read -r line; do
        if [[ $line =~ ^CONFIG_TARGET_DEVICE_.*_DEVICE_([^=]+)=y ]]; then
            local device="${BASH_REMATCH[1]}"
            if [[ -n "$device" ]] && [[ ! " ${devices[@]} " =~ " ${device} " ]]; then
                devices+=("$device")
                log_info "检测到设备: $device"
            fi
        fi
    done < .config
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        error_exit "未检测到任何设备配置"
    fi
    
    echo "${devices[@]}"
    log_success "设备列表获取完成，共${#devices[@]}个设备"
}

# 配置编译选项
configure_build() {
    log_info "配置编译选项..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    # 设置环境变量
    export CCACHE_DIR="${CCACHE_DIR:-}"
    export DL_DIR="${DL_DIR:-}"
    export STAGING_DIR="${STAGING_DIR:-}"
    
    # 生成默认配置
    make defconfig || error_exit "生成默认配置失败"
    
    log_success "编译选项配置完成"
}

# 编译固件
build_firmware() {
    local repo_short="${1:-}"
    local config_type="${2:-}"
    
    log_info "开始编译${repo_short}-${config_type}固件..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    # 设置环境变量
    export CCACHE_DIR="${CCACHE_DIR:-}"
    export DL_DIR="${DL_DIR:-}"
    export STAGING_DIR="${STAGING_DIR:-}"
    
    # 执行编译，超时4小时
    timeout 4h make -j$(nproc) V=s 2>&1 | tee "${LOG_DIR}/${repo_short}-${TARGET_CHIP}-${config_type}.log"
    
    local exit_code=${PIPESTATUS[0]}
    
    if [[ $exit_code -ne 0 ]]; then
        error_exit "编译${repo_short}-${config_type}失败，退出码: $exit_code"
    fi
    
    log_success "${repo_short}-${config_type}固件编译完成"
}

# 处理产出物
process_artifacts() {
    local repo_short="${1:-}"
    local config_type="${2:-}"
    shift 2
    local devices=("$@")
    
    log_info "处理${repo_short}-${config_type}产出物..."
    
    cd "${BUILD_DIR}" || error_exit "无法进入构建目录"
    
    # 创建临时目录
    mkdir -p "${TEMP_DIR}/firmware" "${TEMP_DIR}/configs" "${TEMP_DIR}/logs" "${TEMP_DIR}/apps"
    
    # 复制并重命名固件文件
    for device in "${devices[@]}"; do
        log_info "处理设备${device}的固件..."
        
        # 复制factory固件
        for factory_file in bin/targets/*/*/*-factory.bin; do
            if [[ -f "$factory_file" ]] && [[ $factory_file == *"${TARGET_CHIP}"* ]] && [[ $factory_file == *"$device"* ]] && [[ $factory_file == *"-factory.bin"* ]]; then
                local new_name="${repo_short}-${device}-factory-${config_type}.bin"
                cp "$factory_file" "${TEMP_DIR}/firmware/$new_name"
                log_info "已复制并重命名factory固件: $new_name"
            fi
        done
        
        # 复制sysupgrade固件
        for sysupgrade_file in bin/targets/*/*/*-sysupgrade.bin; do
            if [[ -f "$sysupgrade_file" ]] && [[ $sysupgrade_file == *"${TARGET_CHIP}"* ]] && [[ $sysupgrade_file == *"$device"* ]] && [[ $sysupgrade_file == *"-sysupgrade.bin"* ]]; then
                local new_name="${repo_short}-${device}-sysupgrade-${config_type}.bin"
                cp "$sysupgrade_file" "${TEMP_DIR}/firmware/$new_name"
                log_info "已复制并重命名sysupgrade固件: $new_name"
            fi
        done
    done
    
    # 复制配置相关文件
    local device_list=$(printf '%s ' "${devices[@]}")
    cp .config "${TEMP_DIR}/configs/${repo_short}-${TARGET_CHIP}-${device_list}-${config_type}.config"
    cp .config.buildinfo "${TEMP_DIR}/configs/${repo_short}-${TARGET_CHIP}-${device_list}-${config_type}.config.buildinfo" 2>/dev/null || true
    
    # 查找并复制manifest文件
    find . -name "*.manifest" -exec cp {} "${TEMP_DIR}/configs/${repo_short}-${TARGET_CHIP}-${device_list}-${config_type}.manifest" \; 2>/dev/null || true
    
    # 复制日志文件
    cp "${LOG_DIR}/${repo_short}-${TARGET_CHIP}-${config_type}.log" "${TEMP_DIR}/logs/${repo_short}-${TARGET_CHIP}-${config_type}.log"
    
    # 提取错误和警告日志
    grep -i "error\|warning\|Error\|Warning" "${LOG_DIR}/${repo_short}-${TARGET_CHIP}-${config_type}.log" > "${TEMP_DIR}/logs/${repo_short}-${TARGET_CHIP}-${config_type}-errors-warnings.log" 2>/dev/null || true
    
    # 复制软件包
    if [[ -d "bin/packages" ]]; then
        find bin/packages -name "*.ipk" -exec cp {} "${TEMP_DIR}/apps/" \; 2>/dev/null || true
    fi
    
    if [[ -d "bin/targets" ]]; then
        find bin/targets -name "*.ipk" -exec cp {} "${TEMP_DIR}/apps/" \; 2>/dev/null || true
    fi
    
    log_success "${repo_short}-${config_type}产出物处理完成"
}

# 主函数
main() {
    log_info "开始执行编译脚本..."
    
    # 检查环境
    check_env
    
    # 初始化工作空间
    init_workspace
    
    # 恢复缓存
    restore_cache
    
    log_success "编译脚本执行完成"
}

# 如果直接运行此脚本，则执行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
