#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (例如: sudo bash install_gonic.sh)"
  exit 1
fi

echo "======================================"
echo "    Gonic 安装与自动更新脚本 (优化版)   "
echo "======================================"

# 1. 获取 GitHub 最新 Release 版本号
echo ">> 正在获取 Gonic 最新版本号..."
LATEST_TAG=$(curl -s https://api.github.com/repos/sentriz/gonic/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "错误: 无法获取最新版本号，请检查网络连接或 GitHub 访问。"
    exit 1
fi
echo "线上最新版本为: $LATEST_TAG"

# 2. 检测本地状态并判定是安装还是升级
IS_UPDATE=0
if [ -f "/etc/gonic/config" ] && [ -x "/usr/local/bin/gonic" ]; then
    # 获取本地版本，只提取第一串字符避免多余的换行符
    LOCAL_VERSION=$(/usr/local/bin/gonic -version | awk '{print $1}')
    
    if [ "$LOCAL_VERSION" == "$LATEST_TAG" ]; then
        echo ">> 检查完毕: 本地已是最新版本 ($LOCAL_VERSION)，无需更新。退出脚本。"
        exit 0
    else
        echo ">> 发现新版本: $LOCAL_VERSION -> 将升级至 $LATEST_TAG"
        IS_UPDATE=1
    fi
else
    echo ">> 未检测到已存在的配置文件，准备执行全新安装..."
fi

# 3. 判断系统架构
echo ">> 正在检测系统架构..."
OS_ARCH=$(uname -m)
case $OS_ARCH in
    x86_64)
        GONIC_ARCH="amd64"
        ;;
    aarch64)
        GONIC_ARCH="arm64"
        ;;
    i386|i686)
        GONIC_ARCH="386"
        ;;
    *)
        echo "错误: 不支持的架构 $OS_ARCH"
        exit 1
        ;;
esac
echo "检测到架构: $GONIC_ARCH"

# 4. 停止正在运行的服务 (防锁死)
if [ $IS_UPDATE -eq 1 ]; then
    echo ">> [升级] 正在停止 gonic 服务释放文件占用..."
    systemctl stop gonic
fi

# 5. 构造下载链接并拉取二进制文件
DOWNLOAD_URL="https://github.com/sentriz/gonic/releases/download/${LATEST_TAG}/gonic-linux-${GONIC_ARCH}-${LATEST_TAG}"
echo ">> 正在下载二进制文件: $DOWNLOAD_URL"

wget -q --show-progress -O /usr/local/bin/gonic "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo "错误: 下载失败！"
    # 如果更新下载失败，尝试把旧版服务重新拉起来避免业务中断
    [ $IS_UPDATE -eq 1 ] && systemctl start gonic
    exit 1
fi

# 赋予执行权限
chmod +x /usr/local/bin/gonic
echo ">> 二进制文件已就绪: /usr/local/bin/gonic"

# 6. 环境配置分流逻辑
if [ $IS_UPDATE -eq 0 ]; then
    # 【全新安装分支】
    echo ">> [全新安装] 正在创建专用 gonic 用户与系统目录..."
    adduser --system --no-create-home --group gonic
    mkdir -p /var/lib/gonic/  /var/lib/gonic/podcasts /var/lib/gonic/playlists /etc/gonic/
    chown -R gonic:gonic /var/lib/gonic/

    echo ">> [全新安装] 正在拉取官方 config 和 systemd 配置文件..."
    wget -q -O /etc/gonic/config https://raw.githubusercontent.com/sentriz/gonic/master/contrib/config
    wget -q -O /etc/systemd/system/gonic.service https://raw.githubusercontent.com/sentriz/gonic/master/contrib/gonic.service
    
    echo ">> 正在重载 systemd 守护进程..."
    systemctl daemon-reload
    systemctl enable gonic

    echo "======================================"
    echo "全新安装完成！"
    echo ""
    echo "⚠️ 重要提示: 服务已设置为开机自启，但目前尚未启动。"
    echo "你必须先编辑配置文件，指定你的音乐目录："
    echo "   sudo nano /etc/gonic/config"
    echo "将其中的 music-path 修改为你的实际路径"
    echo "修改完成后，使用以下命令启动服务："
    echo "   sudo systemctl start gonic"
    echo "======================================"
else
    # 【更新升级分支】
    echo ">> [升级完毕] 正在重新启动 gonic 服务..."
    systemctl daemon-reload
    systemctl start gonic
    
    echo "======================================"
    echo "服务升级完成！当前运行版本: $LATEST_TAG"
    echo "======================================"
fi
