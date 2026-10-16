#!/usr/bin/env bash
# att-tunnel — AT&T 线路丢包根治：Xray VLESS Reverse 反向隧道一键部署
# 不绑域名，B 端直连 A 的公网 IP；B 换 IP 自动重连。
set -Eeuo pipefail
# head 提前关管道会让上游收到 SIGPIPE(141)，配合 pipefail+set -e 会静默退出。
# 下面统一用 sed -n / awk NR 代替 head；再加个 ERR 提示，万一意外退出至少知道是哪一行。
trap 'rc=$?; echo "[X] 脚本在第 $LINENO 行意外退出 (rc=$rc)" >&2' ERR

VERSION="2.1.0"
XRAY_BIN="/usr/local/bin/xray"
# 独立配置 + 独立 systemd 服务，不碰机器上已有的 xray / 3x-ui / NodeLite
CFG_DIR="/usr/local/etc/att-tunnel"
CFG="$CFG_DIR/config.json"
SVC="att-tunnel"
STATE="/etc/att-tunnel"
TUNNEL_DOMAIN="tunnel.internal"
REVERSE_STYLE="new"   # 由 install_xray 实测覆盖：new=VLESS Reverse Proxy / old=顶层 reverse
# 固定 Xray 版本：26.7 及以后的版本有 bug，钉在 2026 年 6 月最后一版。
# 需要时可用 ATT_XRAY_VER 覆盖（例：ATT_XRAY_VER=v26.6.22）。
XRAY_VER="${ATT_XRAY_VER:-v26.6.27}"
# 用户入口传输方式：raw（默认，兼容所有客户端）| xhttp（伪装更好，但要求客户端支持）
# 客户端若不支持/未正确配置 XHTTP，会报 unexpected response version ... actually 72
# （72 = 'H'，VLESS 层收到明文 HTTP）。所以默认用 raw。
ATT_TRANSPORT="${ATT_TRANSPORT:-raw}"

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

# 探测该 Xray 用哪一代 reverse 语法：
#   new = VLESS Reverse Proxy（user 内 "reverse":{"tag"}），26.4+ 起强制
#   old = 顶层 "reverse":{portals/bridges}
# 判别用 simplified outbound style：旧版会因 "vnext" is empty 直接失败。
detect_reverse_style(){
  local probe; probe=$(mktemp --suffix=.json)
  cat > "$probe" <<'PROBE'
{ "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "tag": "t", "protocol": "vless",
      "settings": { "address": "127.0.0.1", "port": 12345,
        "id": "11111111-1111-1111-1111-111111111111", "encryption": "none",
        "reverse": { "tag": "bridge" } },
      "streamSettings": { "network": "raw" } },
    { "tag": "f", "protocol": "freedom" } ],
  "routing": { "rules": [ { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "f" } ] } }
PROBE
  if "$XRAY_BIN" -test -config "$probe" >/dev/null 2>&1; then
    REVERSE_STYLE=new
  else
    REVERSE_STYLE=old
  fi
  rm -f "$probe"
  ok "reverse 语法：$REVERSE_STYLE"
}

install_xray(){
  # 本工具专用副本固定用 $XRAY_VER，绝不复用机器上别的版本。
  # 原因：A/B 两端 Xray 版本不一致会导致握手失败，客户端报
  #   unknown version: 72  （72 = 'H'，即收到明文 HTTP 而非 VLESS）
  # 所以只认 /usr/local/bin/xray，且版本号必须等于 $XRAY_VER。
  local want="${XRAY_VER#v}"
  local cur=""
  if [ -x /usr/local/bin/xray ]; then
    cur=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')
  fi

  if [ -n "$cur" ] && [ "$cur" = "$want" ]; then
    XRAY_BIN="/usr/local/bin/xray"
    ok "专用 Xray 已是 $cur（$XRAY_BIN）"
    detect_reverse_style
    return 0
  fi

  if [ -n "$cur" ]; then
    warn "专用 Xray 版本是 $cur，需要 $want —— 卸载重装"
    systemctl stop "$SVC" 2>/dev/null || true
    rm -f /usr/local/bin/xray
  fi

  # 提示一下机器上别的 xray，但明确不碰它
  local other p
  for p in /opt/nodelite/bin/xray /usr/bin/xray /opt/xray/xray \
           /usr/local/x-ui/bin/xray-linux-amd64 /etc/x-ui/bin/xray-linux-amd64; do
    [ -x "$p" ] && { other="$p"; break; }
  done
  if [ -n "${other:-}" ]; then
    local ov; ov=$("$other" version 2>/dev/null | awk 'NR==1{print $2}')
    info "检测到其他 Xray：$other（$ov）—— 不使用、不修改它"
  fi

  info "安装专用 Xray-core $XRAY_VER 到 /usr/local/bin/xray ..."
  # 不用官方安装脚本：它会 stop/接管 xray.service，在已有面板的机器上会出问题，
  # 而且可能装比现有版本更旧的版。直接拉 latest 二进制。
  local arch tmpd
  case "$(uname -m)" in
    x86_64|amd64)  arch=64 ;;
    aarch64|arm64) arch=arm64-v8a ;;
    armv7l)        arch=arm32-v7a ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  tmpd=$(mktemp -d)
  local url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/Xray-linux-$arch.zip"
  if ! curl -fsSL --max-time 180 -o "$tmpd/x.zip" "$url"; then
    rm -rf "$tmpd"
    echo "下载失败：$url"
    echo "常见原因：GitHub 不可达（curl -I https://github.com）/ 硬盘满（df -h）"
    die "Xray 下载失败"
  fi
  if ! unzip -oq "$tmpd/x.zip" -d "$tmpd"; then
    rm -rf "$tmpd"; die "解包失败（缺 unzip？）"
  fi
  [ -f "$tmpd/xray" ] || { rm -rf "$tmpd"; die "包里没找到 xray 二进制"; }
  install -m 755 "$tmpd/xray" /usr/local/bin/xray
  mkdir -p /usr/local/share/xray
  for f in geoip.dat geosite.dat; do
    [ -f "$tmpd/$f" ] && install -m 644 "$tmpd/$f" "/usr/local/share/xray/$f"
  done
  rm -rf "$tmpd"
  XRAY_BIN="/usr/local/bin/xray"
  [ -x "$XRAY_BIN" ] || die "安装后未找到 $XRAY_BIN"
  ok "Xray 已安装: $("$XRAY_BIN" version | sed -n 1p)"

  detect_reverse_style
}

# ---------- 回落域名：实测可用才用（文档坑：microsoft 在新版会握手失败） ----------
# 与 NodeLite 保持一致的预置列表（NodeLite 默认 www.atlasobscura.com）。
# 已逐个做过真实 REALITY 握手实测（Xray 26.3.27），
# NodeLite 预置中的 www.hkstp.org 实测不通，故不纳入。
# 伪装域名列表：域名 | 国家
CANDIDATES_WITH_COUNTRY=(
  "www.atlasobscura.com|美国"
  "www.backblaze.com|美国"
  "www.gog.com|波兰"
  "www.cern.ch|瑞士"
  "www.sciencemuseum.org.uk|英国"
  "www.visitsingapore.com|新加坡"
  "www.discoverhongkong.com|中国香港"
  "www.a-star.edu.sg|新加坡"
  "www.animatetimes.com|日本"
  "www.famitsu.com|日本"
  "www.jodrellbank.net|英国"
)

# 提取纯域名列表（向后兼容）
CANDIDATES=()
for entry in "${CANDIDATES_WITH_COUNTRY[@]}"; do
  CANDIDATES+=("${entry%%|*}")
done

# 单个域名 TLS 1.3 实测
sni_ok(){
  timeout 8 openssl s_client -connect "$1:443" -tls1_3 -servername "$1" </dev/null 2>/dev/null \
    | grep -q 'TLSv1.3'
}

