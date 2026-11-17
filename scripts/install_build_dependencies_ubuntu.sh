#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root: sudo $0" >&2
  exit 1
fi

apt-get update
apt-get install -y \
  build-essential \
  cmake \
  git-lfs \
  libaio-dev \
  "linux-headers-$(uname -r)" \
  python3-jinja2 \
  python3-pip \
  python3-venv

git lfs install --system
