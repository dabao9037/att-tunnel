#!/usr/bin/env bash
# att-tunnel — AT&T 线路丢包根治：Xray VLESS Reverse 反向隧道一键部署
# 不绑域名，B 端直连 A 的公网 IP；B 换 IP 自动重连。
set -euo pipefail

VERSION="1.0.0"
XRAY_BIN="/usr/local/bin/xray"
CFG_DIR="/usr/local/etc/xray"
CFG="$CFG_DIR/config.json"
STATE="/etc/att-tunnel"
TUNNEL_DOMAIN="tunnel.internal"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}==>${RST} $*"; }
ok(){   echo "${GRN}[OK]${RST} $*"; }
warn(){ echo "${YEL}[!]${RST} $*"; }
die(){  echo "${RED}[X]${RST} $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行"; }

# ---------- 依赖 ----------
install_deps(){
  local miss=()
  for c in curl unzip openssl; do command -v "$c" >/dev/null || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  info "安装依赖: ${miss[*]}"
  if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y -qq "${miss[@]}"
  elif command -v dnf >/dev/null; then dnf install -y -q "${miss[@]}"
  elif command -v yum >/dev/null; then yum install -y -q "${miss[@]}"
  else die "无法自动安装依赖，请手动安装: ${miss[*]}"; fi
}

install_xray(){
  if [ -x "$XRAY_BIN" ]; then
    ok "Xray 已安装: $("$XRAY_BIN" version | head -1)"
    return 0
  fi
  info "安装 Xray-core ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
    || die "Xray 安装失败"
  [ -x "$XRAY_BIN" ] || die "Xray 安装后未找到 $XRAY_BIN"
  ok "Xray 安装完成: $("$XRAY_BIN" version | head -1)"
}

