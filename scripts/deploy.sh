#!/bin/bash
# 在已安装 Docker Compose 的机器上部署达芬奇项目库。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  echo "用法: $0 simple|macvlan|shim"
  echo "  simple  宿主机 5432 空闲，一条命令即可"
  echo "  macvlan 系统已占用 5432（如绿联 UGOS），给数据库独立局域网 IP"
  echo "  shim    在 macvlan 之上再加 Tailscale / 第二地址转发"
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已创建 .env，请先编辑里面的密码和网段，再重新运行。"
  exit 1
fi

# 避免把示例密码直接启动
if grep -q "change-me-to-a-strong-password" .env; then
  echo "请先在 .env 里把 POSTGRES_PASSWORD 改成你自己的密码。"
  exit 1
fi

case "$MODE" in
  simple)
    docker compose --env-file .env -f compose.simple.yml up -d
    echo "已启动。达芬奇里「位置」填这台机器的局域网 IP，端口保持 5432。"
    ;;
  macvlan)
    docker compose --env-file .env -f compose.macvlan.yml up -d
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    echo "已启动。局域网里达芬奇「位置」填 ${DB_IP}，端口保持 5432。"
    echo "这个地址经 Tailscale 可能进不去，远程访问请再用: $0 shim"
    ;;
  shim)
    docker compose --env-file .env -f compose.macvlan.yml up -d
    docker compose --env-file .env -f compose.shim.yml up -d --build
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    echo "已启动数据库和转发。"
    echo "家里局域网和 Tailscale 子网路由：达芬奇「位置」填 ${SHIM_IP}"
    if [[ -n "${TAILSCALE_IP:-}" ]]; then
      echo "也可以填 Tailscale 地址 ${TAILSCALE_IP}"
    fi
    echo "端口保持 5432。原来的 ${DB_IP} 一般只在同一局域网直连时可用。"
    ;;
  *)
    echo "未知模式: $MODE" >&2
    exit 1
    ;;
esac
