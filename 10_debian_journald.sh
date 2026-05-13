#!/bin/bash

# 1. 检查是否具有 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 权限不足：请使用 root 身份或加上 sudo 运行此脚本。"
  exit 1
fi

# 定义配置目录和文件路径
CONF_DIR="/etc/systemd/journald.conf.d"
CONF_FILE="$CONF_DIR/99-custom-limits.conf"

# 2. 确保配置目录存在 (如果不存在则自动创建)
mkdir -p "$CONF_DIR"

# 3. 使用 EOF 语法将配置写入文件
echo "⏳ 正在写入配置文件到 $CONF_FILE ..."
cat > "$CONF_FILE" << 'EOF'
[Journal]
Storage=auto
Compress=yes
Seal=yes
SplitMode=uid

SyncIntervalSec=5m

RateLimitIntervalSec=30s
RateLimitBurst=5000

SystemMaxUse=256M
SystemKeepFree=1G
SystemMaxFileSize=32M

RuntimeMaxUse=64M
RuntimeKeepFree=256M
RuntimeMaxFileSize=8M

MaxRetentionSec=0
MaxFileSec=1month
EOF

echo "✅ 写入完成！"

# 4. 重启 journald 服务以应用新配置
echo "🔄 正在重启 systemd-journald 服务以使配置生效..."
systemctl restart systemd-journald

# 5. 检查服务状态并输出结果
if systemctl is-active --quiet systemd-journald; then
  echo "🎉 部署成功！systemd-journald 正在正常运行。"
else
  echo "⚠️ 警告：systemd-journald 启动可能遇到问题，请使用 'systemctl status systemd-journald' 检查状态。"
fi
