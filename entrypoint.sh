#!/bin/sh

# ==================== 默认配置参数 ====================
# VPN 配置
VPN_CONFIG_PATH=${VPN_CONFIG_PATH:-/etc/openfortivpn/config}
VPN_LOG_PATH=${VPN_LOG_PATH:-/var/log/openfortivpn}
VPN_LOG_FILE="${VPN_LOG_PATH}/openfortivpn.log"

# VPN 接口名称
VPN_INTERFACE=${VPN_INTERFACE:-openfortivpn}

# LAN 接口（用于 iptables FORWARD 规则）
LAN_INTERFACE=${LAN_INTERFACE:-br0}

# 超时配置
MAX_WAIT_INTERFACE=${MAX_WAIT_INTERFACE:-30}
MAX_WAIT_IP=${MAX_WAIT_IP:-60}
RECHECK_INTERVAL=${RECHECK_INTERVAL:-2}
PROCESS_CHECK_INTERVAL=${PROCESS_CHECK_INTERVAL:-10}
RESTART_DELAY=${RESTART_DELAY:-5}
STARTUP_FAIL_DELAY=${STARTUP_FAIL_DELAY:-10}

# ==================== 全局变量 ====================
VPN_PID=""
RESTART_COUNT=0

# ==================== 日志函数 ====================
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $@"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $@" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $@" >&2
}

# ==================== 工具函数 ====================

