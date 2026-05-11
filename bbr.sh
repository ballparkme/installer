#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行此脚本 (例如: sudo ./enable_bbr.sh)"
  exit 1
fi

echo "正在配置并开启 BBR..."

# 将配置写入 99-bbr.conf 文件
tee /etc/sysctl.d/99-bbr.conf > /dev/null <<EOF
# 使用 BBR 拥塞控制
net.ipv4.tcp_congestion_control = bbr

# 默认队列调度器
net.core.default_qdisc = fq
EOF

# 使配置生效
echo "正在应用 sysctl 配置..."
sysctl --system

# 验证 BBR 是否成功开启
echo "-----------------------------------"
echo "当前系统的拥塞控制算法为："
sysctl net.ipv4.tcp_congestion_control