# ---------- 回落域名：实测可用才用（文档坑：microsoft 在新版会握手失败） ----------
CANDIDATES=(www.apple.com www.cloudflare.com www.icloud.com dl.google.com www.bing.com)
pick_sni(){
  local d
  for d in "${CANDIDATES[@]}"; do
    if timeout 8 openssl s_client -connect "$d:443" -tls1_3 -servername "$d" </dev/null 2>/dev/null \
       | grep -q 'TLSv1.3'; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# ---------- 工具 ----------
free_port(){
  local p
  while :; do
    p=$(( RANDOM % 40000 + 20000 ))
    ss -ltn 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
  done
}

pubip(){ curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null; }

# 原子写入 + 配置校验，失败自动还原
apply_cfg(){
  local new="$1"
  mkdir -p "$CFG_DIR"
  if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak-$(date +%Y%m%d%H%M%S)"
  fi
  "$XRAY_BIN" -test -config "$new" >/dev/null 2>&1 || {
    echo "--- 配置校验输出 ---"; "$XRAY_BIN" -test -config "$new" 2>&1 | tail -5
    die "配置校验未通过，已保留原配置"
  }
  mv "$new" "$CFG"
  chmod 644 "$CFG"
  chown root:root "$CFG"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || {
    local bak; bak=$(ls -t "$CFG".bak-* 2>/dev/null | head -1)
    [ -n "$bak" ] && { cp "$bak" "$CFG"; systemctl restart xray; }
    die "Xray 启动失败，已回滚。journalctl -u xray -n 30 查看原因"
  }
  ok "配置已生效，Xray 运行中"
}

harden_service(){
  mkdir -p /etc/systemd/system/xray.service.d
  printf '[Service]\nRestart=always\nRestartSec=5\n' > /etc/systemd/system/xray.service.d/restart.conf
  systemctl daemon-reload
}

# A 侧必需：B 换 IP 后会留下一条僵死隧道，portal 仍会往里派流量，
# 导致部分请求挂死。内核默认 tcp_retries2=15（约 15 分钟）太长，
# 调到 5（约 20 秒）才能快速回收。实测：调之前 6/8，调之后 10/10。
tune_tcp(){
  local f=/etc/sysctl.d/99-att-tunnel.conf
  cat > "$f" <<'EOF'
# att-tunnel: 快速回收死掉的反向隧道连接（B 换 IP / 断网场景）
net.ipv4.tcp_retries2 = 5
EOF
  sysctl -p "$f" >/dev/null 2>&1 && ok "已调优 tcp_retries2=5（僵死隧道 ~20s 回收）" \
    || warn "sysctl 应用失败，僵死连接回收会变慢"
}

open_fw(){
  local p="$1"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$p/tcp" >/dev/null 2>&1 && ok "ufw 已放行 $p/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $p/tcp"
  else
    warn "未检测到活动防火墙，跳过（云厂商安全组仍需手动放行 $p/tcp）"
  fi
}

# ================= 服务器 A：用户入口 + portal =================
deploy_a(){
  need_root; install_deps; install_xray

  local aip; aip=$(pubip); [ -n "$aip" ] || die "无法获取本机公网 IP"
  info "本机公网 IP: $aip（B 端将直连此 IP，A 的 IP 不要变）"

  if ss -ltn 2>/dev/null | grep -q ':443 '; then
    die "443 已被占用，请先处理：ss -ltnp | grep :443"
  fi

  info "挑选可用 REALITY 回落域名 ..."
  local sni; sni=$(pick_sni) || die "候选回落域名均不可用，请检查网络"
  ok "回落域名: $sni"

  local rport; rport=$(free_port)
  local uuid buuid sid path priv pub dec enc
  uuid=$("$XRAY_BIN" uuid)
  buuid=$("$XRAY_BIN" uuid)
  sid=$(openssl rand -hex 8)
  path="/$(openssl rand -hex 12)"
  local kp; kp=$("$XRAY_BIN" x25519)
  priv=$(echo "$kp" | awk '/PrivateKey/{print $2}')
  pub=$(echo "$kp"  | awk '/Password/{print $3}')
  local ve; ve=$("$XRAY_BIN" vlessenc 2>/dev/null)
  dec=$(echo "$ve" | grep -o '"decryption": "[^"]*"' | head -1 | cut -d'"' -f4)
  enc=$(echo "$ve" | grep -o '"encryption": "[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$dec" ] && [ -n "$enc" ] || die "VLESS Encryption 生成失败（Xray 版本过旧？）"

  local tmp; tmp=$(mktemp --suffix=.json)
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": { "portals": [ { "tag": "portal", "domain": "$TUNNEL_DOMAIN" } ] },
  "inbounds": [
    {
      "tag": "user-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "email": "node1" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": { "path": "$path", "mode": "auto" },
        "realitySettings": {
          "target": "$sni:443",
          "serverNames": [ "$sni" ],
          "privateKey": "$priv",
          "shortIds": [ "$sid" ]
        }
      }
    },
    {
      "tag": "reverse-in",
      "listen": "0.0.0.0",
      "port": $rport,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$buuid" } ],
        "decryption": "$dec"
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "reverse-in" ], "domain": [ "full:$TUNNEL_DOMAIN" ], "outboundTag": "portal" },
      { "type": "field", "user": [ "node1" ], "outboundTag": "portal" }
    ]
  }
}
EOF

  apply_cfg "$tmp"
  harden_service
  tune_tcp
  open_fw 443
  open_fw "$rport"

  mkdir -p "$STATE"
  cat > "$STATE/a.env" <<EOF
ROLE=A
A_IP=$aip
REVERSE_PORT=$rport
SNI=$sni
SHORT_ID=$sid
XPATH=$path
REALITY_PUB=$pub
BRIDGE_UUID=$buuid
VLESS_ENC=$enc
EOF
  chmod 600 "$STATE/a.env"

  local token
  token=$(printf '%s|%s|%s|%s' "$aip" "$rport" "$buuid" "$enc" | base64 -w0)

  echo
  echo "${BLD}=========== 服务器 A 部署完成 ===========${RST}"
  echo
  echo "${BLD}下一步：到服务器 B（AT&T 出口机）上执行：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL $RAW_URL) --bridge $token${RST}"
  echo
  echo "${YEL}这串 token 含隧道密钥，只在你自己两台机器间使用，不要外发。${RST}"
  echo
  show_links
}

