#!/bin/sh

# 遇到错误立即退出
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==========================================
# 1. 权限与基础工具检查
# ==========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误: 此脚本需要管理员权限。"
    echo "💡 请使用: doas $0 或 sudo $0"
    exit 1
fi

for cmd in curl unzip sha256sum awk tr netstat ip; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "❌ 错误: 系统未安装 '$cmd' 工具。"
        echo "💡 请先运行: apk add curl unzip busybox iproute2"
        exit 1
    fi
done

REPO="Diniboy1123/usque"
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/usr/local/etc/usque"
BIN_NAME="usque"
SERVICE_FILE="/etc/init.d/usque"
ROUTER_SVC_FILE="/etc/init.d/usque-router"
ROUTER_BIN="/usr/local/bin/usque-router.sh"

# ==========================================
# 2. 版本检测与更新判定
# ==========================================
echo "☁️ 正在获取 usque 云端最新版本信息..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 错误: 无法获取云端版本号。"
    exit 1
fi

IS_UPDATE=0
if [ -x "$INSTALL_DIR/$BIN_NAME" ]; then
    LOCAL_VERSION=$("$INSTALL_DIR/$BIN_NAME" version 2>&1 | grep "usque version:" | awk '{print $3}' || true)

    if [ "$LOCAL_VERSION" = "$LATEST_TAG" ]; then
        echo "✅ 当前已安装最新版本 ($LOCAL_VERSION)，无需更新。"
    else
        echo "🔄 检测到版本升级: ${LOCAL_VERSION:-未知} -> $LATEST_TAG"
        IS_UPDATE=1
    fi
else
    echo "🔍 未检测到现有安装，准备全新部署..."
fi

# ==========================================
# 3. 交互配置 (仅全新安装时触发)
# ==========================================
if [ "$IS_UPDATE" -eq 0 ]; then
    # 判定是否为 LXC 容器
    IS_LXC=0
    if [ -f /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ | grep -q '^container=lxc$'; then
        IS_LXC=1
    elif grep -qi 'lxc' /proc/1/cgroup 2>/dev/null; then
        IS_LXC=1
    elif [ -c /dev/lxc/console ]; then
        IS_LXC=1
    fi

    if [ "$IS_LXC" -eq 1 ]; then
        echo "📦 检测到当前系统为【LXC 容器】环境，将采用 SOCKS 模式。"
        while true; do
            printf "👉 请输入 usque SOCKS 代理绑定的端口号 (1-65535，无默认值): "
            read INPUT_PORT
            INPUT_PORT=$(echo "$INPUT_PORT" | tr -d ' ')
            
            if [ -z "$INPUT_PORT" ]; then echo "❌ 不能为空！"; continue; fi
            if ! echo "$INPUT_PORT" | grep -Eq '^[0-9]+$'; then echo "❌ 必须是纯数字！"; continue; fi
            if [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then echo "❌ 超出范围！"; continue; fi
            if netstat -tuln | awk '{print $4}' | grep -qE ":${INPUT_PORT}$"; then echo "❌ 端口 $INPUT_PORT 已被占用！"; continue; fi
            
            echo "✅ 端口 $INPUT_PORT 校验通过！"
            SVC_ARGS="-c $CONF_DIR/config.json socks -b 127.0.0.1 -p $INPUT_PORT --always-reconnect"
            break
        done
    else
        echo "🖥️ 检测到当前系统为【KVM / 物理机】环境。"
        echo "=================================================="
        echo "请选择当前机器的网络环境："
        echo "  1) IPv4 + IPv6 (双栈)       - 保持正常路由"
        echo "  2) IPv6 Only (纯IPv6)     - 将增加守护进程，把 IPv4 默认路由指给 tun0"
        echo "  3) IPv4 Only (纯IPv4)     - 将增加守护进程，把 IPv6 默认路由指给 tun0"
        echo "=================================================="
        while true; do
            printf "👉 请输入对应数字 (1/2/3): "
            read NET_CHOICE
            case "$NET_CHOICE" in
                1)
                    SVC_ARGS="-c $CONF_DIR/config.json nativetun"
                    ROUTE_MODE="none"
                    break ;;
                2)
                    SVC_ARGS="-c $CONF_DIR/config.json nativetun -6"
                    ROUTE_MODE="v6only"
                    break ;;
                3)
                    SVC_ARGS="-c $CONF_DIR/config.json nativetun"
                    ROUTE_MODE="v4only"
                    break ;;
                *)
                    echo "❌ 无效输入，请输入 1、2 或 3。" ;;
            esac
        done
        echo "✅ 网络环境配置已记录。"
    fi
fi

