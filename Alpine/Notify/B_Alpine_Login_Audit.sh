#!/bin/sh
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==========================================
# 交互配置阶段 1：选择监控事件
# ==========================================
echo -e "${CYAN}>>> 请选择需要监控的安全事件 (多个选项用空格分隔):${NC}"
echo -e "  ${GREEN}1) 🟢 SSH 登录成功${NC}"
echo -e "  ${GREEN}2) 🟢 TTY 登录成功${NC}"
echo -e "  ${RED}3) 🔴 TTY 登录失败${NC}"
echo -e "  ${GREEN}4) 🟢 DOAS 切换用户成功${NC}"
echo -e "  ${RED}5) 🔴 DOAS 失败 (包含密码错误、权限不足等所有失败情况)${NC}"
echo -e "  ${YELLOW}6) 🟢 DOAS 提权成功 (偏执狂模式，普通提权通知极多)${NC}"
printf "输入数字序号 (直接回车默认监控除了 6 之外的所有项目): "
read -r MON_OPTIONS

[ -z "$MON_OPTIONS" ] && MON_OPTIONS="1 2 3 4 5"

USE_1=0; USE_2=0; USE_3=0; USE_4=0; USE_5=0; USE_6=0
for opt in $MON_OPTIONS; do
    case $opt in
        1) USE_1=1 ;; 2) USE_2=1 ;; 3) USE_3=1 ;; 
        4) USE_4=1 ;; 5) USE_5=1 ;; 6) USE_6=1 ;;
    esac
done