# 交互式选择伪装域名。
# 结果写入全局变量 SNI_PICKED，不走 $(...) 捕获：
# 之前用 sni=$(pick_sni_interactive)，列表/提示一旦混进 stdout 就被吞进 sni，
# 表现为“先出提示、选完才出列表”，并把多行文本写进 config.json 导致 xray 报
# invalid character '\n' in string literal。
SNI_PICKED=""
pick_sni_interactive(){
  SNI_PICKED=""
  local i d country choice usable=()
  echo
  echo "${CYN}===== 伪装域名（逐个实测 TLS 1.3，约需几秒）=====${RST}"
  for i in "${!CANDIDATES_WITH_COUNTRY[@]}"; do
    d="${CANDIDATES_WITH_COUNTRY[$i]%%|*}"
    country="${CANDIDATES_WITH_COUNTRY[$i]##*|}"
    printf "  %2d. %-30s [%s] " $((i+1)) "$d" "$country"
    if sni_ok "$d"; then
      printf "%s\n" "${GRN}可用${RST}"
      usable+=($((i+1)))
    else
      printf "%s\n" "${RED}不可用${RST}"
    fi
  done
  echo "${CYN}==============================================${RST}"
  echo "${YEL}提示：选入口服务器(A)所在国家/地区的网站，伪装效果更好${RST}"
  [ ${#usable[@]} -gt 0 ] || return 1

  while true; do
    read -r -p "请选择伪装域名序号 [回车默认 ${usable[0]}]: " choice || return 1
    [ -z "$choice" ] && choice="${usable[0]}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ " ${usable[*]} " == *" $choice "* ]]; then
      SNI_PICKED="${CANDIDATES_WITH_COUNTRY[$((choice-1))]%%|*}"
      return 0
    fi
    warn "无效选择，请输入上面标“可用”的序号"
  done
}

pick_sni(){
  # 手动指定优先：ATT_SNI=www.example.com
  if [ -n "${ATT_SNI:-}" ]; then
    if sni_ok "$ATT_SNI"; then
      echo "$ATT_SNI"; return 0
    fi
    warn "指定的 $ATT_SNI 不支持 TLS 1.3，改用预置列表" >&2
  fi
  local d
  for d in "${CANDIDATES[@]}"; do
    if sni_ok "$d"; then
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

pubip(){
  # 允许手动指定，避免探测失败卡住
  if [ -n "${ATT_IP:-}" ]; then printf '%s' "$ATT_IP"; return 0; fi
  curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 10 https://icanhazip.com 2>/dev/null
}

# 建立独立 systemd 服务（不动官方 xray.service）
write_unit(){
  cat > "/etc/systemd/system/$SVC.service" <<EOF
[Unit]
Description=att-tunnel (Xray VLESS Reverse)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $CFG
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

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
  write_unit
  systemctl enable "$SVC" >/dev/null 2>&1 || true
  systemctl restart "$SVC"
  sleep 2
  systemctl is-active --quiet "$SVC" || {
    local bak; bak=$(ls -t "$CFG".bak-* 2>/dev/null | sed -n 1p)
    [ -n "$bak" ] && { cp "$bak" "$CFG"; systemctl restart "$SVC"; }
    echo "--- 服务日志 ---"; journalctl -u "$SVC" -n 15 --no-pager 2>&1 | tail -10
    die "启动失败，已回滚"
  }
  ok "配置已生效，$SVC 运行中（独立服务，未动你现有 xray）"
}

harden_service(){
  : # 自我12服务 unit 里已包含 Restart=always / RestartSec=5
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
  local p="$1" done_any=0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$p/tcp" >/dev/null 2>&1 && { ok "ufw 已放行 $p/tcp"; done_any=1; }
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && { ok "firewalld 已放行 $p/tcp"; done_any=1; }
  fi
  # 很多 VPS 没有 ufw/firewalld，但 iptables INPUT 默认 DROP 或有拦截规则。
  # 上一版只看 ufw/firewalld，所以反代端口实际被 iptables 拦掉。
  if command -v iptables >/dev/null 2>&1; then
    local pol; pol=$(iptables -L INPUT -n 2>/dev/null | sed -n 1p)
    if echo "$pol" | grep -q 'policy DROP' || iptables -L INPUT -n 2>/dev/null | grep -qE '^(DROP|REJECT)'; then
      if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
          && { ok "iptables 已放行 $p/tcp"; done_any=1; }
      else
        ok "iptables 已有 $p/tcp 放行规则"; done_any=1
      fi
      # 尽力持久化
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
      elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      fi
    fi
  fi
  [ "$done_any" = 1 ] || warn "本机未发现防火墙拦截"
  warn "❗ 云厂商安全组需你自己在控制台放行 $p/tcp（脚本改不了）"
}

# ================= 服务器 A：用户入口 + portal =================
deploy_a(){
  need_root; install_deps; install_xray


  local uport="${ATT_PORT:-443}"
  case "$uport" in (*[!0-9]*) die "ATT_PORT 必须是数字";; esac

  local aip; aip=$(pubip) || true
  if [ -z "${aip:-}" ]; then
    echo
    echo "${RED}无法获取本机公网 IP${RST}（请求 api.ipify.org / ifconfig.me 超时）"
    echo "常见原因："
    echo "  • 本机防火墙 INPUT/OUTPUT 默认 DROP，连 DNS 都出不去"
    echo "    检查：${CYN}iptables -L INPUT -n | head -3${RST}"
    echo "  • DNS 不可用：${CYN}cat /etc/resolv.conf; ping -c1 1.1.1.1${RST}"
    echo
    echo "也可以直接指定：${CYN}ATT_IP=你的公网IP bash install.sh --server-a${RST}"
    die "已停止"
  fi
  info "本机公网 IP: $aip（B 端将直连此 IP，A 的 IP 不要变）"
  [ "$uport" = 443 ] || warn "使用非默认入口端口: $uport"

  if ss -ltn 2>/dev/null | grep -q ":$uport "; then
    echo
    warn "$uport 已被占用："
    ss -ltnp 2>/dev/null | grep ":$uport " | sed 's/^/    /'

    if [ -n "${ATT_PORT:-}" ]; then
      # 用户显式指定了端口，不自作主张换
      echo
      echo "你显式指定了 ATT_PORT=$uport，但它被占用了。"
      echo "换个端口重跑，或去掉 ATT_PORT 让脚本自动选。"
      die "已停止，没有动你现有服务"
    fi

    # 降级顺序：443 -> 8443 -> 随机高位端口
    local cand=""
    if ! ss -ltn 2>/dev/null | grep -q ':8443 '; then
      cand=8443
      info "8443 空闲，改用 8443"
    else
      warn "8443 也被占用，改用随机高位端口"
      cand=$(free_port)
    fi

    uport="$cand"
    echo
    ok "自动改用端口 $uport，继续部署（没有动你占用 443 的服务）"
    warn "非 443 的 REALITY 伪装效果会打折；如能腾出 443，停掉占用服务后重跑更好"
    warn "云厂商安全组记得放行 $uport/tcp"
    echo
  fi

  local sni
  if [ -n "${ATT_SNI:-}" ]; then
    info "使用指定的 REALITY 回落域名: $ATT_SNI"
    sni=$(pick_sni) || die "指定的回落域名不可用"
  else
    pick_sni_interactive || die "候选回落域名均不可用，请检查网络"
    sni="$SNI_PICKED"
  fi
  # 写进 config.json 前兜底：只允许纯域名，杜绝换行/空格把 JSON 弄坏
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "回落域名异常: '$sni'"
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
  dec=$(echo "$ve" | grep -o '"decryption": "[^"]*"' | sed -n 1p | cut -d'"' -f4)
  enc=$(echo "$ve" | grep -o '"encryption": "[^"]*"' | sed -n 1p | cut -d'"' -f4)
  [ -n "$dec" ] && [ -n "$enc" ] || die "VLESS Encryption 生成失败（Xray 版本过旧？）"

  # 新/旧 reverse 语法差异：
  #   new: portal 声明在 reverse-in 的 user 上，无顶层 reverse / 无 tunnel.internal 路由
  #   old: 顶层 reverse.portals + 虚拟域名路由
  # XTLS Vision：消除 TLS-in-TLS 指纹，抗封关键。仅 raw 可用，xhttp 不支持 flow。
  # 坑：flow 必须两端完全一致。服务端有 Vision 而客户端没填 flow 时，
  # Xray 直接拒绝（日志：rejected since the client flow is empty），
  # 客户端表现为 EOF / 502。很多客户端导入链接时会丢掉 flow 参数。
  # 客户端导入分享链接后必须保留 flow 字段。
  local a_clients a_users
  if [ "$ATT_TRANSPORT" = xhttp ]; then
    a_clients="{ \"id\": \"$uuid\", \"email\": \"node1\" }"
  else
    a_clients="{ \"id\": \"$uuid\", \"email\": \"node1\", \"flow\": \"xtls-rprx-vision\" }"
  fi
  a_users='"node1"'

  local a_net
  if [ "$ATT_TRANSPORT" = xhttp ]; then
    a_net="\"network\": \"xhttp\",
        \"xhttpSettings\": { \"path\": \"$path\", \"mode\": \"auto\" },"
  else
    a_net="\"network\": \"raw\","
  fi

  local a_reverse_blk a_bclient a_extra_rule
  # 1:1：首个节点 node1 的专属 portal 标签叫 portal-node1；
  # 后续每加一个节点就多一个 bridge client + 一个 portal-<name>。
  if [ "$REVERSE_STYLE" = new ]; then
    a_reverse_blk=""
    a_bclient="{ \"id\": \"$buuid\", \"reverse\": { \"tag\": \"portal-node1\" } }"
    a_extra_rule=""
  else
    a_reverse_blk="  \"reverse\": { \"portals\": [ { \"tag\": \"portal-node1\", \"domain\": \"$TUNNEL_DOMAIN\" } ] },"
    a_bclient="{ \"id\": \"$buuid\" }"
    a_extra_rule="      { \"type\": \"field\", \"inboundTag\": [ \"reverse-in\" ], \"domain\": [ \"full:$TUNNEL_DOMAIN\" ], \"outboundTag\": \"portal-node1\" },"
  fi

  local tmp; tmp=$(mktemp --suffix=.json)
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
$a_reverse_blk
  "inbounds": [
    {
      "tag": "user-in",
      "listen": "0.0.0.0",
      "port": $uport,
      "protocol": "vless",
      "settings": {
        "clients": [ $a_clients ],
        "decryption": "none"
      },
      "streamSettings": {
        $a_net
        "security": "reality",
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
        "clients": [ $a_bclient ],
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
$a_extra_rule
      { "type": "field", "user": [ $a_users ], "outboundTag": "portal-node1" }
    ]
  }
}
EOF

  # 流量统计 + 出口探测（API / probe-in 只听 127.0.0.1，不对外）
  STATS_API_PORT=$(free_port)
  PROBE_PORT=$(free_port)
  while [ "$PROBE_PORT" = "$STATS_API_PORT" ]; do PROBE_PORT=$(free_port); done
  stats_sync "$tmp" 1 || { rm -f "$tmp"; die "统计配置生成失败"; }

  apply_cfg "$tmp"
  harden_service
  tune_tcp
  open_fw "$uport"
  open_fw "$rport"

  mkdir -p "$STATE"
  cat > "$STATE/a.env" <<EOF
ROLE=A
A_IP=$aip
USER_PORT=$uport
REVERSE_PORT=$rport
SNI=$sni
SHORT_ID=$sid
XPATH=$path
TRANSPORT=$ATT_TRANSPORT
REALITY_PUB=$pub
BRIDGE_UUID=$buuid
VLESS_ENC=$enc
REVERSE_STYLE=$REVERSE_STYLE
STATS_API_PORT=$STATS_API_PORT
PROBE_PORT=$PROBE_PORT
EOF
  chmod 600 "$STATE/a.env"

  local token
  token=$(printf '%s|%s|%s|%s|%s' "$aip" "$rport" "$buuid" "$enc" "$REVERSE_STYLE" | base64 -w0)

  echo
  echo "${BLD}=========== 服务器 A 部署完成 ===========${RST}"
  echo
  # 从外部视角验证反代端口真的通，否则 B 端会白跑一轮
  echo
  info "验证反代端口 $rport 是否从外网可达 ..."
  local probe_ok=0 body
  body=$(curl -fsS --max-time 20 "https://ports.yougetsignal.com/check-port.php" \
         --data "remoteAddress=$aip&portNumber=$rport" 2>/dev/null || true)
  if echo "$body" | grep -qi 'open'; then
    probe_ok=1
  fi
  if [ "$probe_ok" = 1 ]; then
    ok "外网可达 $aip:$rport"
  else
    echo
    echo "${YEL}${BLD}⚠ 外网似乎连不上 $aip:$rport${RST}"
    echo "这样 B 端隧道建不起来。本机防火墙已处理，请检查："
    echo "  • ${BLD}云厂商安全组${RST}是否放行 ${BLD}$rport/tcp${RST}（最常见原因）"
    echo "  • 上游服务商是否限制端口"
    echo "放行后隧道会自动建立，不用重跑本脚本。"
    echo "（探测服务可能不准，若你确定已放行可忽略）"
  fi

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

  local dec aip rport buuid enc tstyle
  dec=$(echo "$token" | base64 -d 2>/dev/null) || die "token 解析失败"
  IFS='|' read -r aip rport buuid enc tstyle <<<"$dec"
  [ -n "$aip" ] && [ -n "$rport" ] && [ -n "$buuid" ] && [ -n "$enc" ] || die "token 内容不完整"

  install_deps; install_xray

  # A/B 两端都强制同一个 $XRAY_VER，语法必然一致。若 token 带的 style 不一致，
  # 说明 A 端是用旧版本部署的，必须让 A 也重跑一次，否则握手会失败
  # （客户端报 unknown version: 72）。
  if [ -n "${tstyle:-}" ] && [ "$tstyle" != "$REVERSE_STYLE" ]; then
    warn "A 端 reverse 语法是 $tstyle，本机是 $REVERSE_STYLE —— 两端 Xray 版本不一致"
    die "请在 A 端用同一版脚本重跑菜单 1，拿到新 token 再回来"
  fi

  info "将主动拨向 A: $aip:$rport（reverse 语法 $REVERSE_STYLE）"

  if ! timeout 8 bash -c "</dev/tcp/$aip/$rport" 2>/dev/null; then
    warn "暂时连不上 $aip:$rport —— 检查 A 的防火墙/安全组是否放行了该端口"
    warn "仍会继续部署；隧道会在通了之后自动建立"
  else
    ok "A 的反代端口可达"
  fi

  # 新语法：bridge 声明在 outbound 的 reverse 字段（必须用 simplified style，不能用 vnext）
  # 关键：新版 freedom 对 vless-reverse 入站默认 block 全部（防滥用），
  # 必须显式 finalRules 放行，否则隧道通但流量全被 blackhole
  local tmp; tmp=$(mktemp --suffix=.json)
  if [ "$REVERSE_STYLE" = new ]; then
    cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "address": "$aip",
        "port": $rport,
        "id": "$buuid",
        "encryption": "$enc",
        "reverse": { "tag": "bridge" }
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    },
    {
      "tag": "freedom",
      "protocol": "freedom",
      "settings": {
        "finalRules": [
          { "action": "block", "ip": [ "geoip:private" ] },
          { "action": "allow" }
        ]
      },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } }
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "freedom" }
    ]
  }
}
EOF
  else
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
  fi

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
    echo "${YEL}${BLD}⚠ 隧道未建立${RST}"
    echo "B 已部署完成并会持续重试，卡在这里只有一个原因："
    echo "  ${BLD}A 机的 $rport/tcp 没有对外开放${RST}"
    echo
    echo "去 A 机的${BLD}云厂商控制台安全组${RST}放行 ${BLD}$rport/tcp${RST}（入方向）。"
    echo "放行后无需重跑任何命令，30 秒内隧道会自动建立。"
    echo
    echo "确认方法（本机）：${CYN}ss -tn state established | grep $rport${RST}"
    echo "或直接测连通：  ${CYN}timeout 5 bash -c '</dev/tcp/$aip/$rport' && echo 通 || echo 不通${RST}"
  fi
  echo
  ok "B 端无任何入站监听，公网扫不到"
  ok "B 换 IP 无需任何操作，Xray 会自动重拨"
  echo
  warn "如需把 SSH 迁到高位端口（降低暴露面），单独跑：菜单 10"
}