# ==========================================
# 4. 下载与部署 (更新时仅覆盖二进制)
# ==========================================
if [ "$IS_UPDATE" -eq 1 ] || [ ! -x "$INSTALL_DIR/$BIN_NAME" ]; then
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | amd64)    SEARCH_KW="amd64" ;;
        aarch64 | arm64)   SEARCH_KW="arm64" ;;
        armv7* | armv8l)   SEARCH_KW="armv7" ;;
        *)                 SEARCH_KW="$ARCH" ;;
    esac

    curl -L -s -o "checksums.txt" "https://github.com/$REPO/releases/download/$LATEST_TAG/checksums.txt"
    MATCHED_FILE=$(grep "linux.*$SEARCH_KW.*\.zip" checksums.txt | awk '{print $2}' | head -n 1)

    echo "🚀 正在下载: $MATCHED_FILE ..."
    curl -L -# -o "$MATCHED_FILE" "https://github.com/$REPO/releases/download/$LATEST_TAG/$MATCHED_FILE"
    grep "$MATCHED_FILE" checksums.txt > my_checksum.txt
    sha256sum -c -s my_checksum.txt >/dev/null || { echo "❌ 校验失败"; exit 1; }

    unzip -q -j "$MATCHED_FILE" "$BIN_NAME"
    chmod +x "$BIN_NAME"

    echo "⚙️ 正在停止 usque 服务以释放文件锁..."
    rc-service usque stop 2>/dev/null || true
    rc-service usque-router stop 2>/dev/null || true
    
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"

    # 新装时：初始化配置、服务和路由守护进程
    if [ "$IS_UPDATE" -eq 0 ]; then
        if [ ! -f "$CONF_DIR/config.json" ]; then
            echo "⚙️ 正在生成新账号配置..."
            ./"$BIN_NAME" register -a
            mkdir -p "$CONF_DIR"
            mv "config.json" "$CONF_DIR/config.json"
            chmod 600 "$CONF_DIR/config.json"
        fi

        echo "⚙️ 正在写入主服务配置..."
        cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run

name="usque"
description="Usque Tunnel Service"
command="$INSTALL_DIR/$BIN_NAME"
command_args="$SVC_ARGS"
command_background=true
pidfile="/run/usque.pid"
output_log="/dev/null"
error_logger="logger -t usque -p daemon.err"

depend() {
    need net
    use dns
}
EOF
        # 仅针对 KVM 添加 tun 模块加载
        if [ "$IS_LXC" -eq 0 ]; then
            cat <<EOF >> "$SERVICE_FILE"

start_pre() {
    grep -qxF tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
    modprobe tun 2>/dev/null || true
}
EOF
        fi
        chmod +x "$SERVICE_FILE"
        rc-update add usque default >/dev/null 2>&1

        # KVM 环境下，需要写路由守护进程
        if [ "$IS_LXC" -eq 0 ] && [ "$ROUTE_MODE" != "none" ]; then
            echo "🛡️ 正在生成路由守护进程..."
            if [ "$ROUTE_MODE" = "v6only" ]; then
                IP_ROUTE_CMD="ip -4 route"
            else
                IP_ROUTE_CMD="ip -6 route"
            fi

            cat << EOF > "$ROUTER_BIN"
#!/bin/sh
while true; do
    if ip link show dev tun0 >/dev/null 2>&1; then
        if ! $IP_ROUTE_CMD show default | grep -q "dev tun0"; then
            $IP_ROUTE_CMD replace default dev tun0 metric 50 2>/dev/null || true
        fi
    fi
    sleep 3
done
EOF
            chmod +x "$ROUTER_BIN"

            cat << 'EOF' > "$ROUTER_SVC_FILE"
#!/sbin/openrc-run

name="usque-router"
description="Maintain default route via tun0"
command="/usr/local/bin/usque-router.sh"
command_background=true
pidfile="/run/usque-router.pid"

depend() {
    after net usque
}

stop_post() {
    ip -4 route del default dev tun0 metric 50 2>/dev/null || true
    ip -6 route del default dev tun0 metric 50 2>/dev/null || true
}
EOF
            chmod +x "$ROUTER_SVC_FILE"
            rc-update add usque-router default >/dev/null 2>&1
        fi
    fi

    # 清理并重启
    cd - > /dev/null
    rm -rf "$TMP_DIR"
    
    echo "⚙️ 正在启动服务..."
    rc-service usque start >/dev/null 2>&1 || true
    if [ -f "$ROUTER_SVC_FILE" ]; then
        rc-service usque-router start >/dev/null 2>&1 || true
    fi
fi

# ==========================================
# 5. 状态输出
# ==========================================
echo "--------------------------------------------------"
echo "🎉 部署执行完毕！"
echo "usque 状态: $(rc-service usque status 2>/dev/null | awk '{print $NF}' || echo 'unknown')"
if [ -f "$ROUTER_SVC_FILE" ]; then
    echo "路由守护状态: $(rc-service usque-router status 2>/dev/null | awk '{print $NF}')"
fi
echo "--------------------------------------------------"
