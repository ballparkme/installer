#!/bin/bash

# 检查是否以 root 或 sudo 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 sudo 或 root 权限运行此脚本"
  exit 1
fi

# 确定 SSH 端口
if [ -n "$1" ]; then
    PORT="$1"
else
    # 随机生成 50000-65500 之间的端口
    PORT=$(( RANDOM % 15501 + 50000 ))
fi

echo "====================================================="
echo "🛡️  即将开始 SSH 加固配置"
echo "👉 目标 SSH 端口: $PORT"
echo "⚠️  警告：此脚本将禁用【密码登录】和【Root 登录】。"
echo "请务必确保当前普通用户已经配置了公钥 (~/.ssh/authorized_keys)！"
echo "====================================================="
read -p "按回车键继续执行，或按 Ctrl+C 取消..."

# 0. 备份原配置 (新增)
BACKUP_DIR="/etc/ssh/sshd_backup_$(date +%Y%m%d_%H%M%S)"
echo "[1/9] 正在备份原始配置到 $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"
cp -p /etc/ssh/sshd_config "$BACKUP_DIR/"
cp -rp /etc/ssh/sshd_config.d "$BACKUP_DIR/" 2>/dev/null || true

# 1. 删除旧的配置残留
echo "[2/9] 清理 /etc/ssh/sshd_config.d/ 下的旧配置..."
rm -rf /etc/ssh/sshd_config.d/*

# 2. 更改端口
echo "[3/9] 设置 SSH 端口为 $PORT..."
echo "Port $PORT" > /etc/ssh/sshd_config.d/01-port.conf

# 3. 禁止 Root 登录
echo "[4/9] 禁止 Root 登录..."
echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/02-root.conf

# 4. 禁止密码登录
echo "[5/9] 禁止密码登录..."
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/03-auth.conf

# 5. 清除 root 用户的密钥
echo "[6/9] 清除 Root 用户的授权密钥..."
rm -f /root/.ssh/authorized_keys

# 6. 写入额外加固配置 (修改 LogLevel 为 INFO)
echo "[7/9] 写入额外加固配置 (04-hardening.conf)..."
cat <<EOF > /etc/ssh/sshd_config.d/04-hardening.conf
ClientAliveCountMax 2
LogLevel INFO
MaxAuthTries 3
MaxSessions 2
TCPKeepAlive no
X11Forwarding no
AllowAgentForwarding no
EOF

# 7. 校验配置有效性 (新增)
echo "[8/9] 校验 SSH 配置语法..."
if ! sshd -t; then
    echo "❌ 错误: SSH 配置语法检查未通过！正在执行回滚..."
    # 恢复配置文件
    rm -rf /etc/ssh/sshd_config.d
    cp -rp "$BACKUP_DIR/sshd_config.d" /etc/ssh/ 2>/dev/null || mkdir -p /etc/ssh/sshd_config.d
    cp -p "$BACKUP_DIR/sshd_config" /etc/ssh/
    echo "✅ 回滚完成，当前 SSH 服务未受影响。请检查系统状态后重试。"
    exit 1
else
    echo "✅ SSH 配置语法检查通过。"
fi

# 8. 重启并应用服务
echo "[9/9] 重启 SSH 服务..."
# 禁用 socket 激活
systemctl disable --now ssh.socket 2>/dev/null || true
# 启用并重启 service
systemctl enable --now ssh.service 2>/dev/null || systemctl enable --now sshd.service
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service

echo "====================================================="
echo "✅ SSH 加固配置完成！"
echo "🔌 下次登录请使用：ssh -p $PORT 当前用户名@你的服务器IP"
echo "📦 原始配置已备份至: $BACKUP_DIR"
echo ""
echo "🚨 极度重要：请暂时【不要关闭当前终端窗口】！"
echo "请打开一个新的终端窗口，尝试使用新端口和密钥连接服务器。"
echo "如果新窗口连接成功，您再关闭当前窗口；如果失败，您可以在当前窗口立刻使用备份文件恢复配置。"
echo "====================================================="
