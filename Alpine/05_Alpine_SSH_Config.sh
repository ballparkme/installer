#!/bin/sh

# ==========================================
# Alpine Linux SSH 安全加固脚本
# 适用于 OpenSSH + OpenRC + Alpine
# ==========================================

set -e

# =========================
# 1. 基础检查
# =========================

if [ "$(id -u)" -eq 0 ]; then
    DOAS=""
elif command -v doas >/dev/null 2>&1; then
    DOAS="doas"
elif command -v sudo >/dev/null 2>&1; then
    DOAS="sudo"
else
    echo "错误：需要 root / doas / sudo 权限。"
    exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
    echo "错误：未检测到 sshd。"
    exit 1
fi

printf '%s\n' "=================================================="
printf '%s\n' "⚠️  SSH 安全加固脚本"
printf '%s\n' "=================================================="
printf '%s\n' ""
printf '%s\n' "此脚本将："
printf '%s\n' "  • 随机修改 SSH 端口"
printf '%s\n' "  • 禁止 root 登录"
printf '%s\n' "  • 禁止密码登录"
printf '%s\n' ""
printf '%s\n' "⚠️ 请确保："
printf '%s\n' "  • 当前用户已经配置 SSH 公钥"
printf '%s\n' "  • ~/.ssh/authorized_keys 可正常使用"
printf '%s\n' ""
printf '%s'   "按 Enter 继续，Ctrl+C 取消..."
read -r dummy

# =========================
# 2. 检查 sshd_config.d
# =========================

SSHD_MAIN_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN_CONFIG"; then
    echo
    echo "错误：当前 sshd_config 未启用 sshd_config.d 支持。"
    echo "请先在 /etc/ssh/sshd_config 中添加："
    echo "Include /etc/ssh/sshd_config.d/*.conf"
    exit 1
fi

$DOAS mkdir -p "$SSHD_DROPIN_DIR"

# =========================
# 3. 生成随机端口
# =========================

generate_port() {
    awk '
    BEGIN {
        srand()
        print int(50000 + rand() * 15001)
    }'
}

check_port_free() {
    PORT_TO_CHECK="$1"

    if command -v ss >/dev/null 2>&1; then
        ! ss -ltn | awk '{print $4}' | grep -q ":$PORT_TO_CHECK\$"
    else
        ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT_TO_CHECK\$"
    fi
}

while :; do
    RANDOM_PORT="$(generate_port)"

    if check_port_free "$RANDOM_PORT"; then
        break
    fi
done

printf '\n[INFO] 已生成随机 SSH 端口: %s\n' "$RANDOM_PORT"

# =========================
# 4. 写入配置
# =========================

PORT_CONF="$SSHD_DROPIN_DIR/90-hardening-port.conf"
AUTH_CONF="$SSHD_DROPIN_DIR/90-hardening-auth.conf"

echo "[INFO] 正在写入 SSH 配置..."

printf 'Port %s\n' "$RANDOM_PORT" \
    | $DOAS tee "$PORT_CONF" >/dev/null

cat <<EOF | $DOAS tee "$AUTH_CONF" >/dev/null
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes

X11Forwarding no
PermitTunnel no

MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# =========================
# 5. 配置合法性检测
# =========================

echo "[INFO] 正在验证 SSH 配置..."

if ! $DOAS sshd -t; then
    echo
    echo "错误：SSHD 配置验证失败。"
    echo "配置未生效。"
    exit 1
fi

# =========================
# 6. 重启 SSH
# =========================

echo "[INFO] 正在重启 sshd..."

$DOAS rc-service sshd restart

# =========================
# 7. 完成提示
# =========================

printf '\n==================================================\n'
printf '✅ SSH 加固完成！\n'
printf '==================================================\n'
printf '\n'
printf '新的 SSH 端口: %s\n' "$RANDOM_PORT"
printf '\n'
printf '下次登录示例：\n'
printf 'ssh -p %s %s@服务器IP\n' "$RANDOM_PORT" "$(whoami)"
printf '\n'
printf '⚠️ 请不要立即关闭当前 SSH 会话！\n'
printf '⚠️ 请先新开终端测试新端口是否能正常登录！\n'
printf '\n'
