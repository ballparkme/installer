#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then echo "❌ 请使用 root 权限运行 (sudo -i)"; exit 1; fi

# 终端颜色定义
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=================================================${NC}"
echo -e "${GREEN}    RKHunter 扫描报告 Telegram 转发 - 自动化部署 V2  ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# ================= 1. 交互式获取配置 =================

while [[ -z "$TG_BOT_TOKEN" ]]; do
    read -p "$(echo -e ${YELLOW}"[1/2] 请输入 Telegram Bot Token: "${NC})" TG_BOT_TOKEN
done

while [[ -z "$TG_CHAT_ID" ]]; do
    read -p "$(echo -e ${YELLOW}"[2/2] 请输入 Telegram Chat ID: "${NC})" TG_CHAT_ID
done

echo -e "\n${GREEN}✅ 配置已记录，开始无情覆写安装...${NC}\n"

# ================= 2. 安装依赖组件 =================

echo -e "${CYAN}[1/6] 更新软件源并安装依赖 (postfix, mailutils, curl, rkhunter)...${NC}"
apt-get update -qq
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils curl rkhunter > /dev/null

# ================= 3. 配置 RKHunter 默认运行参数 =================

echo -e "${CYAN}[2/6] 强制覆写 RKHunter 核心运行参数 (/etc/default/rkhunter)...${NC}"
# 1. 开启每日扫描
sed -i 's/^#*[[:space:]]*CRON_DAILY_RUN=.*/CRON_DAILY_RUN="true"/' /etc/default/rkhunter
# 2. 开启每周数据库更新
sed -i 's/^#*[[:space:]]*CRON_DB_UPDATE=.*/CRON_DB_UPDATE="true"/' /etc/default/rkhunter
# 3. 关闭数据库更新邮件通知
sed -i 's/^#*[[:space:]]*DB_UPDATE_EMAIL=.*/DB_UPDATE_EMAIL="false"/' /etc/default/rkhunter
# 4. 设置报告接收邮箱为 root (触发本地管道转发的关键)
sed -i 's/^#*[[:space:]]*REPORT_EMAIL=.*/REPORT_EMAIL="root"/' /etc/default/rkhunter
# 5. 开启 APT 联动自动更新属性库
sed -i 's/^#*[[:space:]]*APT_AUTOGEN=.*/APT_AUTOGEN="true"/' /etc/default/rkhunter
# 6. 设置 CPU 优先级
sed -i 's/^#*[[:space:]]*NICE=.*/NICE="10"/' /etc/default/rkhunter
# 7. 电池模式下也允许运行扫描
sed -i 's/^#*[[:space:]]*RUN_CHECK_ON_BATTERY=.*/RUN_CHECK_ON_BATTERY="true"/' /etc/default/rkhunter

# ================= 4. 配置 RKHunter 本地规则 =================

echo -e "${CYAN}[3/6] 强制覆写 rkhunter 本地配置文件及白名单...${NC}"
# 使用 > 符号无情覆盖旧配置
cat <<EOF > /etc/rkhunter.conf.local
UPDATE_MIRRORS=1
MIRRORS_MODE=0
WEB_CMD=""
ALLOWHIDDENFILE=/etc/.updated
EOF

# 静默更新属性数据库
rkhunter --propupd > /dev/null 2>&1

# ================= 5. 创建转发脚本 =================

echo -e "${CYAN}[4/6] 强制覆写 Telegram 转发脚本 (/usr/local/bin/rkhunter-to-tg.sh)...${NC}"

cat << EOF > /usr/local/bin/rkhunter-to-tg.sh
#!/bin/bash
# 自动生成的 RKHunter 邮件转发脚本

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

FULL_MAIL=\$(cat)

# 仅处理包含 [rkhunter] 主题的邮件
if ! echo "\$FULL_MAIL" | grep -iq "Subject:.*rkhunter"; then
    exit 0
fi

SUBJECT=\$(echo "\$FULL_MAIL" | grep -i "^Subject:" | head -n 1 | sed 's/Subject: //I')
WARNINGS=\$(echo "\$FULL_MAIL" | grep -i "Warning:")
SUMMARY=\$(echo "\$FULL_MAIL" | sed -n '/System checks summary/,\$p')

CONTENT="🛡️ <b>[rkhunter 扫描报告]</b>\n"
CONTENT+="<b>主机:</b> \$(hostname)\n"
CONTENT+="<b>主题:</b> \${SUBJECT}\n\n"

if [ -n "\$WARNINGS" ]; then
    CONTENT+="<b>⚠️ 发现警告:</b>\n<pre>\${WARNINGS}</pre>\n\n"
fi

if [ -n "\$SUMMARY" ]; then
    CONTENT+="<b>📊 扫描总结:</b>\n<pre>\${SUMMARY}</pre>"
fi

if [ \${#CONTENT} -gt 3900 ]; then
    CONTENT="\${CONTENT:0:3900}...[TRUNCATED]"
fi

curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" \\
    -d parse_mode="HTML" \\
    -d text="\$(echo -e "\$CONTENT")" > /dev/null

exit 0
EOF

chown nobody:nogroup /usr/local/bin/rkhunter-to-tg.sh
chmod 700 /usr/local/bin/rkhunter-to-tg.sh

# ================= 6. 配置本地邮件别名 =================

echo -e "${CYAN}[5/6] 强制重置本地邮件管道 (Aliases)...${NC}"

# 1. 无情清理：不管有没有旧的管道引用，先用 sed 把包含该脚本的片段强行删掉 (兼容不同空格和引号格式)
sed -i 's/,[[:space:]]*"|\/usr\/local\/bin\/rkhunter-to-tg.sh"//g' /etc/aliases
sed -i 's/,[[:space:]]*|\/usr\/local\/bin\/rkhunter-to-tg.sh//g' /etc/aliases

# 2. 干净挂载：在 root 行末尾重新追加管道
if grep -q "^root:" /etc/aliases; then
    sed -i '/^root:/ s/$/, "|\/usr\/local\/bin\/rkhunter-to-tg.sh"/' /etc/aliases
else
    echo 'root: \root, "|/usr/local/bin/rkhunter-to-tg.sh"' >> /etc/aliases
fi

# 3. 生效
newaliases
echo -e "${GREEN}✔ 邮件别名已强制覆写并更新${NC}"

# ================= 7. 完成 =================

echo -e "${CYAN}[6/6] 部署完毕！${NC}"
echo -e "${GREEN}✅ RKHunter Telegram 转发系统部署彻底完成！${NC}"
echo -e "\n${YELLOW}提示: ${NC}"
echo -e "你可以随时运行 ${CYAN}/etc/cron.daily/rkhunter${NC} 来测试整套流程。"
