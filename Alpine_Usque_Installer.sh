#!/bin/sh

# 遇到错误立即退出
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==========================================
# 0. 临时运行环境
# ==========================================
TMP_DIR=$(mktemp -d)
# 脚本退出或中断时自动清理临时目录，不留垃圾
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP

# ==========================================
# 1. 权限与依赖处理
# ==========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误: 此脚本需要管理员权限。"
    echo "💡 请使用: doas $0 或 sudo $0"
    exit 1
fi

echo "📦 正在更新软件源并安装必要依赖..."
apk update >/dev/null
apk add -u curl unzip jq iproute2 >/dev/null

REPO="Diniboy1123/usque"
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/usr/local/etc/usque"
BIN_NAME="usque"
SERVICE_FILE="/etc/init.d/usque"
ROUTER_SVC_FILE="/etc/init.d/usque-router"
ROUTER_BIN="/usr/local/bin/usque-router.sh"

# ==========================================
# 2. 版本获取与状态判定
# ==========================================
echo "☁️ 正在获取 usque 云端最新版本信息..."
LATEST_TAG=$(curl -fsSL -H "User-Agent: usque-installer/1.0" "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)

if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
    echo "❌ 错误: 无法获取云端版本号，请检查网络或 GitHub 限制。"
    exit 1
fi

IS_NEW_INSTALL=0
IS_UPGRADE=0

if [ ! -x "$INSTALL_DIR/$BIN_NAME" ]; then
    echo "🔍 未检测到现有安装，准备全新部署..."
    IS_NEW_INSTALL=1
else
    LOCAL_VERSION=$("$INSTALL_DIR/$BIN_NAME" version 2>&1 | grep "usque version:" | awk '{print $3}' || true)
    if [ "$LOCAL_VERSION" = "$LATEST_TAG" ]; then
        echo "✅ 当前已安装最新版本 ($LOCAL_VERSION)，无需更新。"
        exit 0
    else
        echo "🔄 检测到版本升级: ${LOCAL_VERSION:-未知} -> $LATEST_TAG"
        IS_UPGRADE=1
    fi
fi

# ==========================================
# 3. 交互配置 (仅全新安装时触发)
# ==========================================
if [ "$IS_NEW_INSTALL" -eq 1 ]; then
    echo "=================================================="
    echo "请选择需要部署的运行模式："
    echo "  1) SOCKS 代理模式 (适用于 LXC 容器，或仅需代理服务的环境)"
    echo "  2) TUN 模式       (适用于 KVM / 物理机，性能更好)"
    echo "=================================================="
    while true; do
        printf "👉 请输入对应数字 (1/2): "
        read MODE_CHOICE
        case "$MODE_CHOICE" in
            1) INSTALL_MODE="socks"; break ;;
            2) INSTALL_MODE="tun"; break ;;
            *) echo "❌ 无效输入，请输入 1 或 2。" ;;
        esac
    done

    if [ "$INSTALL_MODE" = "socks" ]; then
        echo "📦 已选择【SOCKS 代理模式】。"
        while true; do
            printf "👉 请输入 usque SOCKS 代理绑定的端口号 (1-65535): "
            read INPUT_PORT
            INPUT_PORT=$(echo "$INPUT_PORT" | tr -d ' ')
            
            if [ -z "$INPUT_PORT" ]; then echo "❌ 不能为空！"; continue; fi
            if ! echo "$INPUT_PORT" | grep -Eq '^[0-9]+$'; then echo "❌ 必须是纯数字！"; continue; fi
            if [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then echo "❌ 超出范围！"; continue; fi
            if ss -tuln | awk '{print $5}' | grep -qE ":${INPUT_PORT}$"; then echo "❌ 端口已被占用！"; continue; fi
            
            echo "✅ 端口 $INPUT_PORT 校验通过！"
            SVC_ARGS="-c $CONF_DIR/config.json socks -b 127.0.0.1 -p $INPUT_PORT --always-reconnect"
            break
        done
    else
        echo "🖥️ 已选择【TUN 模式】。"
        echo "=================================================="
        echo "请选择当前机器的网络环境："
        echo "  1) IPv4 + IPv6 (双栈)   - 保持正常路由"
        echo "  2) IPv6 Only (纯IPv6)   - 将缺失的 IPv4 默认路由强制指给 tun0"
        echo "  3) IPv4 Only (纯IPv4)   - 将缺失的 IPv6 默认路由强制指给 tun0"
        echo "=================================================="
        while true; do
            printf "👉 请输入对应数字 (1/2/3): "
            read NET_CHOICE
            case "$NET_CHOICE" in
                1) SVC_ARGS="-c $CONF_DIR/config.json nativetun"; ROUTE_MODE="none"; break ;;
                2) SVC_ARGS="-c $CONF_DIR/config.json nativetun -6"; ROUTE_MODE="v6only"; break ;;
                3) SVC_ARGS="-c $CONF_DIR/config.json nativetun"; ROUTE_MODE="v4only"; break ;;
                *) echo "❌ 无效输入，请输入 1、2 或 3。" ;;
            esac
        done
        echo "✅ 网络环境配置已记录。"
    fi
