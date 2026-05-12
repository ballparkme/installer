#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "❌ 请使用 root 权限运行 (sudo -i)"; exit 1; fi

# 终端颜色定义
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=================================================${NC}"
echo -e "${GREEN}    Telegram PAM 登录与提权监控 - 自动化部署 V5  ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# ================= 1. 交互式获取配置 =================

while [[ -z "$TG_BOT_TOKEN" ]]; do
    read -p "$(echo -e ${YELLOW}"[1/3] 请输入 Telegram Bot Token (格式 123456:ABC...): "${NC})" TG_BOT_TOKEN
done

while [[ -z "$TG_CHAT_ID" ]]; do
    read -p "$(echo -e ${YELLOW}"[2/3] 请输入 Telegram Chat ID (例如 123456789): "${NC})" TG_CHAT_ID
done

echo -e "\n${CYAN}[3/3] 请选择需要监控的服务 (输入数字序号，多个选项用空格分隔):${NC}"
echo -e "  ${GREEN}1)${NC} sshd      (SSH 远程登录)"
echo -e "  ${GREEN}2)${NC} login     (本地 TTY 终端登录)"
echo -e "  ${GREEN}3)${NC} su        (切换用户身份 su / su-l)"
echo -e "  ${GREEN}4)${NC} sudo-i    (交互式提权获取 root 环境)"
echo -e "  ${RED}5)${NC} sudo-all  (${YELLOW}偏执狂模式: 监控所有单次 sudo 命令${NC})"
echo -e "${CYAN}提示: 直接回车默认监控 1 2 3 4。${NC}"

read -p "您的选择 [默认: 1 2 3 4]: " SERVICE_CHOICES
SERVICE_CHOICES=${SERVICE_CHOICES:-1 2 3 4}

SELECTED_SERVICES=()
MOUNT_SUDO_ALL=false

for choice in $SERVICE_CHOICES; do
    case $choice in
        1) SELECTED_SERVICES+=("sshd") ;;
        2) SELECTED_SERVICES+=("login") ;;
        3) SELECTED_SERVICES+=("su" "su-l") ;;
        4) SELECTED_SERVICES+=("sudo-i") ;;
        5) SELECTED_SERVICES+=("sudo"); MOUNT_SUDO_ALL=true ;;
        *) echo -e "${YELLOW}忽略无效选项: $choice${NC}" ;;
    esac
done

if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
    SELECTED_SERVICES=("sshd" "login" "su" "su-l" "sudo-i")
fi

SERVICES=$(IFS="|"; echo "${SELECTED_SERVICES[*]}")

echo -e "\n${GREEN}配置确认：将监控以下服务 -> [ $SERVICES ]${NC}\n"
sleep 1

# ================= 2. 开始系统配置 =================

echo "[1/5] 安装依赖组件..."
apt-get update -qq
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils curl > /dev/null

echo "[2/5] 创建/更新 PAM 触发脚本..."
cat << EOF > /usr/local/bin/login-notify.sh
#!/bin/bash
MONITOR_SERVICES="${SERVICES}"
EOF

cat << 'EOF' >> /usr/local/bin/login-notify.sh
[[ "$PAM_TYPE" != "open_session" ]] && exit 0

if ! [[ "|${MONITOR_SERVICES}|" == *"|${PAM_SERVICE}|"* ]]; then
    exit 0
fi

SUBJECT="[Login Alert] ${PAM_USER}@$(hostname) via ${PAM_SERVICE}"
MESSAGE="主机: $(hostname -f)
用户: ${PAM_USER}
来源: ${PAM_RHOST:-$PAM_TTY}
时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
服务: ${PAM_SERVICE}"

echo -e "$MESSAGE" | mail -s "$SUBJECT" root
EOF
chmod 755 /usr/local/bin/login-notify.sh

echo "[3/5] 创建/更新 Telegram 转发脚本..."
cat << EOF > /usr/local/bin/mail-to-tg.sh
#!/bin/bash
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOF

cat << 'EOF' >> /usr/local/bin/mail-to-tg.sh
CONTENT=$(cat | grep -E "^(主机:|用户:|来源:|时间:|服务:)")

if [ -z "$CONTENT" ]; then
    exit 0
fi

if [ ${#CONTENT} -gt 3900 ]; then
    CONTENT="${CONTENT:0:3900}...[TRUNCATED]"
fi

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d text="$CONTENT")

if [ "$HTTP_STATUS" != "200" ]; then
    exit 75
fi
exit 0
EOF
chown nobody:nogroup /usr/local/bin/mail-to-tg.sh
chmod 700 /usr/local/bin/mail-to-tg.sh

echo "[4/5] 配置本地邮件别名..."
if ! grep -q "mail-to-tg.sh" /etc/aliases; then
    echo 'root: \root, "|/usr/local/bin/mail-to-tg.sh"' >> /etc/aliases
    newaliases
fi

echo "[5/5] 将规则挂载到 PAM 管道..."
PAM_RULE="session optional pam_exec.so /usr/local/bin/login-notify.sh"

# 1. 挂载到全局交互式会话 (处理 1, 2, 3, 4)
if ! grep -qF "$PAM_RULE" /etc/pam.d/common-session; then
    echo "$PAM_RULE" >> /etc/pam.d/common-session
fi

# 2. 动态管理偏执狂模式管道 (处理 5 的增加与回退)
if [ "$MOUNT_SUDO_ALL" = true ]; then
    if ! grep -qF "$PAM_RULE" /etc/pam.d/sudo; then
        echo "$PAM_RULE" >> /etc/pam.d/sudo
    fi
    echo -e "${RED}⚠️ 注意：已开启偏执狂模式，任何 sudo 命令都将触发报警！${NC}"
else
    # 【核心修复】如果没选5，且文件里有遗留规则，则彻底删除它
    if grep -qF "$PAM_RULE" /etc/pam.d/sudo; then
        # 使用 sed 安全地删除匹配的整行
        sed -i '\|session optional pam_exec.so /usr/local/bin/login-notify.sh|d' /etc/pam.d/sudo
        echo -e "${GREEN}🧹 已清理历史偏执狂配置，恢复日常模式。${NC}"
    fi
fi

echo -e "\n${GREEN}✅ 部署彻底完成！${NC}"
