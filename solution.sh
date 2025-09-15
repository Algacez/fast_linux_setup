#!/usr/bin/env bash
# 基于Ubuntu

SSHD_CONFIG="/etc/ssh/sshd_config"

set -e

cat <<EOF >/etc/apt/sources.list
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $(lsb_release -cs) main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $(lsb_release -cs)-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $(lsb_release -cs)-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $(lsb_release -cs)-security main restricted universe multiverse
EOF

apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y

apt-get install -y git docker.io python3 python3-pip curl openssh-server language-pack-zh-hans

sed -i '/^#\?PasswordAuthentication/d' $SSHD_CONFIG
echo "PasswordAuthentication no" >> $SSHD_CONFIG

sed -i '/^#\?PubkeyAuthentication/d' $SSHD_CONFIG
echo "PubkeyAuthentication yes" >> $SSHD_CONFIG

sed -i '/^#\?ClientAliveInterval/d' $SSHD_CONFIG
echo "ClientAliveInterval 600" >> $SSHD_CONFIG

sed -i '/^#\?ClientAliveCountMax/d' $SSHD_CONFIG
echo "ClientAliveCountMax 3" >> $SSHD_CONFIG

systemctl restart ssh

locale-gen zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8
export LANG=zh_CN.UTF-8