# ================= 服务器 B：反向出口 =================
deploy_b(){
  need_root
  local token="${1:-}"
  [ -n "$token" ] || die "缺少 token，请用 A 端输出的完整命令"

  local dec aip rport buuid enc
  dec=$(echo "$token" | base64 -d 2>/dev/null) || die "token 解析失败"
  IFS='|' read -r aip rport buuid enc <<<"$dec"
  [ -n "$aip" ] && [ -n "$rport" ] && [ -n "$buuid" ] && [ -n "$enc" ] || die "token 内容不完整"

  install_deps; install_xray
  info "将主动拨向 A: $aip:$rport"

  if ! timeout 8 bash -c "</dev/tcp/$aip/$rport" 2>/dev/null; then
    warn "暂时连不上 $aip:$rport —— 检查 A 的防火墙/安全组是否放行了该端口"
    warn "仍会继续部署；隧道会在通了之后自动建立"
  else
    ok "A 的反代端口可达"
  fi

  local tmp; tmp=$(mktemp --suffix=.json)
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": { "bridges": [ { "tag": "bridge", "domain": "$TUNNEL_DOMAIN" } ] },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "vnext": [ {
          "address": "$aip",
          "port": $rport,
          "users": [ { "id": "$buuid", "encryption": "$enc" } ]
        } ]
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    },
    { "tag": "freedom", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "bridge" ], "domain": [ "full:$TUNNEL_DOMAIN" ], "outboundTag": "tunnel" },
      { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "freedom" }
    ]
  }
}
EOF

  apply_cfg "$tmp"
  harden_service
  tune_tcp

  mkdir -p "$STATE"
  printf 'ROLE=B\nA_IP=%s\nREVERSE_PORT=%s\n' "$aip" "$rport" > "$STATE/b.env"
  chmod 600 "$STATE/b.env"

  echo
  info "等待反向隧道建立 ..."
  local i estab=0
  for i in $(seq 1 15); do
    if ss -tn state established 2>/dev/null | grep -q "$aip:$rport"; then estab=1; break; fi
    sleep 2
  done

  echo
  echo "${BLD}=========== 服务器 B 部署完成 ===========${RST}"
  if [ "$estab" = 1 ]; then
    ok "反向隧道已建立（B → A ESTAB）"
  else
    warn "暂未看到 ESTAB。排查：A 上是否放行 $rport/tcp（含云安全组）"
    warn "手动查看：ss -tnp | grep $rport   /   journalctl -u xray -n 30"
  fi
  echo
  ok "B 端无任何入站监听，公网扫不到"
  ok "B 换 IP 无需任何操作，Xray 会自动重拨"
  echo
  warn "如需把 SSH 迁到高位端口（降低暴露面），单独跑：菜单 5"
}

# ================= 节点管理 =================
show_links(){
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  echo "${BLD}--- 客户端分享链接 ---${RST}"
  local epath; epath=$(printf '%s' "$XPATH" | sed 's|/|%2F|g')
  local n uuid
  while read -r n uuid; do
    [ -z "$n" ] && continue
    echo
    echo "${CYN}[$n]${RST}"
    echo "vless://$uuid@$A_IP:443?encryption=none&security=reality&type=xhttp&path=$epath&mode=auto&sni=$SNI&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID#$n"
  done < <("$XRAY_BIN" -test -config "$CFG" >/dev/null 2>&1 && python3 - <<'PY'
import json,sys
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d['inbounds']:
    if ib.get('tag')=='user-in':
        for c in ib['settings']['clients']:
            print(c.get('email','node'), c['id'])
PY
)
  echo
}

add_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端加节点"
  local name="${1:-}"
  [ -n "$name" ] || { read -rp "节点名称（如 node2）: " name; }
  [ -n "$name" ] || die "名称不能为空"
  local uuid; uuid=$("$XRAY_BIN" uuid)
  local tmp; tmp=$(mktemp --suffix=.json)
  NEW_NAME="$name" NEW_UUID="$uuid" python3 - > "$tmp" <<'PY'