# 检查进程是否存活
check_process() {
    pid=$1
    if [ -z "$pid" ]; then
        return 1
    fi
    if kill -0 $pid 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取接口 IP 地址
get_interface_ip() {
    interface=$1
    ip -4 addr show $interface 2>/dev/null | grep -o 'inet [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | \
        awk '{print $2}' | head -1
}

# 检查接口状态
is_interface_up() {
    interface=$1
    state=$(ip link show $interface 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')
    if [ "$state" = "UP" ] || [ "$state" = "UNKNOWN" ]; then
        return 0
    fi
    return 1
}

# ==================== 清理函数 ====================

# 清理 iptables 规则
cleanup_iptables() {
    log_info "Cleaning up iptables rules..."
    iptables-legacy -t nat -D POSTROUTING -o $VPN_INTERFACE -j MASQUERADE 2>/dev/null
    iptables-legacy -D FORWARD -i $LAN_INTERFACE -o $VPN_INTERFACE -j ACCEPT 2>/dev/null
}

# 清理 VPN 接口
cleanup_interface() {
    log_info "Cleaning up VPN interface..."
    if ip link show $VPN_INTERFACE >/dev/null 2>&1; then
        ip link delete $VPN_INTERFACE 2>/dev/null
    fi
}

# 完整清理
full_cleanup() {
    log_info "Performing full cleanup..."
    cleanup_iptables
    cleanup_interface
    
    if [ -n "$VPN_PID" ] && check_process $VPN_PID; then
        log_info "Stopping openfortivpn process (PID: $VPN_PID)..."
        kill -TERM $VPN_PID 2>/dev/null
        sleep 2
        if check_process $VPN_PID; then
            kill -KILL $VPN_PID 2>/dev/null
        fi
        wait $VPN_PID 2>/dev/null
    fi
}

# ==================== VPN 就绪检测 ====================

# 等待 VPN 就绪
wait_for_vpn_ready() {
    elapsed=0
    
    # 等待接口出现
    log_info "Waiting for interface '$VPN_INTERFACE' to appear..."
    while [ $elapsed -lt $MAX_WAIT_INTERFACE ]; do
        if ip link show $VPN_INTERFACE >/dev/null 2>&1; then
            log_info "Interface detected after ${elapsed} seconds"
            break
        fi
        
        if ! check_process $VPN_PID; then
            log_error "VPN process died during interface detection"
            return 1
        fi
        
        sleep $RECHECK_INTERVAL
        elapsed=$((elapsed + RECHECK_INTERVAL))
    done
    
    if [ $elapsed -ge $MAX_WAIT_INTERFACE ]; then
        log_error "Interface not detected after ${MAX_WAIT_INTERFACE} seconds"
        return 1
    fi
    
    # 等待 IP 分配
    log_info "Waiting for IP address assignment..."
    elapsed=0
    while [ $elapsed -lt $MAX_WAIT_IP ]; do
        vpn_ip=$(get_interface_ip $VPN_INTERFACE)
        
        if [ -n "$vpn_ip" ] && [ "$vpn_ip" != "0.0.0.0" ]; then
            log_info "IP address assigned: $vpn_ip after ${elapsed} seconds"
            sleep 2
            return 0
        fi
        
        if ! check_process $VPN_PID; then
            log_error "VPN process died during IP assignment"
            return 1
        fi
        
        sleep $RECHECK_INTERVAL
        elapsed=$((elapsed + RECHECK_INTERVAL))
    done
    
    log_error "Failed to obtain IP after ${MAX_WAIT_IP} seconds"
    return 1
}

# ==================== iptables 配置 ====================

# 添加 iptables 规则
setup_iptables() {
    log_info "Setting up iptables rules..."
    
    # 添加 MASQUERADE 规则
    if iptables-legacy -t nat -A POSTROUTING -o $VPN_INTERFACE -j MASQUERADE 2>/dev/null; then
        log_info "MASQUERADE rule added"
    else
        log_error "Failed to add MASQUERADE rule"
        return 1
    fi
    
    # 添加 FORWARD 规则
    if iptables-legacy -A FORWARD -i $LAN_INTERFACE -o $VPN_INTERFACE -j ACCEPT 2>/dev/null; then
        log_info "FORWARD rule added ($LAN_INTERFACE -> $VPN_INTERFACE)"
    else
        log_warn "Failed to add FORWARD rule (interface $LAN_INTERFACE may not exist)"
    fi
    
    # 添加 conntrack 规则
    if iptables-legacy -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        log_info "Conntrack rule added"
    else
        log_warn "Failed to add conntrack rule"
    fi
    
    return 0
}

# 配置 IP 转发
setup_ip_forward() {
    log_info "Checking IP forwarding status..."
    
    # 检查当前状态
    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [ "$current" = "1" ]; then
        log_info "IP forwarding already enabled"
        return 0
    fi
    
    # 尝试启用 IP 转发
    log_info "Attempting to enable IP forwarding..."
    
    # 方法1：直接写入
    if echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
        log_info "IP forwarding enabled successfully"
        return 0
    fi
    
    # 方法2：使用 sysctl
    if sysctl -w net.ipv4.ip_forward=1 2>/dev/null; then
        log_info "IP forwarding enabled via sysctl"
        return 0
    fi
    
    # 如果都失败，尝试检查权限
    log_error "Failed to enable IP forwarding. Current value: $current"
    log_error "This usually means the container lacks sufficient privileges."
    log_error "Make sure to run with: --privileged or --cap-add=NET_ADMIN"
    return 1
}

# ==================== VPN 进程管理 ====================

# 启动 openfortivpn
start_openfortivpn() {
    log_info "Starting openfortivpn..."
    
    if [ ! -f "$VPN_CONFIG_PATH" ]; then
        log_error "VPN config file not found at $VPN_CONFIG_PATH"
        return 1
    fi
    
    # 创建日志目录
    mkdir -p "$VPN_LOG_PATH"
    
    # 清理旧接口
    cleanup_interface
    
    # 启动 VPN
    openfortivpn -c "$VPN_CONFIG_PATH" > "$VPN_LOG_FILE" 2>&1 &
    VPN_PID=$!
    
    log_info "openfortivpn started with PID: $VPN_PID"
    
    # 等待 VPN 就绪
    if ! wait_for_vpn_ready; then
        log_error "VPN failed to become ready"
        return 1
    fi
    
    # 显示路由信息
    log_info "Current VPN routes:"
    ip route show | grep "$VPN_INTERFACE" | while read line; do
        log_info "  $line"
    done
    
    # 设置 iptables
    setup_iptables
    
    log_info "VPN is fully operational"
    return 0
}

# ==================== 主循环 ====================

# 信号处理
signal_handler() {
    log_info "Received termination signal"
    full_cleanup
    exit 0
}

# 检查权限
check_permissions() {
    # 检查是否具有 NET_ADMIN 能力
    if ! ip link set lo up 2>/dev/null; then
        log_error "Container lacks NET_ADMIN capability"
        log_error "Please run with: --cap-add=NET_ADMIN or --privileged"
        return 1
    fi
    
    # 检查 iptables 权限
    if ! iptables-legacy -L -n >/dev/null 2>&1; then
        log_error "Container cannot run iptables commands"
        log_error "Please run with: --cap-add=NET_ADMIN or --privileged"
        return 1
    fi
    
    return 0
}

# 主函数
main() {
    log_info "========================================="
    log_info "OpenFortiVPN Docker Container Starting"
    log_info "========================================="
    log_info "VPN Config: $VPN_CONFIG_PATH"
    log_info "VPN Log: $VPN_LOG_FILE"
    log_info "VPN Interface: $VPN_INTERFACE"
    log_info "LAN Interface: $LAN_INTERFACE"
    log_info "========================================="
    
    # 检查依赖
    for cmd in openfortivpn iptables-legacy ip; do
        if ! command -v $cmd >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # 检查权限
    if ! check_permissions; then
        exit 1
    fi
    
    # 设置信号处理
    trap signal_handler TERM INT QUIT
    
    # 启用 IP 转发
    if ! setup_ip_forward; then
        log_error "IP forwarding is required for NAT to work"
        log_error "Container will continue but NAT may not function correctly"
        # 不退出，让容器继续运行，但记录警告
    fi
    
    # 主循环
    while true; do
        RESTART_COUNT=$((RESTART_COUNT + 1))
        log_info "Starting VPN (attempt #$RESTART_COUNT)..."
        
        if start_openfortivpn; then
            log_info "VPN is running (PID: $VPN_PID), monitoring..."
            
            # 监控循环
            while true; do
                sleep $PROCESS_CHECK_INTERVAL
                
                if ! check_process $VPN_PID; then
                    log_warn "VPN process is no longer running"
                    break
                fi
                
                # 检查健康状态
                if ! ip link show $VPN_INTERFACE >/dev/null 2>&1; then
                    log_warn "VPN interface is missing"
                    kill -TERM $VPN_PID 2>/dev/null
                    sleep 2
                    break
                fi
            done
            
            log_info "VPN needs restart, cleaning up..."
            full_cleanup
            sleep $RESTART_DELAY
        else
            log_error "Failed to start VPN, retrying in ${STARTUP_FAIL_DELAY} seconds..."
            sleep $STARTUP_FAIL_DELAY
        fi
    done
}

# 运行主函数
main
