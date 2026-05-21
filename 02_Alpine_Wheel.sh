#!/bin/sh

# 1. 检查是否以 root 身份运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本需要 root 权限，请使用 root 账户运行。"
    exit 1
fi

# 2. 询问要把哪个用户加入 wheel 组
printf "请输入要加入 wheel 组的用户名: "
read USERNAME

# 检查输入是否为空
if [ -z "$USERNAME" ]; then
    echo "错误：用户名不能为空。"
    exit 1
fi

# 3. 检查用户是否存在
if ! id "$USERNAME" >/dev/null 2>&1; then
    echo "错误：用户 '$USERNAME' 不存在，请先创建该用户 (例如执行: adduser $USERNAME)。"
    exit 1
fi

echo "----------------------------------------"
echo "正在将用户 '$USERNAME' 加入 wheel 组..."
addgroup "$USERNAME" wheel

echo "----------------------------------------"
echo "正在更新软件源并安装 doas..."
apk update
apk add doas

echo "----------------------------------------"
echo "正在配置 /etc/doas.d/doas.conf..."
# 确保配置目录存在
mkdir -p /etc/doas.d
# 写入配置：允许 wheel 组提权，并保持一段时间免密 (persist)
echo "permit persist :wheel" > /etc/doas.d/doas.conf

# 出于安全考虑，将配置文件的权限设置为仅 root 可读
chmod 0400 /etc/doas.d/doas.conf

echo "----------------------------------------"
echo "✅ 配置完成！"
echo "用户 '$USERNAME' 现在可以使用 'doas <命令>' 来执行管理员操作了。"