# ================= 节点 / 出口机 管理 =================
# 架构：一个节点 = 一台出口机 = 一个 portal 标签（严格 1:1）
#   A 端 reverse-in 挂多个 bridge client，每个带自己的 reverse.tag
#   路由一节点一条规则：user:[nodeX] -> portal-nodeX
# B 端无需任何改动：它只认 token 里的 uuid，一台 B 一个 uuid 天然分开，
# 多台 B 复用同一个反代端口没问题。

# 输出：节点名 <TAB> portal标签 <TAB> 出口uuid（一行一个节点）
# portal 标签或 uuid 为空 = 该节点没有绑定出口机
list_exits(){
  [ -f "$CFG" ] || return 1
  ATT_CFG="$CFG" python3 - <<'PY'
import json,os,sys
try:
    d=json.load(open(os.environ['ATT_CFG']))
except Exception:
    sys.exit(1)
bridges={}
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                bridges[t]=c.get('id','')
node2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # probe-in 的探测规则（user=probe-<节点>）不是节点规则
    if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
        for u in r.get('user',[]):
            node2portal[u]=ot
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in':
        for c in ib.get('settings',{}).get('clients',[]):
            n=c.get('email','node')
            p=node2portal.get(n,'')
            print('%s\t%s\t%s'%(n,p,bridges.get(p,'')))
PY
}

# 只列节点名
list_nodes(){ list_exits | cut -f1; }

# xray -test 查不出来的错配，必须自己拦。以下三种实测（Xray 26.6.27）
# 全部返回 Configuration OK，Xray 一个都不管：
#   1) 节点没有 portal 规则 -> 流量 fallthrough 到 direct，从 A 出网，泄露 A 的 IP
#   2) portal 标签重复     -> Xray 在多条隧道间随机派流，出口 IP 不确定
#   3) 规则指向不存在的标签 -> 静默失效
validate_cfg(){
  local f="${1:-$CFG}"
  ATT_CFG="$f" python3 - <<'PY'
import json,os,sys
err=[]
try:
    d=json.load(open(os.environ['ATT_CFG']))
except Exception as e:
    print('配置不是合法 JSON: %s'%e); sys.exit(1)

bridge_tags=[]
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                bridge_tags.append(t)
dup=sorted({t for t in bridge_tags if bridge_tags.count(t)>1})
for t in dup:
    err.append('portal 标签重复: %s（流量会在多条隧道间随机派发）'%t)

nodes=[]
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in':
        for c in ib.get('settings',{}).get('clients',[]):
            nodes.append(c.get('email','node'))

node2portal={}
probe2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 按 inboundTag 区分：probe-in 的是出口探测规则（user=probe-<节点>），单独校验
    if 'probe-in' in (r.get('inboundTag') or []):
        if ot.startswith('portal') and ot not in bridge_tags:
            err.append('探测路由指向不存在的 portal 标签: %s'%ot)
        for u in r.get('user',[]):
            probe2portal[u]=ot
        continue
    if not ot.startswith('portal'):
        continue
    if ot not in bridge_tags:
        err.append('路由指向不存在的 portal 标签: %s'%ot)
    for u in r.get('user',[]):
        if u not in nodes:
            err.append('路由里有悬空用户: %s（入站里没这个节点）'%u)
        node2portal[u]=ot

for n in nodes:
    if n not in node2portal:
        err.append('节点 %s 没绑定出口机（流量会从 A 直接出网，泄露 A 的 IP）'%n)

# 启用了出口探测时：探测账号必须和节点一一对应，且探测走的出口必须等于节点的出口
if any(ib.get('tag')=='probe-in' for ib in d.get('inbounds',[])):
    for u,ot in probe2portal.items():
        n=u[len('probe-'):] if u.startswith('probe-') else None
        if n not in nodes:
            err.append('探测路由里有悬空账号: %s'%u)
        elif node2portal.get(n) and ot!=node2portal[n]:
            err.append('节点 %s 的探测出口(%s)和节点出口(%s)不一致'%(n,ot,node2portal[n]))

if err:
    for e in err:
        print(e)
    sys.exit(1)
PY
}

# 旧版（1.x）只有一个叫 "portal" 的标签，所有节点共享它。
# 升级做法：标签 portal -> portal-<首个节点名>，bridge uuid 不变，
# 所以 B 端不用重新部署，老 token 和客户端链接全部继续有效。
needs_migrate(){
  [ -f "$CFG" ] || return 1
  grep -q '"tag": "portal"' "$CFG" 2>/dev/null
}

migrate_cfg(){
  need_root
  [ -f "$STATE/a.env" ] || die "只有 A 端需要升级配置"
  needs_migrate || { ok "配置已是多出口结构，无需升级"; return 0; }

  info "检测到旧的单 portal 配置，升级为多出口结构 ..."
  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import json,os,sys
d=json.load(open(os.environ['ATT_CFG']))
first=None
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in':
        cs=ib.get('settings',{}).get('clients',[])
        if cs:
            first=cs[0].get('email','node1')
        break
if not first:
    raise SystemExit('NONODE')
new='portal-%s'%first
hit=False
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            rv=c.get('reverse') or {}
            if rv.get('tag')=='portal':
                rv['tag']=new; c['reverse']=rv; hit=True
for r in d.get('routing',{}).get('rules',[]):
    if r.get('outboundTag')=='portal':
        r['outboundTag']=new; hit=True
if not hit:
    raise SystemExit('NOTHING')
sys.stderr.write(new+'\n')
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"; die "升级失败：配置解析异常（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"
    echo "$vmsg" | sed 's/^/    /'
    die "升级后配置自检不通过（原配置未改动）"
  fi
  apply_cfg "$tmp"
  ok "配置已升级为多出口结构"
  ok "B 端无需重新部署，客户端链接也不变（bridge uuid 未变）"
  local shared; shared=$(list_exits | awk -F'\t' '{print $2}' | sort | uniq -d)
  if [ -n "$shared" ]; then
    echo
    warn "以下出口被多个节点共用（遗留的旧结构，不是 1:1）："
    local p
    while read -r p; do
      [ -z "$p" ] && continue
      echo "    $p <- $(list_exits | awk -F'\t' -v t="$p" '$2==t{printf "%s ", $1}')"
    done <<< "$shared"
    warn "这些节点出口 IP 相同。想让它们各走自己的出口机："
    warn "  先删掉多余的（菜单 7），再用菜单 5 每个重新加一台出口机"
  fi
}

# A 端所有改动入口先跑一下，避免在旧结构上叠新出口
ensure_migrated(){
  needs_migrate || return 0
  warn "当前是旧的单出口配置，先自动升级"
  migrate_cfg
}

