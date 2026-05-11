#!/usr/bin/env bash

# ----------------------------------------
# 启用严格模式 (Strict Mode)
# ----------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "❌ 错误: 请使用 root 权限运行此脚本。" >&2
   exit 1
fi

# ========================================
# 变量初始化与参数解析
# ========================================
INTERACTIVE=true
USERNAME=""
SET_PASSWORD=""
SSH_KEY_IN=""
FLAG_ADMIN=false
FLAG_NOPASSWD=false
FLAG_NO_HOME=false
FLAG_FORCE=false

usage() {
    echo "========================================"
    echo "          新用户初始化配置脚本          "
    echo "========================================"
    echo "用法: $0 [选项]"
    echo "选项 (带参数即进入非交互模式):"
    echo "  -u <username>   指定用户名 (非交互模式必填)"
    echo "  -p <password>   设置系统密码 (⚠️ 警告: 密码明文传参可能被 ps 捕捉，建议通过交互模式或环境变量传递)"
    echo "  -k <ssh_key>    设置 SSH 公钥字符串"
    echo "  -a              将用户加入管理员组 (sudo/wheel)"
    echo "  -n              为该用户配置免密 sudo (NOPASSWD)"
    echo "  -M              不创建独立主目录 (仅创建 .ssh 所需结构)"
    echo "  -f              强制模式 (覆盖而非追加 SSH 密钥)"
    echo "  -h              显示此帮助信息"
    exit 1
}

# 解析命令行参数
while getopts "u:p:k:anMfh" opt; do
    case $opt in
        u) USERNAME="$OPTARG"; INTERACTIVE=false ;;
        p) SET_PASSWORD="$OPTARG"; INTERACTIVE=false ;;
        k) SSH_KEY_IN="$OPTARG"; INTERACTIVE=false ;;
        a) FLAG_ADMIN=true; INTERACTIVE=false ;;
        n) FLAG_NOPASSWD=true; INTERACTIVE=false ;;
        M) FLAG_NO_HOME=true; INTERACTIVE=false ;;
        f) FLAG_FORCE=true; INTERACTIVE=false ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ "$INTERACTIVE" == "false" && -z "$USERNAME" ]]; then
    echo "❌ 非交互模式下必须通过 -u 指定用户名！" >&2
    exit 1
fi

# ========================================
# 状态追踪变量 (基于实际落地状态)
# ========================================
USER_EXISTS=false
STATUS_PASSWORD="未设置"
STATUS_HOME="未知"
STATUS_ADMIN="否"
STATUS_NOPASSWD="否"
STATUS_SSH="未配置"

