#!/bin/sh
set -e

# =========================================================
# Alpine Linux 用户初始化脚本
# =========================================================

# ---------- ROOT 检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

# =========================================================
# 安装必要组件
# =========================================================

echo ">>> 正在安装必要组件..."

apk add -u \
    bash \
    bash-completion \
    shadow \
    doas

# ---------- 检查 bash 是否安装成功 ----------
if ! command -v bash >/dev/null 2>&1; then
    echo "错误：bash 安装失败。"
    exit 1
fi

# =========================================================
# 配置默认 shell
# =========================================================

useradd -D -s /bin/bash

# =========================================================
# 配置 doas
# =========================================================

mkdir -p /etc/doas.d

cat > /etc/doas.d/doas.conf << 'EOF'
permit persist keepenv :wheel
EOF

chmod 0400 /etc/doas.d/doas.conf

# =========================================================
# 创建用户
# =========================================================

echo
printf "请输入新用户名 [默认: workforce]: "
read -r USERNAME

USERNAME="${USERNAME:-workforce}"

# ---------- 检查用户是否已存在 ----------
if id "$USERNAME" >/dev/null 2>&1; then
    echo "错误：用户 '$USERNAME' 已存在。"
    exit 1
fi

echo
echo ">>> 正在创建用户: $USERNAME"

useradd -m -s /bin/bash "$USERNAME"

# ---------- 设置密码 ----------
echo
echo ">>> 请为用户设置密码"
passwd "$USERNAME"

# ---------- 加入 wheel ----------
usermod -aG wheel "$USERNAME"

# =========================================================
# SSH 配置
# =========================================================

SSH_DIR="/home/$USERNAME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -m 700 -o "$USERNAME" -g "$USERNAME" -d "$SSH_DIR"

install -m 600 -o "$USERNAME" -g "$USERNAME" \
    /dev/null "$AUTH_KEYS"

# ---------- 输入 SSH 公钥 ----------
echo
echo "请输入 SSH 公钥（单行）:"

while :; do
    read -r SSH_KEY

    case "$SSH_KEY" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *)
            break
            ;;
        *)
            echo "SSH 公钥格式不正确，请重新输入："
            ;;
    esac
done

# ---------- 写入公钥 ----------
printf "%s\n" "$SSH_KEY" > "$AUTH_KEYS"

chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# =========================================================
# 完成
# =========================================================

echo
echo "=================================================="
echo "初始化完成"
echo
echo "用户名: $USERNAME"
echo "默认 Shell: /bin/bash"
echo "已加入 wheel 组"
echo "SSH 公钥已写入"
echo
echo "请确认 SSH 公钥登录正常后，再禁用密码登录。"
echo "=================================================="
