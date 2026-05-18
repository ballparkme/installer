#!/bin/sh

# ==========================================
# Alpine SSH 安全加固脚本
# ==========================================

echo "=================================================="
echo "⚠️ 警告: 请务必确保当前用户的公钥已添加至 ~/.ssh/authorized_keys"
echo "此脚本将禁用密码登录和 Root 登录。如果没有配置好公钥，你将无法再次登录！"
echo "=================================================="
printf "按 Enter 键继续，或按 Ctrl+C 取消..."
read -r dummy

# 生成 50000 到 65000 之间的随机端口
# 使用 awk 确保在 Alpine (BusyBox) 下完美兼容
RANDOM_PORT=$(awk 'BEGIN{srand(); print int(50000 + rand() * 15001)}')

echo "\n[INFO] 已生成随机 SSH 端口: $RANDOM_PORT"

# 7. 清空配置 (添加 -f 防止目录为空时报错)
echo "[INFO] 正在清理旧的 SSH 配置文件..."
doas rm -f /etc/ssh/sshd_config.d/*

# 8. 配置SSH端口
echo "[INFO] 正在配置 SSH 端口为 $RANDOM_PORT..."
echo "Port $RANDOM_PORT" | doas tee /etc/ssh/sshd_config.d/01-port.conf > /dev/null

# 9. 禁止 Root 登录
echo "[INFO] 正在禁用 Root 登录..."
echo "PermitRootLogin no" | doas tee /etc/ssh/sshd_config.d/02-root.conf > /dev/null

# 10. 禁止密码登录
echo "[INFO] 正在禁用密码登录..."
echo "PasswordAuthentication no" | doas tee /etc/ssh/sshd_config.d/03-auth.conf > /dev/null

# 11. 清除root用户的密钥
echo "[INFO] 正在清除 root 用户的 authorized_keys..."
doas rm -f /root/.ssh/authorized_keys

# 12. 重启SSH
echo "[INFO] 正在重启 SSH 服务 (sshd)..."
doas rc-service sshd restart

echo "\n=================================================="
echo "✅ 配置已成功完成！"
echo "🔴 请务必记下你的新 SSH 端口: $RANDOM_PORT"
echo "🔴 下次登录命令示例: ssh -p $RANDOM_PORT 当前用户名@你的服务器IP"
echo "=================================================="
echo "⚠️ 强烈建议：请勿立即关闭当前终端！新开一个终端窗口，测试能否使用新端口和密钥成功登录，以防万一。"
