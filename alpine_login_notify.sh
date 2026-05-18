#!/bin/sh
# ==========================================
# Alpine Linux 登录监控
# ==========================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}>>> [1/4] 正在彻底扫除旧版架构，清理残留进程...${NC}"
service doas-monitor stop 2>/dev/null || true
rc-update del doas-monitor default 2>/dev/null || true
pkill -f doas_monitor.sh || true
rm -f /etc/init.d/doas-monitor
rm -f /usr/local/bin/doas_monitor.sh
rm -f /usr/local/bin/send_tg_alert.sh
rm -f /usr/local/bin/doas_parser.sh
rm -f /etc/profile.d/tty_alert.sh
if [ -f /etc/aliases ]; then sed -i '/tg-alert/d' /etc/aliases; fi

echo -e "${CYAN}>>> [2/4] 配置并校验 Telegram 机器人凭据...${NC}"
# Token 强校验循环
while true; do
    printf "请输入 Telegram Bot Token: "
    read -r TG_BOT_TOKEN
    if echo "$TG_BOT_TOKEN" | grep -qE '^[0-9]+:[a-zA-Z0-9_-]+$'; then
        break
    else
        echo -e "${RED}格式错误！Token 应类似于 123456789:ABCdefGHI... 请检查是否包含多余空格。${NC}"
    fi
done

# Chat ID 强校验循环
while true; do
    printf "请输入 Telegram Chat ID: "
    read -r TG_CHAT_ID
    if echo "$TG_CHAT_ID" | grep -qE '^-?[0-9]+$'; then
        break
    else
        echo -e "${RED}格式错误！Chat ID 必须是纯数字 (群组可能包含负号前缀)。${NC}"
    fi
done

echo -e "\n${CYAN}>>> [3/4] 基础配置确认...${NC}"
printf "请输入 Syslog-ng 系统日志源名称 (直接回车默认为 s_sys): "
read -r SRC_NAME
[ -z "$SRC_NAME" ] && SRC_NAME="s_sys"

echo -e "\n${CYAN}[4/4] 请选择需要监控的核心行为 (多个选项用空格分隔):${NC}"
echo -e "  ${GREEN}1)${NC} sshd      (仅监控 SSH 登录成功)"
echo -e "  ${GREEN}2)${NC} login     (仅监控 本地 TTY 登录成功)"
echo -e "  ${GREEN}3)${NC} doas su   (仅监控 doas su 切换为 root 用户)"
echo -e "  ${RED}4)${NC} doas-all  (${YELLOW}偏执狂模式: 监控所有单次 doas 提权命令${NC})"
printf "输入数字序号 (直接回车默认选择 1 2 3): "
read -r MON_OPTIONS

[ -z "$MON_OPTIONS" ] && MON_OPTIONS="1 2 3"

# 动态生成 Syslog-ng 的原生结构化匹配规则
SYSLOG_FILTER=""
for opt in $MON_OPTIONS; do
    case $opt in
        1) SYSLOG_FILTER="${SYSLOG_FILTER}(program(\"sshd\") and message(\"Accepted\")) or " ;;
        2) SYSLOG_FILTER="${SYSLOG_FILTER}(message(\"login\") and message(\"Success\")) or " ;;
        3) SYSLOG_FILTER="${SYSLOG_FILTER}message(\"ran command su\") or " ;;
        4) SYSLOG_FILTER="${SYSLOG_FILTER}message(\"ran command\") or " ;;
    esac
done
SYSLOG_FILTER=$(echo "$SYSLOG_FILTER" | sed 's/ or $//')

if [ -z "$SYSLOG_FILTER" ]; then exit 1; fi

echo -e "${CYAN}>>> 正在同步更新系统并安装底层依赖...${NC}"
apk update
apk add -u doas postfix curl syslog-ng

# 切换日志服务接管者
service syslog stop 2>/dev/null || true
rc-update del syslog default 2>/dev/null || true
rc-update add syslog-ng default

# ==========================================
# 1. 构建 防泄漏版 Telegram 转发网关
# ==========================================
echo -e "${CYAN}>>> 正在构建防泄漏 Telegram 网关...${NC}"
cat << EOF > /usr/local/bin/send_tg_alert.sh
#!/bin/sh
MAIL_CONTENT=\$(cat)
SUBJECT=\$(echo "\$MAIL_CONTENT" | grep -i '^Subject:' | sed 's/^Subject:[[:space:]]*//i' | tr -d '\r\n')

if ! echo "\$SUBJECT" | grep -q "Login Monitor"; then exit 0; fi

