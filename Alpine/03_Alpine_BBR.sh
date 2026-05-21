#!/bin/sh

# 遇到错误立即停止执行
set -e

# 权限检测：如果当前不是 root 用户（ID不为0），直接报错并退出
if [ "$(id -u)" -ne 0 ]; then
    printf "\033[31m错误：权限不足！请使用 root 用户或通过 doas 运行此脚本 (例如: doas %s)\033[0m\n" "$0"
    exit 1
fi

printf "\033[32m[1/4] 加载 tcp_bbr 内核模块...\033[0m\n"
modprobe tcp_bbr

printf "\033[32m[2/4] 配置开机自动加载 BBR 模块...\033[0m\n"
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

printf "\033[32m[3/4] 写入网络优化配置 (fq + bbr)...\033[0m\n"
cat > /etc/sysctl.d/99-bbr.conf <<'CONFIG'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
CONFIG

printf "\033[32m[4/4] 重新加载 sysctl 配置...\033[0m\n"
sysctl -p /etc/sysctl.d/99-bbr.conf > /dev/null

printf "\033[36m====================================\033[0m\n"
printf "\033[32m✅ BBR 开启成功！当前状态检查：\033[0m\n"
sysctl net.ipv4.tcp_congestion_control
printf "\033[36m====================================\033[0m\n"
