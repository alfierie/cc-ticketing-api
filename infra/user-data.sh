#!/bin/bash
# EC2 user data (runs once as root on first boot, Amazon Linux 2023):
# installs Docker Engine, the Docker Compose plugin and git, and adds 1 GB swap.
set -euxo pipefail
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user

mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# 1 GB swap so MySQL + the API are comfortable on a t3.micro (1 GB RAM)
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi
echo "bootstrap complete" > /var/tmp/bootstrap-done