fi

# ==========================================
# 4. 下载与部署
# ==========================================
if [ "$IS_NEW_INSTALL" -eq 1 ] || [ "$IS_UPGRADE" -eq 1 ]; then
    cd "$TMP_DIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | amd64)    SEARCH_KW="amd64" ;;
        aarch64 | arm64)   SEARCH_KW="arm64" ;;
        armv7* | armv8l)   SEARCH_KW="armv7" ;;
        *)                 SEARCH_KW="$ARCH" ;;
    esac

    curl -fsSL -o "checksums.txt" "https://github.com/$REPO/releases/download/$LATEST_TAG/checksums.txt"
    MATCHED_FILE=$(awk "/linux.*$SEARCH_KW.*\.zip/ {print \$2}" checksums.txt | head -n 1)

    echo "🚀 正在下载: $MATCHED_FILE ..."
    curl -fL -# -o "$MATCHED_FILE" "https://github.com/$REPO/releases/download/$LATEST_TAG/$MATCHED_FILE"
    
    grep -F "$MATCHED_FILE" checksums.txt > my_checksum.txt
    sha256sum -c -s my_checksum.txt >/dev/null || { echo "❌ 校验失败"; exit 1; }

    unzip -q -j "$MATCHED_FILE" "$BIN_NAME"
    chmod +x "$BIN_NAME"

    echo "⚙️ 正在停止旧服务..."
    rc-service usque stop 2>/dev/null || true
    rc-service usque-router stop 2>/dev/null || true
    
    cp "$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"

    # ==========================================
    # 5. 初次安装时的配置生成与持久化
    # ==========================================
    if [ "$IS_NEW_INSTALL" -eq 1 ]; then
        
        # 仅在 TUN 模式下执行 TUN 模块的持久化与加载
        if [ "$INSTALL_MODE" = "tun" ]; then
            echo "⚙️ 正在持久化并激活 TUN 模块..."
            grep -qxF tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
            if command -v modprobe >/dev/null 2>&1; then
                modprobe tun 2>/dev/null || true
            fi
        fi

        if [ ! -f "$CONF_DIR/config.json" ]; then
            echo "⚙️ 正在生成新账号配置..."
            ./"$BIN_NAME" register -a >/dev/null
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
        if [ "$INSTALL_MODE" = "tun" ]; then
            cat <<EOF >> "$SERVICE_FILE"

start_pre() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tun 2>/dev/null || true
    fi
}
EOF
        fi
        chmod +x "$SERVICE_FILE"
        rc-update add usque default >/dev/null 2>&1

        # ==========================================
        # 6. 高级路由守护进程
        # ==========================================
        if [ "$INSTALL_MODE" = "tun" ] && [ "$ROUTE_MODE" != "none" ]; then
            echo "🛡️ 正在生成事件驱动型路由守护进程..."
            if [ "$ROUTE_MODE" = "v6only" ]; then
                IP_ROUTE_CMD="ip -4 route"
            else
                IP_ROUTE_CMD="ip -6 route"
            fi

            cat << EOF > "$ROUTER_BIN"
#!/bin/sh
setup_route() {
    if ip link show dev tun0 >/dev/null 2>&1; then
        $IP_ROUTE_CMD replace default dev tun0 metric 50 proto 42 2>/dev/null || true
    fi
}

setup_route
while true; do
    ip monitor link dev tun0 2>/dev/null | while read -r _; do
        setup_route
    done
    sleep 2
done
EOF
            chmod +x "$ROUTER_BIN"

            cat << EOF > "$ROUTER_SVC_FILE"
#!/sbin/openrc-run

name="usque-router"
description="Maintain default route via tun0 (Event-Driven)"
command="$ROUTER_BIN"
command_background=true
pidfile="/run/usque-router.pid"

depend() {
    after net usque
}

stop_post() {
    ip -4 route del default dev tun0 metric 50 proto 42 2>/dev/null || true
    ip -6 route del default dev tun0 metric 50 proto 42 2>/dev/null || true
}
EOF
            chmod +x "$ROUTER_SVC_FILE"
            rc-update add usque-router default >/dev/null 2>&1
        fi
    fi

    # ==========================================
    # 7. 启动并处理错误捕获
    # ==========================================
    cd - >/dev/null
    
    echo "⚙️ 正在启动服务..."
    if ! rc-service usque start; then
        echo "❌ 启动 usque 主服务失败，请检查配置或日志。"
        exit 1
    fi
    
    if [ -f "$ROUTER_SVC_FILE" ]; then
        if ! rc-service usque-router start; then
            echo "⚠️ 路由守护进程启动失败，但主程序已运行。"
        fi
    fi
fi

# ==========================================
# 8. 状态输出
# ==========================================
echo "--------------------------------------------------"
echo "🎉 部署执行完毕！"
echo "usque 状态: $(rc-service usque status 2>/dev/null | awk '{print $NF}' || echo 'unknown')"
if [ -f "$ROUTER_SVC_FILE" ]; then
    echo "路由守护状态: $(rc-service usque-router status 2>/dev/null | awk '{print $NF}')"
fi
echo "--------------------------------------------------"
