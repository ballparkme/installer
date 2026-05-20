#!/bin/sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 生成精确到秒的时间戳，彻底防止多实例部署时文件名撞车
TS=$(date +%Y%m%d%H%M%S)
SCRIPT_NAME="tg_forwarder_${TS}.sh"
CONF_NAME="tg_${TS}.conf"

# ==========================================
# 交互配置阶段 1：扫描并强制索取通道与主题
# ==========================================
echo -e "${CYAN}>>> 扫描当前系统已存在的邮件通道 (Aliases)...${NC}"
if grep -qE '^[a-zA-Z0-9_-]+:' /etc/aliases; then
    grep -E '^[a-zA-Z0-9_-]+:' /etc/aliases | awk -F':' '{printf "  %s%-15s%s -> %s\n", "\033[1;33m", $1, "\033[0m", $2}'
else
    echo "  (当前系统无任何自定义通道)"
fi

# 强校验通道名称 (无默认值，必须输入)
while true; do
    printf "\n${CYAN}请输入要绑定的别名通道名称 (例如 Telegram, 不能为空): ${NC}"
    read -r CH_NAME
    if [ -z "$CH_NAME" ]; then
        echo -e "${RED}输入错误！通道名不能为空，请参考上方列表进行输入。${NC}"
        continue
    fi
    if echo "$CH_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        break
    else
        echo -e "${RED}输入错误！通道名只能包含字母、数字、下划线和短横线。${NC}"
    fi
done

# 强校验邮件主题 (无默认值，必须输入)
while true; do
    printf "${CYAN}请输入该转发器需要拦截的特定邮件主题 (例如 Login Monitor, 不能为空): ${NC}"
    read -r MAIL_SUBJECT
    if [ -n "$MAIL_SUBJECT" ]; then
        break
    else
        echo -e "${RED}输入错误！邮件主题不能为空。${NC}"
    fi
done

# ==========================================
# 交互配置阶段 2：校验 Telegram 凭据
# ==========================================
echo -e "\n${CYAN}>>> 配置并校验 Telegram 机器人凭据...${NC}"
while true; do
    printf "请输入 Telegram Bot Token (10位数字:35位字符): "
    read -r TG_BOT_TOKEN
    if echo "$TG_BOT_TOKEN" | grep -qE '^[0-9]{10}:[a-zA-Z0-9_-]{35}$'; then
        break
    else
        echo -e "${RED}格式错误！Token 必须严格遵守 [10位纯数字:35位字符] 的格式。${NC}"
    fi
done

while true; do
    printf "请输入 Telegram Chat ID (10位纯数字): "
    read -r TG_CHAT_ID
    if echo "$TG_CHAT_ID" | grep -qE '^[0-9]{10}$'; then
        break
    else
        echo -e "${RED}格式错误！Chat ID 必须是严格的 10 位纯数字。${NC}"
    fi
done

# ==========================================
# 核心智能清理阶段（后悔药：双重身份校验防误杀）
# ==========================================
echo -e "\n${CYAN}>>> 正在检查并清理该通道上针对同一主题的旧转发实例...${NC}"
# 扫描所有旧的时间戳脚本
for old_script in /usr/local/bin/tg_forwarder_*.sh; do
    if [ -f "$old_script" ]; then
        # 必须同时匹配 "通道名" 和 "邮件主题" 才能判定为需要覆盖的历史垃圾
        if grep -q "TARGET_CHANNEL='${CH_NAME}'" "$old_script" 2>/dev/null && \
           grep -q "MAIL_SUBJECT='${MAIL_SUBJECT}'" "$old_script" 2>/dev/null; then
           
            echo -e "${YELLOW}发现通道 [${CH_NAME}] 针对主题 '${MAIL_SUBJECT}' 的旧转发器 $(basename $old_script)，正在卸载...${NC}"
            # 从别名表中擦除旧管道
            sed -i "s@|[[:space:]]*\"$old_script\"@@g" /etc/aliases
            # 清理可能导致的逗号和冒号格式错乱
            sed -i "s@,[[:space:]]*,@,@g" /etc/aliases
            sed -i "s@:[[:space:]]*,@: @g" /etc/aliases
            sed -i "s@,[[:space:]]*$@@g" /etc/aliases
            sed -i "s@:[[:space:]]*$@: root@g" /etc/aliases # 若删空了，默认退回给 root 补底
            
            # 彻底物理删除旧脚本与旧凭据
            rm -f "$old_script"
            old_ts=$(basename "$old_script" | grep -oE '[0-9]+')
            rm -f "/etc/alert-gateway/tg_${old_ts}.conf"
        fi
    fi
