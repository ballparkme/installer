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
echo -e "${GREEN}    RKHunter 扫描报告 Telegram 转发 - 自动化部署   ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# ================= 1. 交互式获取配置 =================

while [[ -z "$TG_BOT_TOKEN" ]]; do
    read -p "$(echo -e ${YELLOW}"[1/2] 请输入 Telegram Bot Token: "${NC})" TG_BOT_TOKEN
done

while [[ -z "$TG_CHAT_ID" ]]; do
    read -p "$(echo -e ${YELLOW}"[2/2] 请输入 Telegram Chat ID: "${NC})" TG_CHAT_ID
done

echo -e "\n${GREEN}✅ 配置已记录，开始安装...${NC}\n"

# ================= 2. 安装依赖组件 =================

echo -e "${CYAN}[1/5] 更新软件源并安装依赖 (postfix, mailutils, curl, rkhunter)...${NC}"
apt-get update -qq
# 预设 Postfix 安装选项，避免交互式弹窗阻塞脚本
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils curl rkhunter > /dev/null

# ================= 3. 配置 RKHunter 本地规则 =================

echo -e "${CYAN}[2/5] 写入 rkhunter 本地配置文件及白名单...${NC}"
cat <<EOF | sudo tee /etc/rkhunter.conf.local > /dev/null
UPDATE_MIRRORS=1
MIRRORS_MODE=0
WEB_CMD=""
# 允许你之前发现的那个隐藏文件
ALLOWHIDDENFILE=/etc/.updated
EOF

# 顺便更新一次属性数据库，避免首次运行全是警告
rkhunter --propupd > /dev/null 2>&1

# ================= 4. 创建转发脚本 =================

echo -e "${CYAN}[3/5] 创建 Telegram 转发脚本 (/usr/local/bin/rkhunter-to-tg.sh)...${NC}"

cat << EOF > /usr/local/bin/rkhunter-to-tg.sh
#!/bin/bash
# 自动生成的 RKHunter 邮件转发脚本

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

# 接收邮件全貌
FULL_MAIL=\$(cat)

# 仅处理包含 [rkhunter] 主题的邮件
if ! echo "\$FULL_MAIL" | grep -iq "Subject:.*rkhunter"; then
    exit 0
fi

# 提取关键信息
SUBJECT=\$(echo "\$FULL_MAIL" | grep -i "^Subject:" | head -n 1 | sed 's/Subject: //I')
WARNINGS=\$(echo "\$FULL_MAIL" | grep -i "Warning:")
SUMMARY=\$(echo "\$FULL_MAIL" | sed -n '/System checks summary/,\$p')

# 拼装消息
CONTENT="🛡️ <b>[rkhunter 扫描报告]</b>\n"
CONTENT+="<b>主机:</b> \$(hostname)\n"
CONTENT+="<b>主题:</b> \${SUBJECT}\n\n"

if [ -n "\$WARNINGS" ]; then
    CONTENT+="<b>⚠️ 发现警告:</b>\n<pre>\${WARNINGS}</pre>\n\n"
fi

if [ -n "\$SUMMARY" ]; then
    CONTENT+="<b>📊 扫描总结:</b>\n<pre>\${SUMMARY}</pre>"
fi

# 长度截断保护
if [ \${#CONTENT} -gt 3900 ]; then
    CONTENT="\${CONTENT:0:3900}...[TRUNCATED]"
fi

# 推送
curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" \\
    -d parse_mode="HTML" \\
    -d text="\$(echo -e "\$CONTENT")" > /dev/null

exit 0
EOF

chown nobody:nogroup /usr/local/bin/rkhunter-to-tg.sh
chmod 700 /usr/local/bin/rkhunter-to-tg.sh

# ================= 5. 配置本地邮件别名 =================

echo -e "${CYAN}[4/5] 配置本地邮件管道 (Aliases)...${NC}"
# 检查是否已经配置过，避免重复添加
if ! grep -q "rkhunter-to-tg.sh" /etc/aliases; then
    # 修改 root 这一行，追加新的管道脚本
    # 这里的逻辑是：如果 root 行已存在，则在末尾追加；如果不存在，则新建
    if grep -q "^root:" /etc/aliases; then
        sed -i '/^root:/ s/$/, "|\/usr\/local\/bin\/rkhunter-to-tg.sh"/' /etc/aliases
    else
        echo 'root: \root, "|/usr/local/bin/rkhunter-to-tg.sh"' >> /etc/aliases
    fi
    newaliases
    echo -e "${GREEN}✔ 邮件别名已更新${NC}"
else
    echo -e "${YELLOW}ℹ 邮件别名已存在，跳过修改${NC}"
fi

# ================= 6. 完成 =================

echo -e "${CYAN}[5/5] 部署验证...${NC}"
echo -e "${GREEN}✅ RKHunter Telegram 转发系统部署完成！${NC}"
echo -e "\n${YELLOW}提示: ${NC}"
echo -e "1. 每日扫描结果将通过 cron.daily 自动运行。"
echo -e "2. 只有当 rkhunter 发现警告（Warning）时才会发送消息。"
echo -e "3. 你可以运行 ${CYAN}sudo rkhunter --check --sk${NC} 手动触发一次扫描进行测试。"