# 菜单入口：交互式平滑升级。比 --migrate 多一层说明和确认，
# 且不会因为「本机不是 A 端 / 无需升级」就退出整个脚本。
migrate_menu(){
  if [ ! -f "$STATE/a.env" ]; then
    warn "本机不是 A 端（入口机），不需要升级配置"
    [ -f "$STATE/b.env" ] && info "B 端（出口机）无需任何改动，老 token 继续有效"
    return 1
  fi
  if ! needs_migrate; then
    ok "配置已经是 1:1 多出口结构，无需升级"
    echo
    show_exits || true
    return 0
  fi

  echo "${BLD}--- 平滑升级为 1:1 多出口结构 ---${RST}"
  echo
  echo "当前配置是旧的单出口结构：所有节点共用一个 ${CYN}portal${RST} 标签，"
  echo "也就是不管几个节点，出口永远是同一台出口机。"
  echo
  echo "升级会把标签改名为 ${CYN}portal-<首个节点名>${RST}，并让后续新增节点"
  echo "各自绑定专属出口机。${BLD}bridge uuid 保持不变${RST}，所以："
  echo "  ${GRN}•${RST} 出口机（B）不用重新部署，老 token 继续有效"
  echo "  ${GRN}•${RST} 客户端分享链接不变，不用重新导入"
  echo "  ${GRN}•${RST} 原配置自动备份到 $CFG.bak-*，服务起不来自动回滚"
  echo
  local n; n=$(list_nodes 2>/dev/null | grep -c . 2>/dev/null) || n=0
  [ -n "$n" ] || n=0
  if [ "$n" -gt 1 ] 2>/dev/null; then
    warn "你现在有 $n 个节点共用一台出口机。升级${BLD}不会${RST}凭空造出新出口机，"
    warn "它们升级后仍然共享。想让它们各走自己的出口机，升级完后："
    warn "  先用菜单 7 删掉多余节点，再用菜单 5 每个重新加一台出口机"
    echo
  fi
  warn "升级会重启 att-tunnel 服务，期间连接会断几秒"
  read -rp "确认升级？（输 yes）: " c
  [ "$c" = yes ] || { warn "已取消，配置未改动"; return; }
  echo
  migrate_cfg
}

show_links(){
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  echo "${BLD}--- 客户端分享链接 ---${RST}"
  local epath; epath=$(printf '%s' "$XPATH" | sed 's|/|%2F|g')
  local tr="${TRANSPORT:-xhttp}"
  local uport="${USER_PORT:-443}"
  local rows; rows=$(list_exits 2>/dev/null || true)
  local n uuid fl qs
  # flow 由每个用户自己的配置决定，不能一刀切
  while read -r n uuid fl; do
    [ -z "$n" ] && continue
    if [ "$tr" = xhttp ]; then
      qs="type=xhttp&path=$epath&mode=auto"
    elif [ "$fl" = "xtls-rprx-vision" ]; then
      qs="type=tcp&flow=xtls-rprx-vision"
    else
      qs="type=tcp"
    fi
    # 每个节点标注它的专属出口（1:1）
    local ptag tip=""
    ptag=$(printf '%s\n' "$rows" | awk -F'\t' -v k="$n" '$1==k{print $2}')
    if [ -z "$ptag" ]; then
      tip="  ${RED}未绑定出口机（流量会从 A 出网，泄露 A 的 IP）${RST}"
    else
      tip="  出口：${CYN}$ptag${RST}"
    fi
    echo
    echo "${CYN}[$n]${RST}$tip"
    echo "vless://$uuid@$A_IP:$uport?encryption=none&security=reality&$qs&sni=$SNI&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID#$n"
  done < <("$XRAY_BIN" -test -config "$CFG" >/dev/null 2>&1 && ATT_CFG="$CFG" python3 - <<'PY'
import json,os
d=json.load(open(os.environ['ATT_CFG']))
for ib in d['inbounds']:
    if ib.get('tag')=='user-in':
        for c in ib['settings']['clients']:
            print(c.get('email','node'), c['id'], c.get('flow',''))
PY
)
  echo
  echo "${BLD}一个节点 = 一台出口机${RST}（严格 1:1）。拿某节点的出口机部署命令：菜单 6"
  echo "隧道是否全部连上：菜单 8（自检）。A 侧无法把单条连接对到具体节点，只能看总数。"
  if [ "$tr" != xhttp ]; then
    echo "${BLD}客户端必须带上 ${GRN}flow=xtls-rprx-vision${RST}${BLD}（导入后请核对）${RST}"
    echo "若报 EOF / 502，几乎肯定是客户端丢了 flow 参数。"
  fi
}

# 打印某台出口机的部署命令（token 含隧道密钥）
print_b_cmd(){
  local buuid="$1" name="${2:-}"
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  local token
  token=$(printf '%s|%s|%s|%s|%s' "$A_IP" "$REVERSE_PORT" "$buuid" "${VLESS_ENC:-none}" "${REVERSE_STYLE:-new}" | base64 -w0)
  echo
  echo "${BLD}到这个节点的出口机${name:+（$name）}上执行：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL $RAW_URL) --bridge $token${RST}"
  echo
  echo "${YEL}这串 token 含隧道密钥，只在你自己两台机器间使用，不要外发。${RST}"
}

add_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端加节点"
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  ensure_migrated
  local name="${1:-}"
  [ -n "$name" ] || { read -rp "节点名称（如 node2）: " name; }
  [ -n "$name" ] || die "名称不能为空"
  # 节点名会拼进 portal 标签和分享链接，限制字符集
  printf '%s' "$name" | grep -qE '^[A-Za-z0-9_-]{1,32}$' \
    || die "名称只能用字母/数字/下划线/连字符，最多 32 位"

  local uport
  read -rp "为这个节点指定入口端口（回车使用已有的 ${USER_PORT:-443}）: " uport
  [ -n "$uport" ] || uport="${USER_PORT:-443}"
  case "$uport" in (*[!0-9]*) die "端口必须是数字";; esac
  [ "$uport" -ge 1 ] && [ "$uport" -le 65535 ] || die "端口越界（1-65535）"

  local uuid buuid
  uuid=$("$XRAY_BIN" uuid)    # 客户端用
  buuid=$("$XRAY_BIN" uuid)   # 这个节点专属出口机用

  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  NEW_NAME="$name" NEW_UUID="$uuid" NEW_BUUID="$buuid" ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import json,os
d=json.load(open(os.environ['ATT_CFG']))
name=os.environ['NEW_NAME']
uuid=os.environ['NEW_UUID']; buuid=os.environ['NEW_BUUID']
ptag='portal-%s'%name

# raw 模式必带 Vision（抗封）；xhttp 不支持 flow
vision=False
for ib in d['inbounds']:
    if ib.get('tag')=='user-in' and ib['streamSettings'].get('network')=='raw':
        vision=True

for ib in d['inbounds']:
    if ib.get('tag')=='user-in':
        cs=ib['settings']['clients']
        if any(c.get('email')==name for c in cs):
            raise SystemExit('DUP')
        c={'id':uuid,'email':name}
        if vision:
            c['flow']='xtls-rprx-vision'
        cs.append(c)

# 严格 1:1：这个节点自己的 bridge client + 自己的 portal 标签
for ib in d['inbounds']:
    if ib.get('tag')=='reverse-in':
        bs=ib['settings']['clients']
        if any((b.get('reverse') or {}).get('tag')==ptag for b in bs):
            raise SystemExit('DUPTAG')
        bs.append({'id':buuid,'reverse':{'tag':ptag}})

# 一节点一条路由，不往旧规则里追加
d.setdefault('routing',{}).setdefault('rules',[]).append(
    {'type':'field','user':[name],'outboundTag':ptag})
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "节点名已存在或配置解析失败（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "配置自检不通过（原配置未改动）"
  fi

  apply_cfg "$tmp"
  open_fw "$REVERSE_PORT" 2>/dev/null || true
  ok "节点 $name 已添加（专属出口 portal-$name）"
  warn "这个节点现在还没有出口机，隧道未建立前不可用"
  print_b_cmd "$buuid" "$name"
  echo
  info "出口机部署完后，跑菜单 8（自检）确认隧道已连"
  show_links
}

# 节点 / 出口机 对应表
show_exits(){
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || { warn "配置里没有任何节点"; return 1; }
  echo "${BLD}--- 节点 / 出口机（严格 1:1）---${RST}"
  local i=0 n p u
  while IFS=$'\t' read -r n p u; do
    [ -z "$n" ] && continue
    i=$((i+1))
    if [ -z "$p" ]; then
      echo "  $i) $n  ${RED}未绑定出口机${RST}"
    else
      echo "  $i) $n  →  $p"
    fi
  done <<< "$rows"
  echo
  local shared; shared=$(printf '%s\n' "$rows" | awk -F'\t' '$2!=""{print $2}' | sort | uniq -d)
  if [ -n "$shared" ]; then
    warn "有出口被多个节点共用，这些节点出口 IP 相同（不是 1:1）："
    local p2
    while read -r p2; do
      [ -z "$p2" ] && continue
      echo "    $p2 <- $(printf '%s\n' "$rows" | awk -F'\t' -v t="$p2" '$2==t{printf "%s ", $1}')"
    done <<< "$shared"
  fi
  info "拿某节点的出口机部署命令：菜单 6；隧道连接情况：菜单 8（自检）"
}

# 重新拿某个节点的出口机部署命令（换机、重装时用）
show_exit_cmd(){
  [ -f "$STATE/a.env" ] || die "只能在 A 端查"
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || die "配置里没有任何节点"
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "${BLD}--- 节点 / 出口机 ---${RST}"
    local i=0 n p u
    while IFS=$'\t' read -r n p u; do
      [ -z "$n" ] && continue
      i=$((i+1))
      echo "  $i) $n  ${p:-${RED}未绑定${RST}}"
    done <<< "$rows"
    echo
    read -rp "查哪个节点的出口机命令？（名称或序号，回车取消）: " name
    [ -n "$name" ] || { warn "已取消"; return; }
  fi
  if printf '%s' "$name" | grep -qE '^[0-9]+$'; then
    name=$(printf '%s\n' "$rows" | sed -n "${name}p" | cut -f1)
    [ -n "$name" ] || die "序号超出范围"
  fi
  local line; line=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n')
  [ -n "$line" ] || die "节点 $name 不存在"
  local buuid; buuid=$(printf '%s' "$line" | cut -f3)
  [ -n "$buuid" ] || die "节点 $name 没有绑定出口机（配置异常，跑菜单 8 自检）"
  print_b_cmd "$buuid" "$name"
}

