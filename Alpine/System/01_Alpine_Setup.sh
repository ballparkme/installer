#!/bin/sh

# 遇到错误即停止执行
set -e

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m错误: 请使用 root 权限运行此脚本 (例如: doas $0 或 sudo $0)\033[0m"
    exit 1
fi

echo "========== 开始初始化 Alpine Linux =========="

echo "[1/5] 正在配置 APK 镜像源 (使用官方全球 CDN)..."
> /etc/apk/repositories
setup-apkrepos -c -1

echo "[2/5] 正在设置时区为 上海 (Asia/Shanghai)..."
setup-timezone -z Asia/Shanghai

echo "[3/5] 正在更新系统并安装必要组件..."
apk update 
apk fix        # 把修复命令独立出来，清理上次遗留的损坏包
apk upgrade    # 然后再正常升级系统
# 安装的包里已经包含了 bash 和 coreutils
apk add nano curl iperf3 dos2unix zstd doas logrotate wget iputils unzip htop fastfetch util-linux bash coreutils

echo "[4/5] 正在配置全局 Bash 终端高亮..."
# 在 /etc/profile.d/ 下创建全局配置文件，对所有系统用户生效
cat << 'EOF' > /etc/profile.d/custom_bash.sh
# 仅当使用 bash 时才加载高亮，避免干扰系统默认的轻量级 ash
if [ -n "$BASH_VERSION" ]; then
    export PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    alias ls='ls --color=auto'
fi
EOF

# 给全局配置文件赋予执行权限
chmod +x /etc/profile.d/custom_bash.sh

echo "========== 系统初始化配置完成！ =========="
