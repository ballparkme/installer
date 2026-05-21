#!/bin/sh

echo "========================================="
echo "      Alpine Linux UFW 一键配置脚本      "
echo "========================================="

# 1. 检查 ROOT 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 必须使用 root 权限运行此脚本。"
    exit 1
fi
echo "[INFO] Root 权限检查通过。"

# 2. 获取 SSH 端口
echo "[INFO] 正在获取当前 SSH 端口..."
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')

if [ -z "$SSH_PORT" ]; then
    echo "[错误] 无法获取 SSH 端口，为防止断网，脚本安全退出。"
    exit 1
fi
echo "[INFO] 成功检测到 SSH 端口: $SSH_PORT"

# 3. 通过 apk 安装 UFW (带上 iptables 依赖，Alpine 常需)
if ! command -v ufw >/dev/null 2>&1; then
    echo "[INFO] 未检测到 UFW，正在通过 apk 安装..."
    apk update && apk add ufw iptables ip6tables
    
    # 检查安装是否成功
    if ! command -v ufw >/dev/null 2>&1; then
        echo "[错误] UFW 安装失败，脚本退出。"
        exit 1
    fi
else
    echo "[INFO] UFW 已经安装，跳过安装步骤。"
fi

# 4. 配置 UFW 规则
echo "[INFO] 正在配置防火墙规则..."
ufw default deny incoming  # 默认禁止入站
ufw default allow outgoing # 默认允许出站

# 采用 limit 规则放行并保护 SSH
ufw limit "${SSH_PORT}/tcp"

# 5. 激活 UFW 防火墙
echo "[INFO] 正在激活 UFW 防火墙..."
ufw --force enable

# 6. 配置 OpenRC 系统服务
echo "[INFO] 正在配置开机自启并启动后台服务..."
rc-update add ufw boot
rc-service ufw start >/dev/null 2>&1 || true

echo ""
echo "========================================="
echo "✅ UFW 配置全部完成！当前状态如下："
echo "========================================="
ufw status verbose