del_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端删节点"
  ensure_migrated
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || die "配置里没有任何节点"
  local names; names=$(printf '%s\n' "$rows" | cut -f1)
  local total; total=$(printf '%s\n' "$names" | grep -c .)

  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "${BLD}--- 当前节点 / 出口机 ---${RST}"
    local i=0 n p u
    while IFS=$'\t' read -r n p u; do
      [ -z "$n" ] && continue
      i=$((i+1))
      echo "  $i) $n  ${p:-${RED}未绑定${RST}}"
    done <<< "$rows"
    echo
    read -rp "删除哪个节点？（输名称或序号，回车取消）: " name
    [ -n "$name" ] || { warn "已取消"; return; }
  fi

  # 允许按序号选
  if printf '%s' "$name" | grep -qE '^[0-9]+$'; then
    local picked; picked=$(printf '%s\n' "$names" | sed -n "${name}p")
    [ -n "$picked" ] || die "序号 $name 超出范围（共 $total 个）"
    name="$picked"
  fi

  printf '%s\n' "$names" | grep -qxF "$name" || die "节点 $name 不存在"
  # 入站至少要留一个 client，否则 Xray 校验不过；真要清空请走卸载
  [ "$total" -gt 1 ] || die "这是最后一个节点，删掉入口就没人能用了。要停用请用菜单 11（卸载）"

  local ptag; ptag=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n{print $2}')
  echo
  warn "将一并删除它的专属出口绑定${ptag:+（$ptag）}"
  warn "对应的出口机会失去连接。它上面的 att-tunnel 需你自己去卸载（否则它会一直重试拨号）"
  read -rp "确认删除节点 ${BLD}$name${RST}？它的分享链接会立刻失效（输 yes）: " c
  [ "$c" = yes ] || { warn "已取消"; return; }

  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  DEL_NAME="$name" ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import json,os
d=json.load(open(os.environ['ATT_CFG']))
name=os.environ['DEL_NAME']

# 这个节点绑的 portal 标签（从路由反查，比拼名字可靠）
ptags=set()
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    if ot.startswith('portal') and name in r.get('user',[]) and 'probe-in' not in (r.get('inboundTag') or []):
        ptags.add(ot)

found=False
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in':
        cs=ib['settings']['clients']
        keep=[c for c in cs if c.get('email')!=name]
        if len(keep)!=len(cs):
            found=True
        if not keep:
            raise SystemExit('LAST')
        ib['settings']['clients']=keep
if not found:
    raise SystemExit('NOTFOUND')

# 1:1：摘掉它专属的 bridge client。仅当没有其他节点共用该标签时才删，
# 防止旧结构（多节点共一个 portal）下误删别人的隧道。
still={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 探测规则（probe-in）不算“共用”，否则 probe-<节点> 会让 bridge 永远删不掉
    if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
        others=[u for u in r.get('user',[]) if u!=name]
        if others:
            still[ot]=others
drop={t for t in ptags if t not in still}
if drop:
    for ib in d.get('inbounds',[]):
        if ib.get('tag')=='reverse-in':
            ib['settings']['clients']=[
                b for b in ib['settings']['clients']
                if (b.get('reverse') or {}).get('tag') not in drop]

# 同步摘掉 portal 路由里的这个用户，用空了的规则整条删掉
rules=[]
for r in d.get('routing',{}).get('rules',[]):
    if 'user' in r:
        r['user']=[u for u in r['user'] if u!=name]
        if not r['user']:
            continue
    rules.append(r)
d['routing']['rules']=rules
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "删除失败：配置解析异常或节点已不存在（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "配置自检不通过（原配置未改动）"
  fi

  # apply_cfg 会先 xray -test 校验，失败自动回滚
  apply_cfg "$tmp"
  ok "节点 $name 及其出口绑定已删除（已备份原配置到 $CFG.bak-*）"
  echo
  info "剩下的节点："
  show_links
}

# ================= 流量统计 / 出口探测（A 端） =================
# 设计：
#   stats + api（只听 127.0.0.1:<随机口>）+ policy 打开按用户计流量。
#   用户 client 的 email = 节点名 → 计数器 user>>>节点>>>traffic>>>uplink/downlink
#   bridge client 的 email = exit.portal-<节点>（出口侧计数，方向相反，面板不用）
#   probe-in：127.0.0.1 上的 socks（密码认证），每个节点一个账号 probe-<节点>，
#   路由 user:[probe-<节点>] + inboundTag:[probe-in] -> portal-<节点>，
#   面板经它访问 api.ipify.org，拿到的就是该节点出口机（B）的实时公网 IP。
#   statsonlineiplist 对反向 bridge 拿不到 IP（已实测），所以只能这样探。
#   probe-in 兜底规则 -> blackhole：探测账号万一没对上规则，宁可失败也不从 A 直出（否则会显示 A 的 IP）。
# 分享链接、B 端配置都不变。

# 是否已启用统计（config 里有 api 段 + probe-in 入站）
stats_enabled(){
  [ -f "$CFG" ] || return 1
  ATT_CFG="$CFG" python3 - <<'PY'
import json,os,sys
d=json.load(open(os.environ['ATT_CFG']))
ok=bool((d.get('api') or {}).get('listen')) and any(ib.get('tag')=='probe-in' for ib in d.get('inbounds',[]))
sys.exit(0 if ok else 1)
PY
}

# 统计/探测用的两个本地端口，存在 a.env 里（STATS_API_PORT / PROBE_PORT）
ensure_stats_ports(){
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  if [ -z "${STATS_API_PORT:-}" ]; then
    STATS_API_PORT=$(free_port); echo "STATS_API_PORT=$STATS_API_PORT" >> "$STATE/a.env"
  fi
  if [ -z "${PROBE_PORT:-}" ] || [ "$PROBE_PORT" = "$STATS_API_PORT" ]; then
    PROBE_PORT=$(free_port)
    while [ "$PROBE_PORT" = "$STATS_API_PORT" ]; do PROBE_PORT=$(free_port); done
    sed -i '/^PROBE_PORT=/d' "$STATE/a.env"; echo "PROBE_PORT=$PROBE_PORT" >> "$STATE/a.env"
  fi
  chmod 600 "$STATE/a.env"
}

# 把统计/探测结构同步进配置文件 $1（原地改写，幂等）。
#   $2=1：没启用也强制加上（部署 / 升级用）；$2=0：只在已启用时同步（加删节点 / 迁移用）
# 同步内容：api/stats/policy、节点 email、bridge email、每节点一个探测账号 + 一条探测路由，
# 删掉已不存在节点的探测账号/路由，探测路由的出口永远跟节点路由一致。
stats_sync(){
  local f="$1" force="${2:-0}" out rc=0
  out=$(mktemp --suffix=.json)
  ATT_CFG="$f" ATT_FORCE="$force" API_PORT="${STATS_API_PORT:-}" PRB_PORT="${PROBE_PORT:-}" \
    python3 - > "$out" <<'PY' || rc=$?
import json,os,secrets,sys
d=json.load(open(os.environ['ATT_CFG']))
ibs=d.setdefault('inbounds',[])
has=bool((d.get('api') or {}).get('listen')) and any(ib.get('tag')=='probe-in' for ib in ibs)
if not has and os.environ.get('ATT_FORCE')!='1':
    print(json.dumps(d,indent=1)); sys.exit(0)
ap=os.environ.get('API_PORT',''); pp=os.environ.get('PRB_PORT','')
# 已启用时沿用配置里的端口，只有新增时才需要端口参数
if not has and not (ap.isdigit() and pp.isdigit()):
    raise SystemExit('NOPORT')
if not (d.get('api') or {}).get('listen'):
    d['api']={'tag':'api','listen':'127.0.0.1:%s'%ap,'services':['StatsService']}
d.setdefault('stats',{})
pol=d.setdefault('policy',{})
lv=pol.setdefault('levels',{}).setdefault('0',{})
lv['statsUserUplink']=True; lv['statsUserDownlink']=True
sy=pol.setdefault('system',{})
for k in ('statsInboundUplink','statsInboundDownlink','statsOutboundUplink','statsOutboundDownlink'):
    sy[k]=True
rules=d.setdefault('routing',{}).setdefault('rules',[])
def is_probe(r): return 'probe-in' in (r.get('inboundTag') or [])
nodes=[]
for ib in ibs:
    if ib.get('tag')=='user-in':
        for i,c in enumerate(ib.get('settings',{}).get('clients',[])):
            if not c.get('email'):
                c['email']='node' if i==0 else 'node%d'%(i+1)
            nodes.append(c['email'])
for ib in ibs:
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                c['email']='exit.%s'%t
n2p={}
for r in rules:
    ot=r.get('outboundTag','')
    if ot.startswith('portal') and not is_probe(r):
        for u in r.get('user',[]):
            n2p.setdefault(u,ot)
pin=[ib for ib in ibs if ib.get('tag')=='probe-in']
if pin:
    pin=pin[0]
else:
    pin={'tag':'probe-in','listen':'127.0.0.1','port':int(pp),'protocol':'socks',
         'settings':{'auth':'password','accounts':[],'udp':False}}
    ibs.append(pin)
pin['listen']='127.0.0.1'
st=pin.setdefault('settings',{}); st['auth']='password'; st['udp']=False
old={a.get('user'):a.get('pass') for a in st.get('accounts',[]) if a.get('pass')}
st['accounts']=[{'user':'probe-'+n,'pass':old.get('probe-'+n) or secrets.token_hex(16)} for n in nodes]
if not st['accounts']:
    raise SystemExit('NONODE')
obs=d.setdefault('outbounds',[])
if not any(o.get('tag')=='probe-block' for o in obs):
    obs.append({'tag':'probe-block','protocol':'blackhole'})
keep=[r for r in rules if not is_probe(r)]
pr=[{'type':'field','inboundTag':['probe-in'],'user':['probe-'+n],'outboundTag':n2p[n]} for n in nodes if n in n2p]
pr.append({'type':'field','inboundTag':['probe-in'],'outboundTag':'probe-block'})
d['routing']['rules']=pr+keep
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$out" ]; then rm -f "$out"; return 1; fi
  mv "$out" "$f"
}

