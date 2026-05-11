#!/bin/bash

# 遇到错误立即退出
set -e

# ==========================================
# 1. 权限与基础工具检查
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误: 此脚本需要管理员权限。"
    echo "💡 请使用: sudo $0"
    exit 1
fi

if ! command -v ping >/dev/null 2>&1; then
    echo "❌ 错误: 系统未安装 'ping' 工具，无法进行网络环境检测。请先安装 iputils-ping 或类似工具。"
    exit 1
fi

REPO="Diniboy1123/usque"
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/usr/local/etc/usque"
BIN_NAME="usque"
SERVICE_FILE="/etc/systemd/system/usque.service"

# ==========================================
# 2. IPv6-Only 纯环境检测
# ==========================================
echo "🔍 正在检测网络环境 (IPv4 连通性测试)..."
EXTRA_FLAGS=""
PING_RES=$(ping -c 1 -W 2 1.1.1.1 2>&1 || true)

if echo "$PING_RES" | grep -q "Network is unreachable"; then
    echo "🌐 检测到当前主机为【纯 IPv6 (IPv6-Only)】环境。"
    EXTRA_FLAGS="-6"
else
    echo "🌐 检测到当前主机支持 IPv4 或双栈网络。"
fi

# ==========================================
# 3. 版本检测与极速拦截 (核心修复区)
# ==========================================
echo "正在获取云端最新版本信息..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 错误: 无法获取云端版本号。"
    exit 1
fi

IS_UPDATE=0
if [ -x "$INSTALL_DIR/$BIN_NAME" ]; then
    LOCAL_VERSION=$("$INSTALL_DIR/$BIN_NAME" version 2>&1 | grep "usque version:" | awk '{print $3}' || true)

    if [ "$LOCAL_VERSION" == "$LATEST_TAG" ]; then
        echo "✅ 当前已安装最新版本 ($LOCAL_VERSION)，无需更新，自动退出。"
        exit 0  # 版本一致时，直接在这里结束脚本
    else
        echo "🔄 检测到版本升级: ${LOCAL_VERSION:-未知} -> $LATEST_TAG"
        IS_UPDATE=1
    fi
else
    echo "🔍 未检测到现有安装，准备全新部署..."
fi

# ==========================================
# 4. 下载与架构匹配 (只有需要安装/更新才会执行到这里)
# ==========================================
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

echo "正在匹配系统架构..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64 | amd64)    SEARCH_KW="amd64" ;;
    aarch64 | arm64)   SEARCH_KW="arm64" ;;
    armv7* | armv8l)   SEARCH_KW="armv7" ;;
    *)                 SEARCH_KW="$ARCH" ;;
esac

curl -L -s -o "checksums.txt" "https://github.com/$REPO/releases/download/$LATEST_TAG/checksums.txt"
MATCHED_FILE=$(grep "linux.*$SEARCH_KW.*\.zip" checksums.txt | awk '{print $2}' | head -n 1)

echo "正在下载: $MATCHED_FILE ..."
curl -L -# -o "$MATCHED_FILE" "https://github.com/$REPO/releases/download/$LATEST_TAG/$MATCHED_FILE"
grep "$MATCHED_FILE" checksums.txt > my_checksum.txt
sha256sum -c my_checksum.txt --status || { echo "❌ 校验失败"; exit 1; }

unzip -q -j "$MATCHED_FILE" "$BIN_NAME"
chmod +x "$BIN_NAME"

# ==========================================
# 5. 执行安装与配置
# ==========================================
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "正在停止 usque 服务以释放文件锁..."
    systemctl stop usque 2>/dev/null || true
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    echo "✅ 程序已覆盖更新。"

    echo "正在重启 usque 服务..."
    systemctl daemon-reload
    systemctl start usque
else
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo "正在生成新账号配置..."
        ./"$BIN_NAME" register -a
        mkdir -p "$CONF_DIR"
        mv "config.json" "$CONF_DIR/config.json"
        chmod 600 "$CONF_DIR/config.json"
    fi

    echo "正在配置 Systemd 服务 (启动参数: $EXTRA_FLAGS)..."
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Usque Native Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$BIN_NAME -c $CONF_DIR/config.json nativetun $EXTRA_FLAGS
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable usque
    systemctl start usque
fi

# ==========================================
# 6. 清理现场
# ==========================================
cd - > /dev/null
rm -rf "$TMP_DIR"

echo "--------------------------------------------------"
echo "🎉 脚本执行完毕！"
echo "当前状态: $(systemctl is-active usque)"
echo "--------------------------------------------------"
