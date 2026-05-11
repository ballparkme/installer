#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限或 sudo 运行此脚本。"
  exit 1
fi

echo "🔄 开始更新软件包列表并升级系统..."
apt update
apt upgrade -y

# 默认必装的包列表（排除了 ufw, fail2ban 和 nftables）
PACKAGES="nano curl iperf3 dos2unix zstd cron sudo logrotate wget iputils-ping unzip unattended-upgrades htop fastfetch needrestart"

echo ""
echo "=================================================="
echo "🛡️  防火墙与安全配置"
echo "=================================================="

# 询问是否安装 UFW
read -p "❓ 是否需要安装防火墙 (ufw)? [y/N]: " choice_ufw

if [[ "$choice_ufw" =~ ^[Yy]$ ]]; then
    echo "✅ 已将 ufw 加入安装列表。"
    PACKAGES="$PACKAGES ufw"
    
    # 只有在选择安装 ufw 的情况下，才询问是否安装 fail2ban
    read -p "❓ 是否需要安装 fail2ban 及 nftables 来防御爆破攻击? [y/N]: " choice_f2b
    if [[ "$choice_f2b" =~ ^[Yy]$ ]]; then
        echo "✅ 已将 fail2ban 和 nftables 加入安装列表。"
        PACKAGES="$PACKAGES fail2ban nftables"
    else
        echo "⏭️ 已跳过 fail2ban 和 nftables。"
    fi
else
    echo "⏭️ 已跳过防火墙配置，fail2ban 也会默认不安装。"
fi

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
echo "🎉 所有安装任务已完成！"
