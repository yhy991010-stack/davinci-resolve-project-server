#!/bin/bash
# 在 SHIM_IP（以及可选的 TAILSCALE_IP）上监听 5432，转发到 DB_IP:5432。
# 可选：给绿联这类会把宿主机 5432 做 DNAT 的系统加 NAT 例外。
set -euo pipefail

: "${DB_IP:?请设置 DB_IP}"
: "${SHIM_IP:?请设置 SHIM_IP}"
LAN_PARENT="${LAN_PARENT:-eth0}"
LAN_SUBNET="${LAN_SUBNET:-}"
TAILSCALE_IP="${TAILSCALE_IP:-}"
APPLY_NAT_EXEMPT="${APPLY_NAT_EXEMPT:-1}"

PREFIX=32
if [[ -n "$LAN_SUBNET" && "$LAN_SUBNET" == */* ]]; then
  PREFIX="${LAN_SUBNET##*/}"
fi

ensure_ip() {
  local ip="$1"
  if ip -4 -o addr show | awk '{print $4}' | grep -q "^${ip}/"; then
    echo "地址已存在: $ip"
    return
  fi
  if ! ip link show "$LAN_PARENT" >/dev/null 2>&1; then
    echo "找不到网卡 $LAN_PARENT，请在 .env 里设置正确的 LAN_PARENT" >&2
    ip -br addr || true
    exit 1
  fi
  echo "在 $LAN_PARENT 上添加 $ip/$PREFIX"
  ip addr add "$ip/$PREFIX" dev "$LAN_PARENT"
}

ensure_ip "$SHIM_IP"

if [[ -n "$TAILSCALE_IP" ]]; then
  if ! ip -4 -o addr show | awk '{print $4}' | grep -q "^${TAILSCALE_IP}/"; then
    echo "未在本机找到 TAILSCALE_IP=$TAILSCALE_IP，将只监听已有地址。请确认 Tailscale 已在 NAS 上运行。"
  fi
fi

apply_nat_exempt() {
  local dest="$1"
  for IPT in iptables iptables-nft iptables-legacy; do
    command -v "$IPT" >/dev/null 2>&1 || continue
    $IPT -t nat -C PREROUTING -d "$dest/32" -p tcp --dport 5432 -j RETURN 2>/dev/null \
      || $IPT -t nat -I PREROUTING -d "$dest/32" -p tcp --dport 5432 -j RETURN || true
    if $IPT -t nat -nL DOCKER >/dev/null 2>&1; then
      $IPT -t nat -C DOCKER -d "$dest/32" -p tcp --dport 5432 -j RETURN 2>/dev/null \
        || $IPT -t nat -I DOCKER -d "$dest/32" -p tcp --dport 5432 -j RETURN || true
    fi
  done
  if command -v nft >/dev/null 2>&1; then
    nft list table ip nat >/dev/null 2>&1 || return 0
    for ch in PREROUTING prerouting DOCKER; do
      nft list chain ip nat "$ch" >/dev/null 2>&1 || continue
      nft add rule ip nat "$ch" ip daddr "$dest" tcp dport 5432 return 2>/dev/null || true
    done
  fi
}

if [[ "$APPLY_NAT_EXEMPT" == "1" ]]; then
  echo "添加 5432 NAT 例外，避免被系统自带数据库抢走"
  apply_nat_exempt "$SHIM_IP"
  if [[ -n "$TAILSCALE_IP" ]]; then
    apply_nat_exempt "$TAILSCALE_IP"
  fi
  for IPT in iptables iptables-nft iptables-legacy; do
    command -v "$IPT" >/dev/null 2>&1 || continue
    $IPT -t nat -C PREROUTING -i tailscale0 -p tcp --dport 5432 -j RETURN 2>/dev/null \
      || $IPT -t nat -I PREROUTING -i tailscale0 -p tcp --dport 5432 -j RETURN || true
    if $IPT -t nat -nL DOCKER >/dev/null 2>&1; then
      $IPT -t nat -C DOCKER -i tailscale0 -p tcp --dport 5432 -j RETURN 2>/dev/null \
        || $IPT -t nat -I DOCKER -i tailscale0 -p tcp --dport 5432 -j RETURN || true
    fi
  done
fi

pids=()
start_socat() {
  local listen_ip="$1"
  if ! ip -4 -o addr show | awk '{print $4}' | grep -q "^${listen_ip}/"; then
    return
  fi
  echo "监听 ${listen_ip}:5432 -> ${DB_IP}:5432"
  socat TCP-LISTEN:5432,bind="$listen_ip",fork,reuseaddr TCP:"${DB_IP}":5432 &
  pids+=("$!")
}

start_socat "$SHIM_IP"
if [[ -n "$TAILSCALE_IP" ]]; then
  start_socat "$TAILSCALE_IP"
fi

if [[ ${#pids[@]} -eq 0 ]]; then
  echo "没有可用的监听地址" >&2
  exit 1
fi

term() {
  for p in "${pids[@]}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap term EXIT INT TERM

echo "davinci-host-shim 已启动"
wait -n "${pids[@]}"