import json,os
d=json.load(open('/usr/local/etc/xray/config.json'))
name=os.environ['NEW_NAME']; uuid=os.environ['NEW_UUID']
for ib in d['inbounds']:
    if ib.get('tag')=='user-in':
        cs=ib['settings']['clients']
        if any(c.get('email')==name for c in cs):
            raise SystemExit('DUP')
        cs.append({'id':uuid,'email':name})
for r in d['routing']['rules']:
    if 'user' in r and name not in r['user']:
        r['user'].append(name)
print(json.dumps(d,indent=1))
PY
  [ -s "$tmp" ] || die "节点名已存在或配置解析失败"
  apply_cfg "$tmp"
  ok "节点 $name 已添加"
  show_links
}

# ================= 自检 =================
selfcheck(){
  echo "${BLD}--- 运行自检 ---${RST}"
  if systemctl is-active --quiet xray; then ok "Xray active"; else echo "${RED}[X]${RST} Xray 未运行"; fi

  if [ -f "$STATE/a.env" ]; then
    source "$STATE/a.env"
    echo "角色: ${BLD}A（入口端）${RST}   本机 IP: $A_IP   反代端口: $REVERSE_PORT"
    ss -ltn 2>/dev/null | grep -q ':443 ' && ok "443 监听中" || echo "${RED}[X]${RST} 443 未监听"
    ss -ltn 2>/dev/null | grep -q ":$REVERSE_PORT " && ok "反代口 $REVERSE_PORT 监听中" || echo "${RED}[X]${RST} 反代口未监听"
    if ss -tn state established 2>/dev/null | grep -q ":$REVERSE_PORT"; then
      ok "B 的反向隧道已连上"
      ss -tn state established 2>/dev/null | grep ":$REVERSE_PORT" | head -3 | sed 's/^/    /'
    else
      warn "没有来自 B 的 ESTAB —— B 端未部署或端口被封"
    fi
    grep -q '"outboundTag": "portal"' "$CFG" && ok "portal 路由已配置" || warn "portal 路由缺失"
    local ntun; ntun=$(ss -tn state established 2>/dev/null | grep -c ":$REVERSE_PORT")
    if [ "$ntun" -gt 1 ]; then
      warn "检测到 $ntun 条隧道连接 —— 可能有僵死连接（B 刚换过 IP）"
      warn "部分请求会挂死，等 ~20s 内核回收；若长期如此查：sysctl net.ipv4.tcp_retries2（应为 5）"
    fi
    local r2; r2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)
    [ "$r2" = 5 ] && ok "tcp_retries2=5（僵死隧道快速回收）" || warn "tcp_retries2=$r2，建议为 5"
    echo; info "客户端连上后，请确认查到的出口 IP 等于 ${BLD}B 的实时公网 IP${RST}"
    info "如果显示的是 A 的 IP（$A_IP），说明路由没把用户流量送进 portal"
  elif [ -f "$STATE/b.env" ]; then
    source "$STATE/b.env"
    echo "角色: ${BLD}B（出口端）${RST}   拨向: $A_IP:$REVERSE_PORT"
    if ss -tn state established 2>/dev/null | grep -q "$A_IP:$REVERSE_PORT"; then
      ok "隧道 ESTAB 正常"
    else
      echo "${RED}[X]${RST} 隧道未建立，检查 A 侧防火墙/安全组 $REVERSE_PORT/tcp"
    fi
    local listen; listen=$(ss -ltn 2>/dev/null | grep -vE '127.0.0.1|::1|State' | wc -l)
    ok "对外监听端口数（含 SSH）: $listen"
    grep -q '"inbounds": \[\]' "$CFG" && ok "B 无任何用户入站（零暴露）" || warn "B 端出现了 inbound，与设计不符"
    echo -n "本机实时公网 IP: "; pubip; echo
  else
    warn "未找到部署状态，尚未部署"
  fi
  echo
}

