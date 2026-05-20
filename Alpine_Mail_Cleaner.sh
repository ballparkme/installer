#!/bin/sh
# ==========================================
# Maildir 每周一强制定时清空任务
# ==========================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${CYAN}>>> 正在配置 Maildir 每周一清空任务...${NC}"

# 核心逻辑：使用 find 同时查找 new 和 cur 目录下的所有文件 (-type f)，并直接安全删除 (-delete)
# 时间定义：0 2 * * 1 代表 [每个星期的星期一 凌晨 2:00]
CLEANUP_JOB="0 2 * * 1 find /root/Maildir/new /root/Maildir/cur -type f -delete 2>/dev/null"

# 剥离旧的清理规则（如果你之前部署过其他的 find 清理规则，这里会将其覆盖）
CURRENT_CRON=$(crontab -l 2>/dev/null | grep -vF "find /root/Maildir/" || true)

(
    if [ -n "$CURRENT_CRON" ]; then
        echo "$CURRENT_CRON"
    fi
    echo "$CLEANUP_JOB"
) | grep -v "^$" | crontab -

echo -e "${GREEN}>>> 🎉 部署完成！${NC}"
echo "Cron 规则已生效："
echo -e "${CYAN}0 2 * * 1 find /root/Maildir/new /root/Maildir/cur -type f -delete${NC}"
echo "系统现在会在每个星期一的凌晨 2:00，准时将这两个文件夹内的所有历史邮件彻底抹除。"