BODY=\$(echo "\$MAIL_CONTENT" | sed '1,/^$/d')

# 标准输入提取，杜绝 cmdline 参数泄漏
HTTP_CODE=\$(echo "\$BODY" | curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="${TG_CHAT_ID}" \\
    --data-urlencode "text@-")

if [ "\$HTTP_CODE" != "200" ]; then exit 75; fi
exit 0
EOF

chown root:nobody /usr/local/bin/send_tg_alert.sh
chmod 550 /usr/local/bin/send_tg_alert.sh

# ==========================================
# 2. 配置 Postfix MTA 网络隔离
# ==========================================
echo -e "${CYAN}>>> 正在配置 Postfix 本地高可用安全队列...${NC}"
echo "tg-alert: |\"/usr/local/bin/send_tg_alert.sh\"" >> /etc/aliases
postconf -e "alias_maps = lmdb:/etc/aliases"
postconf -e "alias_database = lmdb:/etc/aliases"
postconf -e "inet_interfaces = loopback-only"
postconf -e "default_privs = nobody"

newaliases
postsuper -d ALL || true
rc-update add postfix default
service postfix restart

# ==========================================
# 3. 构建 零负载版 日志解析器
# ==========================================
echo -e "${CYAN}>>> 正在部署零负载日志解析引擎...${NC}"
cat << 'EOF' > /usr/local/bin/doas_parser.sh
#!/bin/sh
while read -r line; do
    TIME=$(date "+%Y-%m-%d %H:%M:%S %Z")
    HOST=$(hostname)
    USER_VAL="Unknown"
    SRC_VAL="Local"
    SVC_VAL="Unknown"

    if echo "$line" | grep -q -i "sshd"; then
        SVC_VAL="sshd"
        USER_VAL=$(echo "$line" | grep -oE '(for|user) [^ ]+' | head -n 1 | awk '{print $2}')
        SRC_VAL=$(echo "$line" | grep -oE 'from [^ ]+' | head -n 1 | awk '{print $2}')
        
    elif echo "$line" | grep -q -i "login"; then
        SVC_VAL="login"
        USER_VAL=$(echo "$line" | grep -i -oE '([^ ]+) login on' | head -n 1 | awk '{print $1}')
        SRC_VAL=$(echo "$line" | grep -oE "on '[^']+'|on tty[0-9]+" | head -n 1 | sed "s/on //; s/'//g")
        
    elif echo "$line" | grep -q -i "ran command"; then
        SVC_VAL="doas"
        echo "$line" | grep -q -i "ran command su" && SVC_VAL="doas su"
        USER_VAL=$(echo "$line" | awk -F' ran command' '{print $1}' | awk '{print $NF}')
        SRC_VAL="Local"
    fi

    [ -z "$USER_VAL" ] && USER_VAL="Unknown"
    [ -z "$SRC_VAL" ] && SRC_VAL="Unknown"

    BODY="主机: $HOST\n用户: $USER_VAL\n来源: $SRC_VAL\n时间: $TIME\n服务: $SVC_VAL"
    echo -e "$BODY" | mail -s "Login Monitor" tg-alert
done
EOF

chown root:root /usr/local/bin/doas_parser.sh
chmod 500 /usr/local/bin/doas_parser.sh

# ==========================================
# 4. 注入 Syslog-ng 高级路由规则
# ==========================================
echo -e "${CYAN}>>> 正在挂载 Syslog-ng 原生事件管道...${NC}"
mkdir -p /etc/syslog-ng/conf.d

cat << EOF > /etc/syslog-ng/conf.d/paranoia.conf
filter f_paranoia {
    $SYSLOG_FILTER
};

destination d_paranoia {
    program("/usr/local/bin/doas_parser.sh");
};

log {
    source($SRC_NAME);
    filter(f_paranoia);
    destination(d_paranoia);
};
EOF

service syslog-ng restart

# ==========================================
# 5. 物理控制台钩子
# ==========================================
cat << 'EOF' > /etc/profile.d/tty_alert.sh
#!/bin/sh
if [ -z "$SSH_CLIENT" ] && [ -z "$SSH_TTY" ]; then
    logger -p auth.info "login[$$]: $USER login on '$(tty | sed 's|/dev/||')' (Success)"
fi
EOF
chmod +x /etc/profile.d/tty_alert.sh

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 部署完成！${NC}"
echo -e "日志挂载点: ${YELLOW}$SRC_NAME${NC}"
echo -e "已生效规则: ${YELLOW}$SYSLOG_FILTER${NC}"
echo -e "${GREEN}==========================================${NC}"