# ========================================
# 1. 交互式数据采集
# ========================================
if [[ "$INTERACTIVE" == "true" ]]; then
    echo "========================================"
    echo "          新用户初始化配置脚本          "
    echo "========================================"
    
    # 采集用户名
    while true; do
        read -p "请输入要操作的用户名 [默认: workforce]: " INPUT_USER
        USERNAME=${INPUT_USER:-workforce}
        if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            echo "⚠️ 错误: 用户名不合法。请使用小写字母、数字或下划线。"
            continue
        fi
        break
    done

    # 检查用户是否存在，动态调整询问逻辑
    if id "$USERNAME" &>/dev/null; then
        echo "ℹ️ 提示: 用户 '$USERNAME' 已存在。后续操作将作为 [更新] 执行。"
        USER_EXISTS=true
        STATUS_PASSWORD="原有状态 (未修改)"
    fi

    # 采集密码
    echo "----------------------------------------"
    if [[ "$USER_EXISTS" == "true" ]]; then
        echo "👉 该用户已存在，若要重置密码请输入，否则直接回车跳过:"
    else
        echo "👉 请为 '$USERNAME' 设置密码 (直接按回车可跳过):"
    fi

    while true; do
        read -s -p "密码: " PASS1
        echo
        if [[ -z "$PASS1" ]]; then
            # 只有新用户跳过密码时才需要二次确认防呆
            if [[ "$USER_EXISTS" == "false" ]]; then
                read -s -p "⚠️ 密码为空！【再次按回车】确认跳过 (输入任意字符取消): " PASS2
                echo
                if [[ -z "$PASS2" ]]; then
                    echo "ℹ️ 确认跳过。用户将无初始密码。"
                    STATUS_PASSWORD="无密码"
                    break
                else
                    continue
                fi
            else
                break
            fi
        else
            read -s -p "请再次输入密码以确认: " PASS2
            echo
            if [[ "$PASS1" == "$PASS2" ]]; then
                SET_PASSWORD="$PASS1"
                break
            else
                echo "❌ 两次密码不一致，请重试。"
            fi
        fi
    done

    # 若为新用户，采集家目录需求
    if [[ "$USER_EXISTS" == "false" ]]; then
        echo "----------------------------------------"
        read -p "是否为 '$USERNAME' 创建独立主目录？[Y/n 默认: Y]: " PROMPT_HOME
        if [[ ! "${PROMPT_HOME:-Y}" =~ ^[Yy]$ ]]; then
            FLAG_NO_HOME=true
        fi
    fi

    # 采集提权需求
    echo "----------------------------------------"
    read -p "是否将 '$USERNAME' 加入管理员组 (sudo/wheel)？[Y/n 默认: Y]: " PROMPT_ADMIN
    if [[ "${PROMPT_ADMIN:-Y}" =~ ^[Yy]$ ]]; then
        FLAG_ADMIN=true
        read -p "是否配置免密 sudo (NOPASSWD)？[y/N 默认: N]: " PROMPT_NOPASSWD
        if [[ "${PROMPT_NOPASSWD:-N}" =~ ^[Yy]$ ]]; then
            FLAG_NOPASSWD=true
        fi
    fi

    # 采集 SSH 密钥
    echo "----------------------------------------"
    while true; do
        echo "请输入 '$USERNAME' 的 SSH 公钥 (支持粘贴并回车，输入 'skip' 跳过):"
        read -r SSH_KEY_IN
        if [[ "$SSH_KEY_IN" == "skip" || -z "$SSH_KEY_IN" ]]; then
            SSH_KEY_IN=""
            break
        fi
        if [[ ! "$SSH_KEY_IN" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
            echo "⚠️ 错误: 无法识别的 SSH 密钥格式！"
            continue
        fi
        break
    done

    # 针对已存在用户配置是否强制覆盖密钥
    if [[ -n "$SSH_KEY_IN" ]]; then
        read -p "是否强制覆盖现有的 SSH 密钥 (选 n 则追加)？[y/N 默认: N]: " PROMPT_FORCE
        if [[ "${PROMPT_FORCE:-N}" =~ ^[Yy]$ ]]; then
            FLAG_FORCE=true
        fi
    fi
fi

# ========================================
# 2. 执行与部署逻辑 (交/非交互统一处理)
# ========================================

# 初始化非交互模式下存在的用户状态
if [[ "$INTERACTIVE" == "false" ]]; then
    if id "$USERNAME" &>/dev/null; then
        USER_EXISTS=true
        STATUS_PASSWORD="原有状态 (未修改)"
    else
        STATUS_PASSWORD="无密码"
    fi
fi

# 创建用户与设置密码
if [[ "$USER_EXISTS" == "false" ]]; then
    CREATE_HOME_FLAG="-m"
    [[ "$FLAG_NO_HOME" == "true" ]] && CREATE_HOME_FLAG="-M"
    useradd "$CREATE_HOME_FLAG" -s /bin/bash "$USERNAME" || { echo "❌ 创建用户失败！" >&2; exit 1; }
fi

if [[ -n "$SET_PASSWORD" ]]; then
    echo "$USERNAME:$SET_PASSWORD" | chpasswd || { echo "❌ 密码写入失败！" >&2; exit 1; }
    STATUS_PASSWORD="已设置 (手工指定)"
fi

# 家目录路径与状态探测 (多级 Fallback 机制)
# 优先级1: awk 解析 passwd (高兼容性)
USER_HOME=$(awk -F: -v user="$USERNAME" '$1 == user {print $6}' /etc/passwd 2>/dev/null || true)
# 优先级2: getent (针对 LDAP/NIS 等网络账户)
if [[ -z "$USER_HOME" ]]; then
    USER_HOME=$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || true)
fi
# 优先级3: 硬编码兜底
if [[ -z "$USER_HOME" ]]; then
    USER_HOME="/home/$USERNAME"
    echo "⚠️ 警告: 无法通过系统接口获取家目录，使用兜底路径 $USER_HOME" >&2
fi

if [[ -d "$USER_HOME" ]]; then
    STATUS_HOME="已就绪"
    chmod 750 "$USER_HOME" || { echo "⚠️ 警告: 修改 $USER_HOME 权限失败！" >&2; }
else
    STATUS_HOME="未创建/路径缺失"
fi

# 提权配置 (严格死锁拦截)
if [[ "$FLAG_ADMIN" == "true" ]]; then
    # 拦截：新用户 + 无密码设定 + 未开 NOPASSWD = 死锁
    if [[ "$USER_EXISTS" == "false" && -z "$SET_PASSWORD" && "$FLAG_NOPASSWD" == "false" ]]; then
        echo "🚨 致命错误: 该用户无密码且未开启 NOPASSWD！提权会导致密码验证死锁。" >&2
        echo "   -> 已主动中止管理员组添加操作。" >&2
    else
        # 兼容 sudo 或 wheel
        if getent group sudo > /dev/null 2>&1; then
            usermod -aG sudo "$USERNAME" || { echo "❌ usermod 失败" >&2; exit 1; }
            STATUS_ADMIN="是 (sudo组)"
        elif getent group wheel > /dev/null 2>&1; then
            usermod -aG wheel "$USERNAME" || { echo "❌ usermod 失败" >&2; exit 1; }
            STATUS_ADMIN="是 (wheel组)"
        else
            echo "⚠️ 警告: 系统中既无 sudo 也无 wheel 组。" >&2
        fi

        # 写入 sudoers
        if [[ "$FLAG_NOPASSWD" == "true" && "$STATUS_ADMIN" != "否" ]]; then
            SUDOERS_FILE="/etc/sudoers.d/99-$USERNAME"
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE" || { echo "❌ 写入 sudoers 失败" >&2; exit 1; }
            chmod 0440 "$SUDOERS_FILE" || { echo "❌ 修改 sudoers 权限失败" >&2; exit 1; }
            STATUS_NOPASSWD="是"
        fi
    fi
fi

# SSH 密钥写入
if [[ -n "$SSH_KEY_IN" ]]; then
    if [[ "$SSH_KEY_IN" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
        SSH_DIR="${USER_HOME}/.ssh"
        AUTH_FILE="${SSH_DIR}/authorized_keys"

        mkdir -p "$SSH_DIR" || { echo "❌ 目录创建失败" >&2; exit 1; }
        chmod 700 "$SSH_DIR" || { echo "❌ 目录提权失败" >&2; exit 1; }

        if [[ "$FLAG_FORCE" == "true" ]]; then
            echo "$SSH_KEY_IN" > "$AUTH_FILE" || { echo "❌ 密钥覆盖失败" >&2; exit 1; }
            STATUS_SSH="已配置 (强制覆盖)"
        else
            echo "$SSH_KEY_IN" >> "$AUTH_FILE" || { echo "❌ 密钥追加失败" >&2; exit 1; }
            STATUS_SSH="已配置 (追加写入)"
        fi
        
        chmod 600 "$AUTH_FILE" || { echo "❌ 密钥文件提权失败" >&2; exit 1; }
        chown -R "$USERNAME":"$USERNAME" "$SSH_DIR" || { echo "❌ 属主修改失败" >&2; exit 1; }
    else
        echo "⚠️ 警告: 传入的 SSH 密钥格式错误，已被丢弃。" >&2
    fi
fi

# ========================================
# 3. 部署总结
# ========================================
echo "========================================"
echo "          🎉 部署总结 🎉          "
echo "========================================"
echo -e "用户名:\t\t $USERNAME"
echo -e "家目录状态:\t $STATUS_HOME ($USER_HOME)"
echo -e "系统密码:\t $STATUS_PASSWORD"
echo -e "管理员组:\t $STATUS_ADMIN"
echo -e "免密 sudo:\t $STATUS_NOPASSWD"
echo -e "SSH 密钥:\t $STATUS_SSH"
echo "========================================"
