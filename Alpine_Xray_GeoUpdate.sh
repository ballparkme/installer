#!/bin/sh

# 明确声明 PATH，确保在 cron 计划任务等非交互环境中也能正常执行命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 定义安装路径（如果环境变量中有 DAT_PATH 则使用，否则使用默认值）
DAT_PATH=${DAT_PATH:-/usr/local/share/xray}

# 定义 Loyalsoldier 的最新 geodata 下载链接
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

echo "Checking dependencies..."
# 检查是否安装了 curl，如果没有则自动使用 apk 安装
if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found, installing via apk..."
    apk add --no-cache curl
fi

# 创建临时目录
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR" || { echo "Failed to create temp directory"; exit 1; }

echo "Downloading geoip.dat and geosite.dat..."
# 使用 curl 下载文件及其校验和
curl -L -q --retry 3 -O "$GEOIP_URL"
curl -L -q --retry 3 -O "${GEOIP_URL}.sha256sum"
curl -L -q --retry 3 -O "$GEOSITE_URL"
curl -L -q --retry 3 -O "${GEOSITE_URL}.sha256sum"

echo "Verifying checksums..."
# 验证下载文件的完整性
if ! sha256sum -c geoip.dat.sha256sum || ! sha256sum -c geosite.dat.sha256sum; then
    echo "Error: SHA256 checksum validation failed! Aborting."
    cd - >/dev/null || exit 1
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "Checksums verified successfully."

echo "Installing geodata to $DAT_PATH..."
# 确保目标目录存在
mkdir -p "$DAT_PATH"

# 将文件安装到指定目录并设置 644 权限
install -m 644 geoip.dat "$DAT_PATH/geoip.dat"
install -m 644 geosite.dat "$DAT_PATH/geosite.dat"

# 清理临时文件
cd - >/dev/null || exit 1
rm -rf "$TMP_DIR"

echo "Update completed successfully!"
echo "------------------------------------------------------"

# 自动重启 Xray 服务
if command -v rc-service >/dev/null 2>&1; then
    echo "Restarting Xray service via OpenRC..."
    # 尝试重启，如果服务没运行或报错，会提示 fallback 信息
    rc-service xray restart || echo "Warning: Could not restart Xray. Is the service name correct?"
else
    # 针对 Alpine Docker 容器环境的提示（Docker 容器内通常没有 rc-service）
    echo "Notice: 'rc-service' command not found."
    echo "If you are running this inside a Docker container, please restart the container to apply the new dat files."
fi
