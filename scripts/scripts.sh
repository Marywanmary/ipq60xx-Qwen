#!/bin/bash
#
# OpenWrt配置和设备管理脚本
# 包含第三方源配置和设备初始设置
#

# 设置严格模式
set -euo pipefail

# 默认设置
DEFAULT_IP="192.168.111.1"
DEFAULT_USER="root"
DEFAULT_PASSWORD=""
DEFAULT_WIFI_PASSWORD="12345678"

# 添加第三方源
add_third_party_feeds() {
    local repo_path="${1:-}"
    
    if [[ -z "$repo_path" ]] || [[ ! -d "$repo_path" ]]; then
        echo "错误: 无效的仓库路径"
        return 1
    fi
    
    cd "$repo_path" || return 1
    
    # 示例：添加额外的feeds源
    # 注意：实际使用时请根据需要添加或修改
    echo "添加第三方源..."
    
    # 这里可以添加额外的软件包源
    # 例如添加lienol的包
    # echo "src-git lienol https://github.com/Lienol/openwrt-package" >> feeds.conf.default
    
    # 更新feeds
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    
    echo "第三方源添加完成"
}

# 配置设备初始设置
configure_device_initial_settings() {
    local config_file="${1:-}"
    
    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        echo "错误: 无效的配置文件路径"
        return 1
    fi
    
    echo "配置设备初始设置..."
    
    # 在配置文件中添加默认设置
    {
        echo "# 设备初始设置"
        echo "# 管理IP: $DEFAULT_IP"
        echo "# 默认用户: $DEFAULT_USER"
        echo "# 默认密码: $DEFAULT_PASSWORD"
        echo "# 默认WIFI密码: $DEFAULT_WIFI_PASSWORD"
    } >> "$config_file"
    
    echo "设备初始设置配置完成"
}

# 获取内核版本
get_kernel_version() {
    local build_dir="${1:-}"
    
    if [[ -z "$build_dir" ]] || [[ ! -d "$build_dir" ]]; then
        echo "未知"
        return 1
    fi
    
    cd "$build_dir" || return 1
    
    # 尝试从buildinfo文件获取内核版本
    if [[ -f ".config.buildinfo" ]]; then
        grep -oP 'LINUX_VERSION=\K[^\s]+' ".config.buildinfo" 2>/dev/null || echo "未知"
    elif [[ -f "include/kernel-version.mk" ]]; then
        grep -oP 'LINUX_VERSION-\K[^\s]+' "include/kernel-version.mk" 2>/dev/null || echo "未知"
    else
        echo "未知"
    fi
}

# 获取编译的软件包列表
get_compiled_packages() {
    local build_dir="${1:-}"
    
    if [[ -z "$build_dir" ]] || [[ ! -d "$build_dir" ]]; then
        echo "无法获取软件包列表"
        return 1
    fi
    
    cd "$build_dir" || return 1
    
    # 从配置文件中获取启用的Luci应用
    grep -oP 'CONFIG_PACKAGE_luci-app-\K[^=]*' .config | grep -v '=n' | sort -u
}

# 检查配置文件有效性
validate_config() {
    local config_file="${1:-}"
    
    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        echo "错误: 无效的配置文件路径"
        return 1
    fi
    
    echo "验证配置文件: $config_file"
    
    # 检查必需的配置项
    local required_items=(
        "CONFIG_TARGET_"
        "CONFIG_TARGET_DEVICE_"
    )
    
    for item in "${required_items[@]}"; do
        if ! grep -q "$item" "$config_file"; then
            echo "警告: 配置文件中未找到 $item"
        fi
    done
    
    # 检查设备配置
    if ! grep -q "CONFIG_TARGET_DEVICE_.*DEVICE_.*=y" "$config_file"; then
        echo "错误: 配置文件中未找到有效的设备配置"
        return 1
    fi
    
    echo "配置文件验证通过"
}

# 显示设备信息
show_device_info() {
    local config_file="${1:-}"
    
    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        echo "错误: 无效的配置文件路径"
        return 1
    fi
    
    echo "设备信息:"
    
    # 从配置文件中提取设备名称
    grep "CONFIG_TARGET_DEVICE_.*DEVICE_.*=y" "$config_file" | \
    sed -n 's/.*CONFIG_TARGET_DEVICE_.*_DEVICE_\([^=]*\)=y/\1/p' | \
    while read -r device; do
        echo "- $device"
    done
}

# 设置默认网络配置
set_default_network_config() {
    local target_dir="${1:-}"
    
    if [[ -z "$target_dir" ]] || [[ ! -d "$target_dir" ]]; then
        echo "错误: 无效的目标目录"
        return 1
    fi
    
    echo "设置默认网络配置..."
    
    # 创建默认网络配置文件
    local network_config="$target_dir/files/etc/config/network"
    mkdir -p "$(dirname "$network_config")"
    
    cat > "$network_config" << EOF
config interface 'loopback'
    option ifname 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config interface 'lan'
    option ifname 'eth0 eth1'
    option proto 'static'
    option ipaddr '$DEFAULT_IP'
    option netmask '255.255.255.0'
    option gateway '192.168.111.254'
    option dns '8.8.8.8 114.114.114.114'

config interface 'wan'
    option ifname 'eth2'
    option proto 'dhcp'
EOF
    
    echo "默认网络配置设置完成"
}

# 设置默认无线配置
set_default_wireless_config() {
    local target_dir="${1:-}"
    
    if [[ -z "$target_dir" ]] || [[ ! -d "$target_dir" ]]; then
        echo "错误: 无效的目标目录"
        return 1
    fi
    
    echo "设置默认无线配置..."
    
    # 创建默认无线配置文件
    local wireless_config="$target_dir/files/etc/config/wireless"
    mkdir -p "$(dirname "$wireless_config")"
    
    cat > "$wireless_config" << EOF
config wifi-device 'radio0'
    option type 'mac80211'
    option channel '11'
    option hwmode '11g'
    option path 'platform/soc/a000000.wifi'
    option htmode 'HT20'
    option country 'CN'

config wifi-iface 'default_radio0'
    option device 'radio0'
    option network 'lan'
    option mode 'ap'
    option ssid 'OpenWrt'
    option encryption 'psk2'
    option key '$DEFAULT_WIFI_PASSWORD'
EOF
    
    echo "默认无线配置设置完成"
}

# 获取当前日期
get_current_date() {
    date +%Y-%m-%d
}

# 主函数示例
main() {
    echo "OpenWrt配置和设备管理脚本"
    echo "用法: $0 [命令] [参数]"
    echo ""
    echo "可用命令:"
    echo "  add-feeds <repo_path>                    - 添加第三方源"
    echo "  configure-device <config_file>          - 配置设备初始设置"
    echo "  get-kernel-version <build_dir>          - 获取内核版本"
    echo "  get-packages <build_dir>                - 获取编译的软件包列表"
    echo "  validate-config <config_file>           - 验证配置文件"
    echo "  show-device-info <config_file>          - 显示设备信息"
    echo "  set-network-config <target_dir>         - 设置默认网络配置"
    echo "  set-wireless-config <target_dir>        - 设置默认无线配置"
    echo "  get-date                                - 获取当前日期"
}

# 如果直接运行此脚本，则显示帮助信息
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
