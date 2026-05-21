#!/bin/sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}>>> 正在部署通用本地邮件队列 (Postfix)...${NC}"
apk update && apk add -u postfix mailx

# 配置 Postfix 仅监听本地，拒绝外部网络连接
postconf -e "home_mailbox = Maildir/"
postconf -e "inet_interfaces = loopback-only"
postconf -e "default_privs = nobody"
postconf -e "alias_maps = lmdb:/etc/aliases"
postconf -e "alias_database = lmdb:/etc/aliases"

echo -e "\n${CYAN}>>> 扫描当前系统已存在的邮件通道 (Aliases)...${NC}"
# 过滤出所有非注释的有效别名定义，并格式化输出
if grep -qE '^[a-zA-Z0-9_-]+:' /etc/aliases; then
    grep -E '^[a-zA-Z0-9_-]+:' /etc/aliases | awk -F':' '{printf "  %s%-15s%s -> %s\n", "\033[1;33m", $1, "\033[0m", $2}'
else
    echo "  (当前系统无任何自定义通道)"
fi

echo -e "\n${CYAN}提示：建立独立的通道可以完美隔离报警信息与系统默认日志。${NC}"
printf "请输入您想创建的报警通道名称 (建议一个应用一个通道，通道名为应用名，直接回车跳过): "
read -r CH_NAME

# 处理用户的交互输入
if [ -n "$CH_NAME" ]; then
    # 严格校验通道名称格式 (仅限字母、数字、下划线、短横线)
    if echo "$CH_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        if ! grep -q "^${CH_NAME}:" /etc/aliases; then
            # 预留通道，指向 root（后续会被模块2接管）
            echo "${CH_NAME}: root" >> /etc/aliases
            echo -e "${GREEN}>>> 已成功为您预留通道: ${CH_NAME}${NC}"
        else
            echo -e "${YELLOW}>>> 通道 ${CH_NAME} 已经存在，无需重复创建。${NC}"
        fi
    else
        echo -e "${RED}格式错误！通道名只能包含字母、数字、下划线和短横线。本次跳过创建。${NC}"
        CH_NAME="" # 清空非法变量，防止后续误用
    fi
else
    echo -e "${GREEN}>>> 跳过通道预留操作。${NC}"
fi

# 编译别名数据库，应用配置
newaliases
rc-update add postfix default
service postfix restart

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 邮件队列引擎部署完成！${NC}"
if [ -n "$CH_NAME" ]; then
    echo -e "推荐后续通知模块对接至通道: ${YELLOW}${CH_NAME}${NC}"
else
    echo -e "本地高可用邮件队列已就绪。${NC}"
fi
echo -e "${GREEN}==========================================${NC}"
