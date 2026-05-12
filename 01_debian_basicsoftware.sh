#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限或 sudo 运行此脚本。"
  exit 1
fi

echo "🔄 开始更新软件包列表并升级系统..."
apt update
apt upgrade -y

echo ""
echo "=================================================="
echo "🧹 清理系统组件"
echo "=================================================="

# 检测并自动删除 rsyslog
if dpkg -s rsyslog >/dev/null 2>&1; then
    echo "🗑️ 检测到系统已安装 rsyslog，正在自动卸载..."
    apt purge -y rsyslog
    # 可选：清理因此产生的无用依赖
    apt autoremove -y
    echo "✅ rsyslog 已成功卸载。"
else
    echo "⏭️ 系统未安装 rsyslog，无需清理。"
fi

# 默认必装的包列表（排除了 ufw, fail2ban 和 nftables）
PACKAGES="nano curl iperf3 dos2unix zstd cron sudo logrotate wget iputils-ping unzip unattended-upgrades htop fastfetch needrestart"

echo ""
echo "=================================================="
echo "📦 开始安装软件包"
echo "=================================================="
echo "即将安装以下组件: "
echo "$PACKAGES"
echo "--------------------------------------------------"

# 执行安装命令
apt install -y $PACKAGES

echo ""
echo "🎉 所有清理与安装任务已完成！"
