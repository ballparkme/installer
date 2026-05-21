#!/bin/sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. 检查权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：权限不足。请使用 doas 或以 root 身份执行此脚本。${NC}"
    exit 1
fi

# ==========================================
# 交互配置阶段
# ==========================================
echo -e "\n${CYAN}>>> 扫描当前系统已存在的邮件通道 (Aliases)...${NC}"
if grep -qE '^[a-zA-Z0-9_-]+:' /etc/aliases; then
    grep -E '^[a-zA-Z0-9_-]+:' /etc/aliases | awk -F':' '{printf "  %s%-15s%s -> %s\n", "\033[1;33m", $1, "\033[0m", $2}'
else
    echo "  (当前系统无任何自定义通道)"
fi

while true; do
    printf "\n${CYAN}请输入接收告警通知的通道名称 (例如 Telegram, 不能为空): ${NC}"
    read -r CH_NAME
    if [ -z "$CH_NAME" ]; then continue; fi
    if echo "$CH_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then break; else echo -e "${RED}格式错误！${NC}"; fi
done

printf "${CYAN}请输入报警邮件的主题 (直接回车默认为 System Upgrade Failed): ${NC}"
read -r MAIL_SUBJECT
[ -z "$MAIL_SUBJECT" ] && MAIL_SUBJECT="System Upgrade Failed"

# ==========================================
# 核心部署阶段
# ==========================================
echo -e "\n${CYAN}>>> 正在安装必要的底层依赖...${NC}"
apk add -u util-linux coreutils  # 确保 timeout 和高级 flock 可用

echo -e "${CYAN}>>> 正在生成独立的生产级更新处理器...${NC}"
SCRIPT_PATH="/usr/local/bin/apk_autoupgrade_task.sh"

cat << EOF > "$SCRIPT_PATH"
#!/bin/sh
# --- 生产级更新处理器 ---

LOG_FILE="/var/log/apk-autoupgrade.log"
LOCK_FILE="/run/lock/apk_update.lock"
FLAG_FILE="/run/reboot-required"

# 1. 使用标准文件描述符锁 (FD 9)，保证脚本级别的绝对排他性
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    echo "[\$(date)] 警告：上一个更新进程仍在运行，本次任务放弃。" >> "\$LOG_FILE"
    exit 1
fi

# 2. 核心执行：加入 45 分钟硬超时防护
echo "[\$(date)] 开始系统更新..." >> "\$LOG_FILE"
if timeout 45m apk upgrade --update >> "\$LOG_FILE" 2>&1; then
    # 成功：发放重启通行证
    echo "[\$(date)] 更新成功，准备授权重启。" >> "\$LOG_FILE"
    touch "\$FLAG_FILE"
else
    # 失败：直接拦截并立即报警
    ERROR_CODE=\$?
    if [ "\$ERROR_CODE" -eq 124 ]; then
        REASON="触发 45 分钟网络超时熔断，进程被强制结束。"
    else
        REASON="依赖冲突或包管理器内部错误 (退出码: \$ERROR_CODE)。"
    fi
    
    echo "[\$(date)] 致命错误：\$REASON" >> "\$LOG_FILE"
    
    # 构建邮件正文并发送至你指定的通道
    BODY="主机: \$(hostname)\n时间: \$(date)\n警报: 03:00 系统自动更新任务失败！\n原因: \$REASON\n日志: 请登录服务器查看 /var/log/apk-autoupgrade.log"
    printf "%b\n" "\$BODY" | mail -s "${MAIL_SUBJECT}" "${CH_NAME}"
fi
EOF

chmod 700 "$SCRIPT_PATH"

echo -e "${CYAN}>>> 正在配置 crond 服务与调度任务...${NC}"
rc-update add crond default 2>/dev/null || true
rc-service crond start 2>/dev/null || true

# 重新组装极简的 cron 任务
UPDATE_JOB="0 3 * * * $SCRIPT_PATH"
# 重启任务：只看通行证行事
REBOOT_JOB="0 4 * * * [ -f /run/reboot-required ] && rm -f /run/reboot-required && /sbin/reboot"

# 幂等性清理历史旧 cron 规则（清理包含老式 flock 字符串或新脚本路径的行）
CURRENT_CRON=$(crontab -l 2>/dev/null | grep -vF "apk upgrade" | grep -vF "/sbin/reboot" | grep -vF "$SCRIPT_PATH" || true)

(
    if [ -n "$CURRENT_CRON" ]; then echo "$CURRENT_CRON"; fi
    echo "$UPDATE_JOB"
    echo "$REBOOT_JOB"
) | grep -v "^$" | crontab -

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 生产级自动更新探针部署完成！${NC}"
echo -e "任务脚本: ${YELLOW}$SCRIPT_PATH${NC}"
echo -e "更新计划: ${YELLOW}每天 03:00 执行带 45m 超时防护的更新${NC}"
echo -e "重启计划: ${YELLOW}每天 04:00 (仅当更新成功时触发)${NC}"
echo -e "告警机制: ${YELLOW}遭遇超时或失败时，立即向 ${CH_NAME} 发送报告${NC}"
echo -e "${GREEN}==========================================${NC}"
