#!/bin/sh

# 遇到错误即停止执行
set -e

echo "========== 开始初始化 Alpine Linux =========="

# 【调换顺序】先修好软件源，这是所有后续操作的基础
echo "[1/4] 正在配置 APK 镜像源 (使用官方全球 CDN)..."
> /etc/apk/repositories
setup-apkrepos -c -1

# 【调换顺序】现在有稳定的源了，再去下载时区包
echo "[2/4] 正在设置时区为 上海 (Asia/Shanghai)..."
setup-timezone -z Asia/Shanghai

echo "[3/4] 正在更新系统并安装必要组件..."
# 加上 --fix 参数，顺手修复一下第一次运行残留下来的损坏包状态
apk update 
apk upgrade -a --fix
apk add nano curl iperf3 dos2unix zstd doas logrotate wget iputils unzip htop fastfetch util-linux bash

echo "[4/4] 正在初始化用户..."
setup-user

echo "========== 系统初始化配置完成！ =========="
