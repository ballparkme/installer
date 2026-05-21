#!/bin/sh

# 遇到错误即停止执行
set -e

echo "========== 开始初始化 Alpine Linux =========="

echo "[1/4] 正在设置时区为 上海 (Asia/Shanghai)..."
setup-timezone -z Asia/Shanghai

echo "[2/4] 正在自动寻找并设置最快的 APK 镜像源..."
> /etc/apk/repositories
setup-apkrepos -cf

echo "[3/4] 正在更新系统并安装必要组件..."
apk update 
apk upgrade 
apk add nano curl iperf3 dos2unix zstd doas logrotate wget iputils unzip htop fastfetch util-linux bash

echo "[4/4] 正在初始化用户..."
# 注意：setup-user 默认是交互式命令，运行到这里时会暂停并要求你输入新用户名和密码
setup-user

echo "========== 系统初始化配置完成！ =========="
