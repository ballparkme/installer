#!/bin/sh

# 遇到错误即停止执行
set -e

echo "========== 开始初始化 Alpine Linux =========="

echo "[1/4] 正在配置 APK 镜像源 (使用官方全球 CDN)..."
> /etc/apk/repositories
setup-apkrepos -c -1

echo "[2/4] 正在设置时区为 上海 (Asia/Shanghai)..."
setup-timezone -z Asia/Shanghai

echo "[3/4] 正在更新系统并安装必要组件..."
apk update 
apk fix        # 把修复命令独立出来，清理上次遗留的损坏包
apk upgrade    # 然后再正常升级系统
apk add nano curl iperf3 dos2unix zstd doas logrotate wget iputils unzip htop fastfetch util-linux bash

echo "[4/4] 正在初始化用户..."
setup-user

echo "========== 系统初始化配置完成！ =========="
