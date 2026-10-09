#!/bin/bash
# Phase 15 - first boot of the EC2 host (Amazon Linux 2023). Only what Ansible needs to take over:
# Python is already there; add swap (small instances), basic tools, and a marker file. Ansible does the rest.
set -euo pipefail
exec > >(tee -a /var/log/ems-first-boot.log) 2>&1
echo "ems first boot: $(date -Is)"

dnf -y -q install jq tar gzip cronie

if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

hostnamectl set-hostname ems-host
mkdir -p /etc/ems
date -Is > /etc/ems/first-boot-done
echo "ems first boot finished"