# 已部署的 A 端升级：加上统计 + 出口探测。幂等，可反复跑。
# 先备份，xray -test + validate_cfg 都过了才替换；服务起不来 apply_cfg 自动回滚。
enable_stats(){
  need_root
  [ -f "$STATE/a.env" ] || die "只有 A 端（入口机）需要启用统计"
  [ -f "$CFG" ] || die "找不到配置 $CFG"
  ensure_migrated
  ensure_stats_ports
  local tmp; tmp=$(mktemp --suffix=.json)
  cp "$CFG" "$tmp"
  stats_sync "$tmp" 1 || { rm -f "$tmp"; die "统计配置生成失败（原配置未改动）"; }
  if ATT_A="$CFG" ATT_B="$tmp" python3 -c 'import json,os,sys; a=json.load(open(os.environ["ATT_A"])); b=json.load(open(os.environ["ATT_B"])); sys.exit(0 if a==b else 1)'; then
    rm -f "$tmp"; ok "流量统计 / 出口探测已启用，配置无需改动"; return 0
  fi
  "$XRAY_BIN" -test -config "$tmp" >/dev/null 2>&1 || {
    "$XRAY_BIN" -test -config "$tmp" 2>&1 | tail -5; rm -f "$tmp"
    die "新配置 xray -test 不通过（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "新配置自检不通过（原配置未改动）"
  fi
  warn "将重启 att-tunnel，连接会断几秒（分享链接、B 端都不变）"
  apply_cfg "$tmp"
  ok "已启用流量统计（API 仅监听 127.0.0.1:$STATS_API_PORT）和出口探测（127.0.0.1:$PROBE_PORT）"
  systemctl is-active --quiet "$WEB_SVC" 2>/dev/null && systemctl restart "$WEB_SVC" || true
}

# ================= 网页流量面板（A 端） =================
WEB_SVC="att-tunnel-web"
WEB_DIR="/usr/local/lib/att-tunnel"
WEB_PY="$WEB_DIR/web.py"
WEB_ENV="$STATE/web.env"
WEB_DATA="/var/lib/att-tunnel"

write_web_py(){
  mkdir -p "$WEB_DIR"
  cat > "$WEB_PY.tmp" <<'ATT_WEB_PY'
#!/usr/bin/env python3
# att-tunnel 流量面板：只用 Python 标准库。
# 数据来源：Xray StatsService（每 60s 带 -reset 拉一次，累加进本地 JSON，xray 重启也不丢总量）
# 出口 IP：经本机 127.0.0.1 的 probe-in（socks5+密码）按节点走 portal-<节点>，访问 api.ipify.org
# 安全：随机端口 + 随机路径前缀 + 登录密码（root 600 文件）；会话 Cookie HttpOnly/SameSite=Strict；
#       重置/探测需 CSRF token；登录失败限速。面板绝不返回 vless 链接或 UUID。
import hmac
import http.cookies
import http.server
import ipaddress
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

CFG = os.environ.get('ATT_CFG', '/usr/local/etc/att-tunnel/config.json')
ENVF = os.environ.get('ATT_WEB_ENV', '/etc/att-tunnel/web.env')
STATEF = os.environ.get('ATT_WEB_STATE', '/var/lib/att-tunnel/web-state.json')
XRAY = os.environ.get('ATT_XRAY', '/usr/local/bin/xray')
POLL = int(os.environ.get('ATT_POLL', '60'))
PROBE_EVERY = int(os.environ.get('ATT_PROBE_EVERY', '300'))
SESSION_TTL = 12 * 3600
IP_SOURCES = [('api.ipify.org', '/'), ('icanhazip.com', '/'), ('ifconfig.me', '/ip')]


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = load_env(ENVF)
PORT = int(ENV['WEB_PORT'])
PREFIX = '/' + ENV['WEB_PATH'].strip('/')
PASS = ENV['WEB_PASS']
LISTEN = ENV.get('WEB_LISTEN', '0.0.0.0')
if len(PASS) < 8 or PREFIX == '/':
    sys.exit('web.env 不完整：WEB_PASS 至少 8 位，WEB_PATH 不能为空')

lock = threading.RLock()
probe_lock = threading.Lock()
state = {'nodes': {}, 'last_poll': 0, 'poll_err': ''}


def now():
    return int(time.time())


def load_state():
    global state
    try:
        with open(STATEF) as f:
            s = json.load(f)
        if isinstance(s, dict) and isinstance(s.get('nodes'), dict):
            state = s
    except Exception:
        pass


def save_state():
    # 原子写：先写临时文件再 rename，断电/崩溃不会留下半截 JSON
    d = os.path.dirname(STATEF)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = '%s.tmp.%d' % (STATEF, os.getpid())
    with lock:
        data = json.dumps(state, ensure_ascii=False)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATEF)


def read_cfg():
    """从 config.json 读节点表：名称、入口端口、绑定出口、探测账号、API 地址。"""
    with open(CFG) as f:
        d = json.load(f)
    api = (d.get('api') or {}).get('listen', '')
    nodes, uport, probe_port, probe_acc = [], None, None, {}
    for ib in d.get('inbounds', []):
        if ib.get('tag') == 'user-in':
            uport = ib.get('port')
            for c in ib.get('settings', {}).get('clients', []):
                nodes.append(c.get('email', 'node'))
        elif ib.get('tag') == 'probe-in':
            probe_port = ib.get('port')
            for a in ib.get('settings', {}).get('accounts', []):
                probe_acc[a.get('user', '')] = a.get('pass', '')
    portal = {}
    for r in d.get('routing', {}).get('rules', []):
        ot = r.get('outboundTag', '')
        if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
            for u in r.get('user', []):
                portal[u] = ot
    out = []
    for n in nodes:
        out.append({'name': n, 'port': uport, 'exit': portal.get(n, ''),
                    'probe_user': 'probe-' + n,
                    'probe_pass': probe_acc.get('probe-' + n, '')})
    return {'api': api, 'probe_port': probe_port, 'nodes': out}


def node_rec(name):
    with lock:
        return state['nodes'].setdefault(name, {
            'up': 0, 'down': 0, 'since': now(), 'ip': '', 'ip_ts': 0,
            'probe_ok': False, 'probe_ts': 0, 'probe_err': ''})


def statsquery(api, pattern, reset=True):
    cmd = [XRAY, 'api', 'statsquery', '--server=' + api, '-pattern', pattern]
    if reset:
        cmd.append('-reset')
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[-200:] or 'statsquery 失败')
    txt = p.stdout.strip()
    if not txt:
        return []
    return (json.loads(txt).get('stat') or [])


def poll_stats():
    """拉取 user>>>节点>>>traffic>>>uplink/downlink 并清零，累加进本地状态。"""
    try:
        c = read_cfg()
        if not c['api']:
            raise RuntimeError('config.json 没有 api 段，请先在脚本里启用统计')
        names = {n['name'] for n in c['nodes']}
        stats = statsquery(c['api'], 'user>>>')
        with lock:
            for s in stats:
                parts = s.get('name', '').split('>>>')
                if len(parts) != 4 or parts[0] != 'user' or parts[2] != 'traffic':
                    continue
                n, direction = parts[1], parts[3]
                if n not in names:
                    continue  # probe-<节点> 的探测流量不计入
                v = int(s.get('value') or 0)
                r = node_rec(n)
                if direction == 'uplink':
                    r['up'] += v
                elif direction == 'downlink':
                    r['down'] += v
            state['last_poll'] = now()
            state['poll_err'] = ''
    except Exception as e:
        with lock:
            state['poll_err'] = str(e)[:200]
    save_state()
def recv_exact(s, n):
    b = b''
    while len(b) < n:
        x = s.recv(n - len(b))
        if not x:
            raise RuntimeError('socks 连接被关闭')
        b += x
    return b


def socks5_get(port, user, pw, host, path, timeout=15):
    """标准库 socks5（RFC1928/1929 密码认证）+ 明文 HTTP GET，返回响应体。"""
    s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    try:
        s.sendall(b'\x05\x01\x02')
        if recv_exact(s, 2) != b'\x05\x02':
            raise RuntimeError('socks 不接受密码认证')
        u, p = user.encode(), pw.encode()
        s.sendall(b'\x01' + bytes([len(u)]) + u + bytes([len(p)]) + p)
        if recv_exact(s, 2)[1] != 0:
            raise RuntimeError('socks 认证失败')
        h = host.encode()
        s.sendall(b'\x05\x01\x00\x03' + bytes([len(h)]) + h + (80).to_bytes(2, 'big'))
        rep = recv_exact(s, 4)
        if rep[1] != 0:
            raise RuntimeError('socks 连接失败 rep=%d' % rep[1])
        atyp = rep[3]
        if atyp == 1:
            recv_exact(s, 6)
        elif atyp == 4:
            recv_exact(s, 18)
        else:
            recv_exact(s, recv_exact(s, 1)[0] + 2)
        req = ('GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: curl/8.0\r\n'
               'Accept: */*\r\nConnection: close\r\n\r\n' % (path, host))
        s.sendall(req.encode())
        buf = b''
        while len(buf) < 65536:
            x = s.recv(4096)
            if not x:
                break
            buf += x
    finally:
        s.close()
    head, _, body = buf.partition(b'\r\n\r\n')
    status = head.split(b'\r\n', 1)[0]
    if b' 200' not in status:
        raise RuntimeError('HTTP ' + status.decode('latin1')[:40])
    return body.decode('latin1').strip()


def probe_node(n, probe_port):
    r = node_rec(n['name'])
    err = ''
    ip = ''
    if not probe_port or not n['probe_pass']:
        err = '未配置探测账号'
    else:
        for host, path in IP_SOURCES:
            try:
                txt = socks5_get(probe_port, n['probe_user'], n['probe_pass'], host, path)
                ip = str(ipaddress.ip_address(txt.split()[0]))
                break
            except Exception as e:
                err = '%s: %s' % (host, str(e)[:80])
    with lock:
        r['probe_ts'] = now()
        if ip:
            r['ip'], r['ip_ts'], r['probe_ok'], r['probe_err'] = ip, now(), True, ''
        else:
            r['probe_ok'], r['probe_err'] = False, err


def probe_all(only=None):
    if not probe_lock.acquire(blocking=False):
        return  # 已有一轮在跑
    try:
        c = read_cfg()
        ths = []
        for n in c['nodes']:
            if only and n['name'] != only:
                continue
            t = threading.Thread(target=probe_node, args=(n, c['probe_port']), daemon=True)
            t.start()
            ths.append(t)
        for t in ths:
            t.join(60)
    except Exception:
        pass
    finally:
        probe_lock.release()
    save_state()


def worker():
    last_probe = 0
    while True:
        poll_stats()
        if time.time() - last_probe >= PROBE_EVERY:
            last_probe = time.time()
            threading.Thread(target=probe_all, daemon=True).start()
        time.sleep(POLL)


def status_json():
    try:
        c = read_cfg()
        cfg_err = ''
    except Exception as e:
        c, cfg_err = {'nodes': []}, str(e)[:200]
    t = now()
    out = []
    with lock:
        for n in c['nodes']:
            r = node_rec(n['name'])
            online = bool(r['probe_ok'] and t - r['probe_ts'] <= PROBE_EVERY + POLL + 30)
            out.append({'name': n['name'], 'port': n['port'], 'exit': n['exit'],
                        'online': online, 'ip': r['ip'], 'ip_ts': r['ip_ts'],
                        'probe_ts': r['probe_ts'], 'probe_err': r['probe_err'],
                        'up': r['up'], 'down': r['down'], 'total': r['up'] + r['down'],
                        'since': r['since']})
        return {'now': t, 'last_poll': state['last_poll'],
                'error': cfg_err or state['poll_err'], 'nodes': out}
