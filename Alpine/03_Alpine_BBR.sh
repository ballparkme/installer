#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

echo "[1/5] 检查 BBR 支持..."

if ! modprobe tcp_bbr 2>/dev/null; then
    echo "当前内核不支持 BBR"
    exit 1
fi

echo "[2/5] 配置模块自动加载..."
echo tcp_bbr > /etc/modules-load.d/bbr.conf

echo "[3/5] 写入 sysctl..."
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

echo "[4/5] 应用 sysctl..."
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null

echo "[5/5] 验证状态..."
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc

echo "完成"