done

# ==========================================
# 核心部署阶段
# ==========================================
echo -e "${CYAN}>>> 正在写入专属凭据并配置安全权限...${NC}"
mkdir -p /etc/alert-gateway
echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'" > /etc/alert-gateway/${CONF_NAME}
echo "TG_CHAT_ID='${TG_CHAT_ID}'" >> /etc/alert-gateway/${CONF_NAME}
chown root:nobody /etc/alert-gateway/${CONF_NAME}
chmod 440 /etc/alert-gateway/${CONF_NAME}

echo -e "${CYAN}>>> 正在生成专属 TG 转发处理器 [${SCRIPT_NAME}]...${NC}"

# 第一步：动态注入身份标识与配置变量
cat << EOF > /usr/local/bin/${SCRIPT_NAME}
#!/bin/sh
# --- 实例身份标识 (用于防碰撞与智能清理) ---
TARGET_CHANNEL='${CH_NAME}'
MAIL_SUBJECT='${MAIL_SUBJECT}'

# --- 读取本实例专属的独立凭据 ---
. /etc/alert-gateway/${CONF_NAME}
EOF

# 第二步：安全追加静态核心逻辑
cat << 'EOF' >> /usr/local/bin/${SCRIPT_NAME}
MAIL_CONTENT=$(cat)
SUBJECT=$(echo "$MAIL_CONTENT" | grep -i '^Subject:' | sed 's/^Subject:[[:space:]]*//i' | tr -d '\r\n')

# 核心逻辑：动态主题过滤
if ! echo "$SUBJECT" | grep -q "$MAIL_SUBJECT"; then 
    exit 0 
fi

BODY=$(echo "$MAIL_CONTENT" | sed '1,/^$/d')

# 发送至 Telegram (带超时防护)
HTTP_CODE=$(echo "$BODY" | curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 -m 30 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    --data-urlencode "text@-")

# 队列重试机制
if [ "$HTTP_CODE" != "200" ]; then 
    exit 75 
fi

exit 0
EOF

chown nobody:nobody /usr/local/bin/${SCRIPT_NAME}
chmod 500 /usr/local/bin/${SCRIPT_NAME}

echo -e "${CYAN}>>> 正在将全新转发器无损挂载至邮件通道 [${CH_NAME}]...${NC}"
if grep -q "^${CH_NAME}:" /etc/aliases; then
    # 如果别名通道已存在，使用 @ 分隔符安全追加到末尾，绝不破坏前人规则
    sed -i "s@^${CH_NAME}:.*@&, |\"/usr/local/bin/${SCRIPT_NAME}\"@_CF" /etc/aliases 2>/dev/null || \
    sed -i "s@^${CH_NAME}:.*@&, |\"/usr/local/bin/${SCRIPT_NAME}\"@" /etc/aliases
else
    # 如果通道不存在，直接创建全新的规则
    echo "${CH_NAME}: |\"/usr/local/bin/${SCRIPT_NAME}\"" >> /etc/aliases
fi

newaliases

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 多实例通用转发器部署成功！${NC}"
echo -e "专属处理器: ${YELLOW}/usr/local/bin/${SCRIPT_NAME}${NC}"
echo -e "专属凭证表: ${YELLOW}/etc/alert-gateway/${CONF_NAME}${NC}"
echo -e "监听别名通道: ${YELLOW}${CH_NAME}${NC}"
echo -e "精确拦截主题: ${YELLOW}${MAIL_SUBJECT}${NC}"
echo -e "${GREEN}==========================================${NC}"
