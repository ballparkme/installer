#!/bin/bash

# 遇到错误即停止运行
set -e

echo "====================================="
echo "  正在配置系统时间同步与时区 (Asia/Shanghai)"
echo "====================================="

# 1. 更新软件包列表并安装时间同步组件
echo "[1/5] 正在安装 systemd-timesyncd..."
sudo apt update
# 添加了 -y 参数以跳过手动确认，实现自动化
sudo apt install -y systemd-timesyncd

# 2. 启动服务并设置开机自启
echo "[2/5] 启动时间同步服务并配置开机自启..."
sudo systemctl enable --now systemd-timesyncd

# 3. 开启系统 NTP 功能
echo "[3/5] 开启网络时间协议 (NTP) 同步..."
sudo timedatectl set-ntp true

# 4. 设置系统时区
echo "[4/5] 设置系统时区为 Asia/Shanghai (东八区)..."
sudo timedatectl set-timezone Asia/Shanghai

# 5. 打印状态信息
echo "[5/5] 配置完成！当前的系统时间状态如下："
echo "-------------------------------------"
timedatectl status
echo "-------------------------------------"
echo "💡 提示：请检查上方输出中的 'System clock synchronized' 是否为 yes，以及 'NTP service' 是否为 active。"