# ================= SSH 端口迁移（危险操作，单独菜单） =================
ssh_migrate(){
  need_root
  echo "${YEL}${BLD}⚠ 这个操作会修改 SSH 端口，操作不当会把你自己锁在外面。${RST}"
  echo "流程：新旧端口先并存 → 你新开一个会话实测新端口 → 确认后手动收揉 22"
  echo "${BLD}全程不要关掉你当前这个 SSH 会话。${RST}"
  echo
  read -rp "新端口（20000-60000，回车随机）: " np
  [ -n "$np" ] || np=$(free_port)
  case "$np" in (*[!0-9]*) die "端口必须是数字";; esac
  [ "$np" -ge 1024 ] && [ "$np" -le 65535 ] || die "端口越界"
  read -rp "确认把 SSH 加监听到 $np？输 yes 继续: " c
  [ "$c" = yes ] || { warn "已取消"; return; }

  open_fw "$np"
  mkdir -p /etc/ssh/sshd_config.d
  printf 'Port 22\nPort %s\n' "$np" > /etc/ssh/sshd_config.d/00-att-tunnel-port.conf
  sshd -t || { rm -f /etc/ssh/sshd_config.d/00-att-tunnel-port.conf; die "sshd 配置校验失败，已回滚"; }
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  sleep 1
  ss -ltn | grep -q ":$np " && ok "新端口 $np 已监听（22 仍在）" || die "新端口未监听"
  echo
  echo "${BLD}现在另开一个终端实测：${RST} ssh -p $np root@\$(本机IP)"
  echo "确认能登录后，再跑下面两行收揉 22："
  echo "${CYN}  printf 'Port $np\\n' > /etc/ssh/sshd_config.d/00-att-tunnel-port.conf${RST}"
  echo "${CYN}  sshd -t && systemctl restart ssh${RST}"
  echo "然后在云安全组回收 22/tcp，并：ufw delete allow 22/tcp"
  warn "我不会自动删 22 —— 必须你亲自验证新端口可登录之后再做。"
}

# ================= 卸载 =================
uninstall(){
  need_root
  read -rp "确认卸载？会删除 Xray 配置与本工具状态（输 yes）: " c
  [ "$c" = yes ] || { warn "已取消"; return; }
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service.d/restart.conf
  systemctl daemon-reload 2>/dev/null || true
  local bdir="/root/att-tunnel-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$bdir"
  [ -f "$CFG" ] && cp "$CFG" "$bdir/" 2>/dev/null || true
  [ -d "$STATE" ] && cp -r "$STATE" "$bdir/" 2>/dev/null || true
  rm -rf "$STATE"
  ok "已停止并清理。备份在：$bdir"
  warn "Xray 本体未删除。彻底移除：bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ remove"
  warn "SSH 端口改动不会自动还原，需手动处理 /etc/ssh/sshd_config.d/00-att-tunnel-port.conf"
}

# ================= 菜单 =================
menu(){
  while :; do
    echo
    echo "${BLD}  att-tunnel v$VERSION${RST}  — AT&T 丢包反向隧道"
    echo "  ──────────────────────────────"
    echo "  1) 部署服务器 A（境外入口机）"
    echo "  2) 部署服务器 B（AT&T 出口机，需 A 的 token）"
    echo "  3) 看节点分享链接"
    echo "  4) 加一个节点"
    echo "  5) 运行自检"
    echo "  6) SSH 搬到高位端口（可选，小心）"
    echo "  7) 卸载"
    echo "  0) 退出"
    echo
    read -rp "选择: " ch
    case "$ch" in
      1) deploy_a ;;
      2) read -rp "粘贴 A 端给的 token: " t; deploy_b "$t" ;;
      3) show_links ;;
      4) add_node ;;
      5) selfcheck ;;
      6) ssh_migrate ;;
      7) uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

RAW_URL="https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh"

case "${1:-}" in
  --bridge)   need_root; deploy_b "${2:-}" ;;
  --server-a) deploy_a ;;
  --check)    selfcheck ;;
  --links)    show_links ;;
  --add)      add_node "${2:-}" ;;
  --version)  echo "att-tunnel v$VERSION" ;;
  "")         menu ;;
  *)          die "未知参数: $1（可用：--server-a | --bridge TOKEN | --check | --links | --add NAME）" ;;
esac