SYSLOG_FILTER=""
[ "$USE_1" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}(program(\"sshd\") and message(\"Accepted\")) or "
[ "$USE_2" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}(message(\"login on\") and message(\"Success\")) or "
[ "$USE_3" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}message(\"invalid password\") or message(\"FAILED\") or "
[ "$USE_4" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}message(\"ran command su\") or "
[ "$USE_6" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}message(\"ran command\") or "
[ "$USE_5" = "1" ] && SYSLOG_FILTER="${SYSLOG_FILTER}message(\"failed auth for\") or message(\"failed command for\") or "

SYSLOG_FILTER=$(echo "$SYSLOG_FILTER" | sed 's/ or $//')

if [ -z "$SYSLOG_FILTER" ]; then
    echo -e "${RED}未选择任何监控项，退出部署。${NC}"
    exit 1
fi

# ==========================================
# 交互配置阶段 2：选择通知通道与主题
# ==========================================
echo -e "\n${CYAN}>>> 扫描当前系统已存在的邮件通道 (Aliases)...${NC}"
# 过滤出所有非注释的有效别名定义，并格式化输出
if grep -qE '^[a-zA-Z0-9_-]+:' /etc/aliases; then
    grep -E '^[a-zA-Z0-9_-]+:' /etc/aliases | awk -F':' '{printf "  %s%-15s%s -> %s\n", "\033[1;33m", $1, "\033[0m", $2}'
else
    echo "  (当前系统无任何自定义通道)"
fi

# 强校验通道名称 (无默认值，强制要求输入)
while true; do
    printf "\n请输入接收通知的通道名称或本地用户名 (例如 Telegram, 不能为空): "
    read -r CH_NAME
    
    if [ -z "$CH_NAME" ]; then
        echo -e "${RED}输入错误！通道名不能为空，请参考上方列表进行输入。${NC}"
        continue
    fi
    
    if echo "$CH_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        break
    else
        echo -e "${RED}格式错误！通道名只能包含字母、数字、下划线和短横线。${NC}"
    fi
done

# 设定邮件主题 (保留默认值，方便日常监控直接回车)
printf "请输入报警邮件的主题 (直接回车默认为 Login Monitor): "
read -r MAIL_SUBJECT
[ -z "$MAIL_SUBJECT" ] && MAIL_SUBJECT="Login Monitor"


# ==========================================
# 核心部署阶段
# ==========================================
echo -e "\n${CYAN}>>> 正在安装日志解析依赖...${NC}"
apk update && apk add -u syslog-ng
rc-update del syslog default 2>/dev/null || true
rc-update add syslog-ng default

echo -e "${CYAN}>>> 正在生成零负载日志解析引擎...${NC}"

# 巧妙地将用户指定的 通道 和 主题 以单引号的安全形式注入到解析脚本头部
cat << EOF > /usr/local/bin/doas_parser.sh
#!/bin/sh
MON_OPTIONS=",$(echo $MON_OPTIONS | tr ' ' ','),"
TARGET_CHANNEL='${CH_NAME}'
MAIL_SUBJECT='${MAIL_SUBJECT}'
EOF

# 追加解析器逻辑
cat << 'EOF' >> /usr/local/bin/doas_parser.sh
while read -r line; do
    TIME=$(date "+%Y-%m-%d %H:%M:%S %Z")
    HOST=$(hostname)
    USER_VAL="Unknown"
    SRC_VAL="Unknown"
    SVC_VAL="Unknown"
    STATUS_TITLE="⚪ 未知事件"

    # 1. SSH 登录
    if echo "$line" | grep -q -i "sshd"; then
        STATUS_TITLE="🟢 SSH 登录成功"
        SVC_VAL="sshd"
        USER_VAL=$(echo "$line" | grep -oE '(for|user) [^ ]+' | head -n 1 | awk '{print $2}')
        SRC_VAL=$(echo "$line" | grep -oE 'from [^ ]+' | head -n 1 | awk '{print $2}')
        
    # 2. TTY 登录
    elif echo "$line" | grep -q -i "login on" || echo "$line" | grep -q -i "invalid password"; then
        SVC_VAL="login"
        if echo "$line" | grep -q -i "Success"; then
            STATUS_TITLE="🟢 TTY 登录成功"
            USER_VAL=$(echo "$line" | grep -oE '[a-zA-Z0-9_-]+ login on' | head -n 1 | awk '{print $1}')
            SRC_VAL=$(echo "$line" | grep -oE "on '[^']+'" | head -n 1 | sed "s/on '//; s/'//")
        else
            STATUS_TITLE="🔴 TTY 登录失败"
            USER_VAL=$(echo "$line" | grep -oE "for '[^']+'" | head -n 1 | sed "s/for '//; s/'//")
            SRC_VAL=$(echo "$line" | grep -oE "on '[^']+'" | head -n 1 | sed "s/on '//; s/'//")
        fi
        
    # 3. DOAS 提权行为
    elif echo "$line" | grep -q -i "ran command"; then
        SVC_VAL="doas"
        USER_VAL=$(echo "$line" | awk -F' ran command' '{print $1}' | awk '{print $NF}' | tr -d ':')
        SRC_VAL="Local"
        if echo "$line" | grep -q -i "ran command su"; then
            STATUS_TITLE="🟢 DOAS 切换用户成功"
            SVC_VAL="doas su"
        else
            STATUS_TITLE="🟢 DOAS 提权成功"
        fi
        
    # 4. 统一处理所有的 DOAS 失败 (极简逻辑)
    elif echo "$line" | grep -q -i -E "failed auth for|failed command for"; then
        SVC_VAL="doas"
        USER_VAL=$(echo "$line" | grep -oE 'for [^:]+' | head -n 1 | awk '{print $2}' | tr -d "'")
        SRC_VAL="Local"
        STATUS_TITLE="🔴 DOAS 失败"
    fi

    [ -z "$USER_VAL" ] && USER_VAL="Unknown"
    [ -z "$SRC_VAL" ] && SRC_VAL="Unknown"

    EVENT_ID=0
    [ "$STATUS_TITLE" = "🟢 SSH 登录成功" ] && EVENT_ID=1
    [ "$STATUS_TITLE" = "🟢 TTY 登录成功" ] && EVENT_ID=2
    [ "$STATUS_TITLE" = "🔴 TTY 登录失败" ] && EVENT_ID=3
    [ "$STATUS_TITLE" = "🟢 DOAS 切换用户成功" ] && EVENT_ID=4
    [ "$STATUS_TITLE" = "🔴 DOAS 失败" ] && EVENT_ID=5
    [ "$STATUS_TITLE" = "🟢 DOAS 提权成功" ] && EVENT_ID=6

    # 微观过滤并发送给用户指定的通道和主题
    if echo "$MON_OPTIONS" | grep -q ",$EVENT_ID,"; then
        BODY="${STATUS_TITLE}\n主机: ${HOST}\n用户: ${USER_VAL}\n来源: ${SRC_VAL}\n时间: ${TIME}\n服务: ${SVC_VAL}"
        printf "%b\n" "$BODY" | mail -s "$MAIL_SUBJECT" "$TARGET_CHANNEL"
    fi
done
EOF

chown root:root /usr/local/bin/doas_parser.sh
chmod 500 /usr/local/bin/doas_parser.sh

echo -e "${CYAN}>>> 正在挂载 Syslog-ng 高级路由规则...${NC}"
mkdir -p /etc/syslog-ng/conf.d

cat << EOF > /etc/syslog-ng/conf.d/paranoia.conf
filter f_paranoia {
    $SYSLOG_FILTER
};

destination d_paranoia {
    program("/usr/local/bin/doas_parser.sh");
};

log {
    source(s_sys);
    filter(f_paranoia);
    destination(d_paranoia);
};
EOF

service syslog-ng restart

sleep 2

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 登录监控审计部署完成！${NC}"
echo -e "日志挂载点: ${YELLOW}Syslog-ng s_sys${NC}"
echo -e "投递通道名: ${YELLOW}${CH_NAME}${NC}"
echo -e "触发的主题: ${YELLOW}${MAIL_SUBJECT}${NC}"
echo -e "${GREEN}==========================================${NC}"
