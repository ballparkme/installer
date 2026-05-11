#!/bin/bash

# ==========================================
# UFW 自动化配置脚本 V5 (生产环境终极完善版)
# ==========================================

set -uo pipefail

# --- 日志函数 ---
log_info()    { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn()    { echo -e "\e[33m[WARN]\e[0m $1"; }
log_error()   { echo -e "\e[31m[ERROR]\e[0m $1"; >&2; }
log_success() { echo -e "\e[36m[SUCCESS]\e[0m $1"; }

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
   log_error "权限不足！请使用 root 权限运行此脚本 (例如: sudo bash $0)"
   exit 1
fi

log_info "开始执行 UFW 防火墙自动化配置..."

# 2. 通用依赖检查与自动安装函数
check_and_install() {
    local cmd=$1
    local pkg=$2
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_warn "未检测到命令: $cmd。准备尝试自动安装包: $pkg ..."
        if command -v apt-get >/dev/null 2>&1; then
            # 更新软件源并静默安装
            apt-get update -qq && apt-get install -y "$pkg" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_success "依赖包 $pkg 自动安装成功。"
            else
                log_error "依赖包 $pkg 自动安装失败，请检查网络或手动安装。"
                exit 1
            fi
        else
            log_error "当前系统未检测到 apt-get (非 Debian/Ubuntu 系)，无法自动安装 $pkg。请手动安装后重试。"
            exit 1
        fi
    fi
}

# 检查并安装核心依赖
check_and_install ufw ufw
check_and_install ss iproute2

# 3. 多重策略检测 SSH 端口
get_ssh_port() {
    local port=""

    # 策略 A: 精准抓取 ss 状态 (严格匹配 "sshd" 进程)
    # 处理 IPv4 (0.0.0.0:22) 和 IPv6 ([::]:22 或 *:22) 格式
    port=$(ss -tlnp 2>/dev/null | grep '"sshd"' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)

    # 策略 B: 如果 ss 未抓取到，尝试 sshd -T
    if [[ -z "$port" ]]; then
        port=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n 1)
    fi

    # 策略 C: 降级方案，直接用正则硬抓配置文件 (过滤掉注释)
    if [[ -z "$port" && -f /etc/ssh/sshd_config ]]; then
        port=$(grep -iE '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    fi

    # 最终 Fallback: 如果一切都失败，或者获取到的不是纯数字
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        log_warn "无法通过常规手段检测到 SSH 端口，回退至默认端口: 22"
        port=22
    fi

    echo "$port"
}

SSH_PORT=$(get_ssh_port)
log_success "确认当前 SSH 端口为: ${SSH_PORT}"

# 4. 配置 UFW 规则
log_info "正在写入规则 (UFW 会自动为 IPv4 和 IPv6 添加规则)..."

if ! ufw allow "${SSH_PORT}/tcp" >/dev/null; then
    log_error "放行 ${SSH_PORT}/tcp 端口失败！"
    exit 1
fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# 5. 启用 UFW 服务 (应用规则 + 系统级自启)
log_info "正在启用 UFW 防火墙与系统服务..."

# 第一步：启用 UFW 内部状态（修改 ufw.conf 并加载 iptables 规则）
# --force 跳过终端中断确认提示
if ! ufw --force enable >/dev/null; then
    log_error "UFW 启用失败！请检查系统内核或模块。"
    exit 1
fi

# 第二步：在 Systemd 层面设置开机自启并立即启动守护进程
if command -v systemctl >/dev/null 2>&1; then
    if systemctl enable --now ufw >/dev/null 2>&1; then
        log_success "Systemd: ufw.service 已配置为开机自启并立即运行。"
    else
        log_warn "Systemd 设为自启失败（如果您在 Docker/LXC 容器中运行，可忽略此警告）。"
    fi
fi

# 6. 显示状态与收尾
echo ""
log_success "UFW 防火墙配置已就绪！当前状态如下："
echo "------------------------------------------------"
ufw status verbose
echo "------------------------------------------------"
echo -e "\e[1;33m⚠️  重要提醒：您当前的 SSH 端口是 【 ${SSH_PORT} 】，请确保连接时使用此端口！\e[0m"
echo ""
