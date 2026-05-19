#!/bin/sh

# 遇到错误立即退出
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==========================================
# 1. 权限与基础工具检查
# ==========================================
# 修复: Alpine 的 sh 不一定支持 $EUID，改用 id -u 检查
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误: 此脚本需要管理员权限。"
    echo "💡 请使用: doas $0 或 sudo $0"
    exit 1
fi

# 检查必要的依赖工具 (Alpine 可能精简了 curl 或 unzip)
for cmd in curl unzip ping sha256sum; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "❌ 错误: 系统未安装 '$cmd' 工具。"
        echo "💡 请先运行: apk add curl unzip iputils"
        exit 1
    fi
done

REPO="Diniboy1123/usque"
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/usr/local/etc/usque"
BIN_NAME="usque"
# 修复: 改为 Alpine/OpenRC 的服务管理目录
SERVICE_FILE="/etc/init.d/usque"

# ==========================================
# 2. IPv6-Only 纯环境检测
# ==========================================
echo "🔍 正在检测网络环境 (IPv4 连通性测试)..."
EXTRA_FLAGS=""
# 修复: Alpine 的 Busybox ping 使用 -w 来指定超时秒数
PING_RES=$(ping -c 1 -w 2 1.1.1.1 2>&1 || true)

if echo "$PING_RES" | grep -q -i "unreachable"; then
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

    if [ "$LOCAL_VERSION" = "$LATEST_TAG" ]; then
        echo "✅ 当前已安装最新版本 ($LOCAL_VERSION)，无需更新，自动退出。"
        exit 0
    else
        echo "🔄 检测到版本升级: ${LOCAL_VERSION:-未知} -> $LATEST_TAG"
        IS_UPDATE=1
    fi
else
    echo "🔍 未检测到现有安装，准备全新部署..."
fi

# ==========================================
# 4. 下载与架构匹配
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

if [ -z "$MATCHED_FILE" ]; then
    echo "❌ 错误: 未能在 Release 中找到匹配当前架构 ($SEARCH_KW) 的文件。"
    exit 1
fi

echo "正在下载: $MATCHED_FILE ..."
curl -L -# -o "$MATCHED_FILE" "https://github.com/$REPO/releases/download/$LATEST_TAG/$MATCHED_FILE"
grep "$MATCHED_FILE" checksums.txt > my_checksum.txt
sha256sum -c -s my_checksum.txt || { echo "❌ 校验失败"; exit 1; }

unzip -q -j "$MATCHED_FILE" "$BIN_NAME"
chmod +x "$BIN_NAME"

# ==========================================
# 5. 执行安装与配置
# ==========================================
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "正在停止 usque 服务以释放文件锁..."
    # 修复: 改用 rc-service 管理服务
    rc-service usque stop 2>/dev/null || true
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    echo "✅ 程序已覆盖更新。"

    echo "正在重启 usque 服务..."
    rc-service usque start
else
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo "正在生成新账号配置..."
        ./"$BIN_NAME" register -a
        mkdir -p "$CONF_DIR"
        mv "config.json" "$CONF_DIR/config.json"
        chmod 600 "$CONF_DIR/config.json"
    fi

    echo "正在配置 OpenRC 服务 (启动参数: $EXTRA_FLAGS)..."
    # 修复: 编写符合 Alpine 规范的 OpenRC 脚本，并自动处理 tun 模块
    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run

name="usque"
description="Usque Native Tunnel Service"
command="$INSTALL_DIR/$BIN_NAME"
command_args="-c $CONF_DIR/config.json nativetun $EXTRA_FLAGS"
command_background=true
pidfile="/run/usque.pid"
# 将 usque 的常规业务日志（标准输出）直接丢弃到黑洞
output_log="/dev/null"
# 强烈建议保留程序的报错日志（标准错误），依然交给 syslog-ng 管理
error_logger="logger -t usque -p daemon.err"

depend() {
    need net
    use dns
}

start_pre() {
    # 确保 TUN 模块已加载 (Alpine 专用优化)
    grep -qxF tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
    modprobe tun 2>/dev/null || true
}
EOF
    
    # 赋予服务脚本执行权限
    chmod +x "$SERVICE_FILE"

    # 修复: 注册并启动 OpenRC 服务
    rc-update add usque default
    rc-service usque start
fi

# ==========================================
# 6. 清理现场
# ==========================================
cd - > /dev/null
rm -rf "$TMP_DIR"

echo "--------------------------------------------------"
echo "🎉 脚本执行完毕！"
echo "当前状态: $(rc-service usque status | awk '{print $NF}')"
echo "日志查看: cat /var/log/usque.log"
echo "--------------------------------------------------"
