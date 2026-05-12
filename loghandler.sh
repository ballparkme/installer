#!/bin/bash

# 1. 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m错误：此脚本需要修改 /etc 目录，请使用 sudo 或 root 账户运行此脚本。\e[0m"
  exit 1
fi

# 2. 检查关键依赖：zstd
if ! command -v zstd >/dev/null 2>&1; then
  echo -e "\e[31m错误：未找到 zstd 命令。请先执行 apt install zstd (或对应发行版的包管理器) 进行安装。\e[0m"
  exit 1
fi

# 3. 定义写入函数
write_xray_config() {
  local target_file="/etc/logrotate.d/xray_logs"
  echo -e "\e[34m[INFO]\e[0m 正在写入 Xray 日志轮转配置到 ${target_file}..."
  
  cat << 'EOF' > "$target_file"
/var/log/xray/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    compresscmd /usr/bin/zstd
    uncompresscmd /usr/bin/unzstd
    compressoptions -19 -T1
    compressext .zst
    delaycompress
    dateext
    dateyesterday
    dateformat -%Y-%m-%d-%H%M%S
    copytruncate        
}
EOF
  # 显式设置权限，防止 logrotate 因权限过宽而忽略该文件
  chmod 644 "$target_file"
  echo -e "\e[32m[SUCCESS]\e[0m Xray 配置写入完成，权限已锁定为 644。"
}

write_mail_config() {
  local target_file="/etc/logrotate.d/mails_archive"
  echo -e "\e[34m[INFO]\e[0m 正在写入 Mail 日志轮转配置到 ${target_file}..."
  
  cat << 'EOF' > "$target_file"
/var/mail/root /root/mbox {
    daily
    rotate 60
    missingok
    notifempty
    compress
    compresscmd /usr/bin/zstd
    uncompresscmd /usr/bin/unzstd
    compressoptions -19 -T1
    compressext .zst
    delaycompress
    dateext
    dateyesterday
    dateformat -%Y-%m-%d-%H%M%S
    copytruncate
}
EOF
  # 显式设置权限
  chmod 644 "$target_file"
  echo -e "\e[32m[SUCCESS]\e[0m Mail 配置写入完成，权限已锁定为 644。"
}

# 4. 交互式菜单
echo "======================================================"
echo "          Logrotate 规则自动化配置脚本          "
echo "======================================================"
echo "请选择要配置的日志轮转规则："
echo "  1) 仅写入 Xray 规则 (/etc/logrotate.d/xray_logs)"
echo "  2) 仅写入 Mail 规则 (/etc/logrotate.d/mails_archive)"
echo "  3) 全部写入 (默认)"
echo "------------------------------------------------------"

# 提示用户输入，设置默认值为 3
read -p "请输入选项 [1/2/3] (直接回车默认全选): " choice

# 处理输入逻辑
choice=${choice:-3}

echo ""

case $choice in
  1)
    write_xray_config
    ;;
  2)
    write_mail_config
    ;;
  3)
    write_xray_config
    write_mail_config
    ;;
  *)
    echo -e "\e[33m[WARN]\e[0m 无效输入，将执行默认操作 (全部写入)。"
    write_xray_config
    write_mail_config
    ;;
esac

echo ""
echo -e "\e[32m[DONE]\e[0m 任务结束！你可以使用以下命令进行测试验证（仅演习，不实际执行）："
echo "  sudo logrotate -d /etc/logrotate.d/xray_logs"
echo "  sudo logrotate -d /etc/logrotate.d/mails_archive"