sessions = {}   # sid -> {'exp': ts, 'csrf': token}
fails = {}      # ip -> [失败时间戳]
FAIL_WIN, FAIL_MAX = 600, 5


def rate_limited(ip):
    t = time.time()
    with lock:
        lst = [x for x in fails.get(ip, []) if t - x < FAIL_WIN]
        fails[ip] = lst
        return len(lst) >= FAIL_MAX


def note_fail(ip):
    with lock:
        fails.setdefault(ip, []).append(time.time())


def new_session():
    sid, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
    with lock:
        t = time.time()
        for k in [k for k, v in sessions.items() if v['exp'] < t]:
            del sessions[k]
        sessions[sid] = {'exp': t + SESSION_TTL, 'csrf': csrf}
    return sid


PAGE_LOGIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>att-tunnel 登录</title>
<style>body{font-family:system-ui,sans-serif;background:#f4f5f7;margin:0;display:flex;
min-height:100vh;align-items:center;justify-content:center}form{background:#fff;padding:24px;
border-radius:12px;box-shadow:0 2px 12px #0001;width:min(320px,90vw)}input,button{width:100%;
box-sizing:border-box;padding:10px;margin-top:10px;font-size:16px;border-radius:8px;
border:1px solid #ccc}button{background:#2563eb;color:#fff;border:0}.e{color:#c00}</style></head>
<body><form method="post" action="{P}/login"><h2>att-tunnel 流量面板</h2>{E}
<label for="pw">密码</label><input id="pw" type="password" name="password" autocomplete="current-password" required autofocus>
<button type="submit">登录</button></form></body></html>'''
PAGE_MAIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>att-tunnel 流量面板</title>
<style>body{font-family:system-ui,sans-serif;background:#f4f5f7;margin:0;padding:12px;color:#222}
h1{font-size:20px;margin:4px 0 12px}.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
button{padding:8px 14px;border-radius:8px;border:1px solid #bbb;background:#fff;font-size:15px;cursor:pointer}
button.p{background:#2563eb;color:#fff;border:0}button.d{color:#b91c1c;border-color:#e5a5a5}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px}
.card{background:#fff;border-radius:12px;padding:14px;box-shadow:0 1px 6px #0001}
.card h2{font-size:17px;margin:0 0 8px;display:flex;justify-content:space-between;align-items:center}
.on{color:#15803d}.off{color:#b91c1c}dl{display:grid;grid-template-columns:auto 1fr;gap:4px 10px;margin:0 0 10px}
dt{color:#666}dd{margin:0;word-break:break-all}.m{color:#666;font-size:13px}.err{color:#b91c1c}</style></head>
<body><h1>att-tunnel 流量面板</h1>
<div class="bar"><button class="p" id="probe" type="button">立即探测出口 IP</button>
<button id="refresh" type="button">刷新</button>
<form method="post" action="{P}/logout" style="margin:0"><input type="hidden" name="csrf" value="{C}">
<button type="submit">退出</button></form><span class="m" id="meta" aria-live="polite"></span></div>
<div class="err" id="err" role="alert"></div><div class="grid" id="list"></div>
<script>
const P="{P}",C="{C}";
function fb(n){const u=["B","KB","MB","GB","TB"];let i=0;while(n>=1024&&i<4){n/=1024;i++}return n.toFixed(i?2:0)+" "+u[i]}
function ft(t){if(!t)return"从未";const d=new Date(t*1000);return d.toLocaleString("zh-CN",{hour12:false})}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
async function post(u,body){const r=await fetch(P+u,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded","X-CSRF-Token":C},body:new URLSearchParams(body)});if(r.status==401)location.href=P+"/";return r}
async function load(){try{const r=await fetch(P+"/api/status",{cache:"no-store"});if(r.status==401){location.href=P+"/";return}
const d=await r.json();document.getElementById("err").textContent=d.error?("统计异常："+d.error):"";
document.getElementById("meta").textContent="流量更新于 "+ft(d.last_poll)+"（每 60 秒）";
document.getElementById("list").innerHTML=d.nodes.map(n=>`<section class="card"><h2><span>${esc(n.name)}</span>
<span class="${n.online?"on":"off"}">${n.online?"● 在线":"● 离线"}</span></h2><dl>
<dt>入口端口</dt><dd>${esc(n.port)}</dd><dt>绑定出口</dt><dd>${esc(n.exit||"未绑定")}</dd>
<dt>出口 IP</dt><dd>${esc(n.ip||"—")}</dd><dt>最后在线</dt><dd>${ft(n.ip_ts)}</dd>
<dt>上传</dt><dd>${fb(n.up)}</dd><dt>下载</dt><dd>${fb(n.down)}</dd><dt>合计</dt><dd><b>${fb(n.total)}</b></dd>
<dt>统计起点</dt><dd>${ft(n.since)}</dd></dl>${(!n.online&&n.probe_err)?`<div class="m err">${esc(n.probe_err)}</div>`:""}
<button class="d" type="button" data-reset="${esc(n.name)}">重置</button></section>`).join("")||"<p>没有节点</p>"}
catch(e){document.getElementById("err").textContent="加载失败："+e}}
document.getElementById("list").addEventListener("click",async e=>{const n=e.target.getAttribute("data-reset");if(!n)return;
if(!confirm("确定把节点 "+n+" 的累计流量清零？"))return;await post("/api/reset",{node:n});load()});
document.getElementById("refresh").onclick=load;
document.getElementById("probe").onclick=async e=>{e.target.disabled=true;e.target.textContent="探测中…";
await post("/api/probe",{});e.target.disabled=false;e.target.textContent="立即探测出口 IP";load()};
load();setInterval(load,30000);
</script></body></html>'''
class H(http.server.BaseHTTPRequestHandler):
    server_version = 'att-web'
    sys_version = ''

    def log_message(self, fmt, *a):
        pass  # 不记访问日志（里面会有路径前缀）

    def send(self, code, body, ctype='text/html; charset=utf-8', extra=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                         "connect-src 'self'; form-action 'self'; frame-ancestors 'none'")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(b)

    def redirect(self, to, extra=None):
        self.send(303, '', extra=[('Location', to)] + (extra or []))

    def session(self):
        c = http.cookies.SimpleCookie()
        try:
            c.load(self.headers.get('Cookie', ''))
        except Exception:
            return None, None
        m = c.get('att_sid')
        if not m:
            return None, None
        with lock:
            s = sessions.get(m.value)
            if not s or s['exp'] < time.time():
                return None, None
            return m.value, s

    def form(self):
        n = min(int(self.headers.get('Content-Length') or 0), 4096)
        raw = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def route(self):
        p = urllib.parse.urlsplit(self.path).path
        if p != PREFIX and not p.startswith(PREFIX + '/'):
            return None
        return p[len(PREFIX):] or '/'

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        sid, s = self.session()
        if r == '/':
            if not s:
                return self.send(200, PAGE_LOGIN.replace('{P}', PREFIX).replace('{E}', ''))
            return self.send(200, PAGE_MAIN.replace('{P}', PREFIX).replace('{C}', s['csrf']))
        if r == '/api/status':
            if not s:
                return self.send(401, '{"error":"unauthorized"}', 'application/json')
            return self.send(200, json.dumps(status_json(), ensure_ascii=False),
                             'application/json; charset=utf-8')
        return self.send(404, 'Not Found', 'text/plain')
    def do_POST(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        ip = self.client_address[0]
        if r == '/login':
            if rate_limited(ip):
                return self.send(429, PAGE_LOGIN.replace('{P}', PREFIX).replace(
                    '{E}', '<p class="e">失败次数过多，请 10 分钟后再试</p>'))
            f = self.form()
            if hmac.compare_digest(f.get('password', '').encode(), PASS.encode()):
                sid = new_session()
                ck = ('att_sid=%s; Path=%s; HttpOnly; SameSite=Strict; Max-Age=%d'
                      % (sid, PREFIX, SESSION_TTL))
                return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
            note_fail(ip)
            time.sleep(1)
            return self.send(401, PAGE_LOGIN.replace('{P}', PREFIX).replace(
                '{E}', '<p class="e">密码错误</p>'))
        sid, s = self.session()
        if not s:
            return self.send(401, '{"error":"unauthorized"}', 'application/json')
        f = self.form()
        tok = self.headers.get('X-CSRF-Token') or f.get('csrf', '')
        if not hmac.compare_digest(tok.encode(), s['csrf'].encode()):
            return self.send(403, '{"error":"csrf"}', 'application/json')
        if r == '/logout':
            with lock:
                sessions.pop(sid, None)
            ck = 'att_sid=; Path=%s; HttpOnly; SameSite=Strict; Max-Age=0' % PREFIX
            return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
        if r == '/api/reset':
            n = f.get('node', '')
            try:
                names = {x['name'] for x in read_cfg()['nodes']}
            except Exception:
                names = set()
            if n not in names:
                return self.send(404, '{"error":"no such node"}', 'application/json')
            with lock:
                rec = node_rec(n)
                rec['up'] = rec['down'] = 0
                rec['since'] = now()
            save_state()
            return self.send(200, '{"ok":true}', 'application/json')
        if r == '/api/probe':
            probe_all(f.get('node') or None)
            return self.send(200, '{"ok":true}', 'application/json')
        return self.send(404, 'Not Found', 'text/plain')


class Srv(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    load_state()
    threading.Thread(target=worker, daemon=True).start()
    Srv((LISTEN, PORT), H).serve_forever()


if __name__ == '__main__':
    main()
ATT_WEB_PY
  chmod 700 "$WEB_PY.tmp"; mv "$WEB_PY.tmp" "$WEB_PY"
}

web_url(){
  # shellcheck disable=SC1090,SC1091
  source "$STATE/a.env"
  # shellcheck disable=SC1090,SC1091
  source "$WEB_ENV"
  echo "http://$A_IP:$WEB_PORT/$WEB_PATH/"
}

web_enable(){
  need_root
  [ -f "$STATE/a.env" ] || die "网页面板只在 A 端（入口机）上用"
  command -v python3 >/dev/null || die "缺 python3"
  stats_enabled || enable_stats
  stats_enabled || die "统计未启用，无法开面板"
  if [ ! -f "$WEB_ENV" ]; then
    local p; p=$(free_port)
    umask 077
    printf 'WEB_PORT=%s\nWEB_PATH=%s\nWEB_PASS=%s\nWEB_LISTEN=0.0.0.0\n' \
      "$p" "$(openssl rand -hex 8)" "$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)" > "$WEB_ENV"
    umask 022
  fi
  chmod 600 "$WEB_ENV"; chown root:root "$WEB_ENV"
  write_web_py
  mkdir -p "$WEB_DATA"; chmod 700 "$WEB_DATA"
  cat > "/etc/systemd/system/$WEB_SVC.service" <<EOF
[Unit]
Description=att-tunnel 流量面板
After=network-online.target $SVC.service

[Service]
Type=simple
Environment=ATT_CFG=$CFG ATT_WEB_ENV=$WEB_ENV ATT_WEB_STATE=$WEB_DATA/web-state.json ATT_XRAY=$XRAY_BIN
ExecStart=$(command -v python3) $WEB_PY
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$WEB_SVC" >/dev/null 2>&1 || true
  systemctl restart "$WEB_SVC"
  sleep 2
  systemctl is-active --quiet "$WEB_SVC" || {
    journalctl -u "$WEB_SVC" -n 15 --no-pager 2>&1 | tail -10
    die "面板启动失败"; }
  # shellcheck disable=SC1090
  source "$WEB_ENV"
  open_fw "$WEB_PORT"
  ok "网页面板已启用"
  web_info
}

web_disable(){
  need_root
  systemctl stop "$WEB_SVC" 2>/dev/null || true
  systemctl disable "$WEB_SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WEB_SVC.service"
  systemctl daemon-reload 2>/dev/null || true
  ok "网页面板已关闭（累计流量数据保留在 $WEB_DATA，重新开启后继续累计）"
}

web_info(){
  [ -f "$WEB_ENV" ] || { warn "网页面板还没启用（菜单 13）"; return 1; }
  # shellcheck disable=SC1090
  source "$WEB_ENV"
  if systemctl is-active --quiet "$WEB_SVC" 2>/dev/null; then ok "面板运行中"; else warn "面板当前未运行"; fi
  echo "  地址：${GRN}$(web_url)${RST}"
  echo "  密码：${GRN}$WEB_PASS${RST}"
  echo "  ${YEL}面板是明文 HTTP，靠随机路径 + 密码保护；别在不可信网络里登录，地址和密码不要外发${RST}"
  warn "云厂商安全组需放行 $WEB_PORT/tcp 才能从外面打开"
}

web_menu(){
  if systemctl is-active --quiet "$WEB_SVC" 2>/dev/null; then
    read -rp "面板运行中，关闭它？（输 yes）: " c
    [ "$c" = yes ] && web_disable || warn "未改动"
  else
    web_enable
  fi
}

# ================= 自检 =================
selfcheck(){
  echo "${BLD}--- 运行自检 ---${RST}"
  if systemctl is-active --quiet "$SVC"; then ok "$SVC active"; else echo "${RED}[X]${RST} $SVC 未运行"; fi
  if [ -x /usr/local/bin/xray ]; then
    local xv; xv=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')
    if [ "$xv" = "${XRAY_VER#v}" ]; then
      ok "专用 Xray 版本 $xv（两端必须一致）"
    else
      warn "专用 Xray 版本 $xv，期望 ${XRAY_VER#v} —— 重跑脚本会自动换成期望版本"
    fi
  fi

  if [ -f "$STATE/a.env" ]; then
    source "$STATE/a.env"
    echo "角色: ${BLD}A（入口端）${RST}   本机 IP: $A_IP   入口端口: ${USER_PORT:-443}   反代端口: $REVERSE_PORT"
    ss -ltn 2>/dev/null | grep -q ":${USER_PORT:-443} " && ok "入口端口 ${USER_PORT:-443} 监听中" || echo "${RED}[X]${RST} 入口端口 ${USER_PORT:-443} 未监听"
    ss -ltn 2>/dev/null | grep -q ":$REVERSE_PORT " && ok "反代口 $REVERSE_PORT 监听中" || echo "${RED}[X]${RST} 反代口未监听"

    # 节点 / 出口机 对应表（严格 1:1）
    if needs_migrate; then
      echo
      warn "配置还是旧的单出口结构（所有节点共一台 B）"
      warn "跑菜单 9 可以直接平滑升级（加/删节点时也会自动升），或跑：$0 --migrate"
    fi
    local rows nexit=0
    rows=$(list_exits 2>/dev/null || true)
    if [ -n "$rows" ]; then
      echo
      echo "${BLD}节点 / 出口机（1:1）${RST}"
      local n p u
      while IFS=$'\t' read -r n p u; do
        [ -z "$n" ] && continue
        if [ -z "$p" ]; then
          echo "    $n  ${RED}未绑定出口机→流量从 A 出网，泄露 A 的 IP${RST}"
        else
          echo "    $n  →  $p"
          nexit=$((nexit+1))
        fi
      done <<< "$rows"
    fi

    # 配置自检：xray -test 拦不住的错配（泄露 A IP / 标签重复 / 悬空引用）
    local vmsg
    if vmsg=$(validate_cfg "$CFG" 2>/dev/null); then
      ok "节点与出口绑定自检通过"
    else
      echo "${RED}[X]${RST} 配置自检发现问题："
      echo "$vmsg" | sed 's/^/    /'
    fi

    # 多出口下多条隧道是正常的，只有超出出口数才可疑（僵死连接）
    local ntun; ntun=$(ss -tn state established 2>/dev/null | grep -c ":$REVERSE_PORT")
    if [ "$ntun" = 0 ]; then
      warn "没有来自 B 的 ESTAB —— 出口机未部署或端口被封"
    else
      ok "反向隧道连接数：$ntun（已绑定出口：$nexit）"
      ss -tn state established 2>/dev/null | grep ":$REVERSE_PORT" | sed -n 1,5p | sed 's/^/    /'
      if [ "$nexit" -gt 0 ] && [ "$ntun" -lt "$nexit" ]; then
        warn "隧道数少于出口数 —— 有出口机没连上（未部署 / 安全组未放行 / 已关机）"
      fi
      if [ "$nexit" -gt 0 ] && [ "$ntun" -gt "$nexit" ]; then
        warn "隧道数多于出口数 —— 可能有僵死连接（某台 B 刚换过 IP）"
        warn "部分请求会挂死，等 ~20s 内核回收；若长期如此查：sysctl net.ipv4.tcp_retries2（应为 5）"
      fi
    fi
    local r2; r2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)
    [ "$r2" = 5 ] && ok "tcp_retries2=5（僵死隧道快速回收）" || warn "tcp_retries2=$r2，建议为 5"
    echo; info "逐个节点验收：连上后查出口 IP，必须等于${BLD}它对应那台出口机的实时公网 IP${RST}"
    info "如果显示的是 A 的 IP（$A_IP），说明该节点的流量没进 portal"
    info "如果两个节点查出同一个出口 IP，说明它们共用了出口，不是 1:1"
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
  read -rp "确认卸载 att-tunnel？（不影响你其他 xray 节点，输 yes）: " c
  [ "$c" = yes ] || { warn "已取消"; return; }
  systemctl stop "$WEB_SVC" 2>/dev/null || true
  systemctl disable "$WEB_SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WEB_SVC.service"
  systemctl stop "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC.service"
  systemctl daemon-reload 2>/dev/null || true
  local bdir="/root/att-tunnel-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$bdir"
  [ -f "$CFG" ] && cp "$CFG" "$bdir/" 2>/dev/null || true
  [ -d "$STATE" ] && cp -r "$STATE" "$bdir/" 2>/dev/null || true
  [ -d "$WEB_DATA" ] && cp -r "$WEB_DATA" "$bdir/" 2>/dev/null || true
  rm -rf "$STATE" "$CFG_DIR" "$WEB_DIR" "$WEB_DATA"
  ok "已停止并清理 att-tunnel。备份在：$bdir"
  ok "你机器上原有的 xray / 3x-ui / NodeLite 未受影响"
  warn "Xray 二进制未删除（可能其他服务在用）"
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
    echo "  4) 节点 / 出口机 对应表"
    echo "  5) 加一个节点（同时生成它专属出口机的部署命令）"
    echo "  6) 重新拿某节点的出口机部署命令"
    echo "  7) 删除一个节点（连带它的出口绑定）"
    echo "  8) 运行自检"
    echo "  9) 升级配置为 1:1 多出口结构（平滑，客户端不变）"
    echo " 10) SSH 搬到高位端口（可选，小心）"
    echo " 11) 卸载"
    echo " 12) 启用流量统计 / 出口探测（老 A 机升级，幂等）"
    echo " 13) 网页流量面板：开启 / 关闭"
    echo " 14) 查看网页面板地址和密码"
    echo "  0) 退出"
    echo
    read -rp "选择: " ch
    case "$ch" in
      1) deploy_a ;;
      2) read -rp "粘贴 A 端给的 token: " t; deploy_b "$t" ;;
      3) show_links ;;
      4) show_exits ;;
      5) add_node ;;
      6) show_exit_cmd ;;
      7) del_node ;;
      8) selfcheck ;;
      9) migrate_menu ;;
      10) ssh_migrate ;;
      11) uninstall ;;
      12) enable_stats ;;
      13) web_menu ;;
      14) web_info ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# 生成给 B 的命令用哪个脚本地址；测试分支/指定提交时用 ATT_RAW_URL 覆盖
RAW_URL="${ATT_RAW_URL:-https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh}"

case "${1:-}" in
  --bridge)   need_root; deploy_b "${2:-}" ;;
  --server-a) deploy_a ;;
  --check)    selfcheck ;;
  --links)    show_links ;;
  --add)      add_node "${2:-}" ;;
  --del|--delete|--remove) del_node "${2:-}" ;;
  --list)     show_exits ;;
  --exit-cmd) show_exit_cmd "${2:-}" ;;
  --migrate)  migrate_cfg ;;
  --enable-stats) enable_stats ;;
  --web)      web_enable ;;
  --web-off)  web_disable ;;
  --web-info) web_info ;;
  --version)  echo "att-tunnel v$VERSION" ;;
  "")         menu ;;
  *)          die "未知参数: $1（可用：--server-a | --bridge TOKEN | --check | --links | --list | --add NAME | --del NAME | --exit-cmd NAME | --migrate | --enable-stats | --web | --web-off | --web-info）" ;;
esac
