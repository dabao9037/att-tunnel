#!/usr/bin/env bash
# att-tunnel — AT&T 线路丢包根治：Xray VLESS Reverse 反向隧道一键部署
# 不绑域名，B 端直连 A 的公网 IP；B 换 IP 自动重连。
set -Eeuo pipefail
# head 提前关管道会让上游收到 SIGPIPE(141)，配合 pipefail+set -e 会静默退出。
# 下面统一用 sed -n / awk NR 代替 head；再加个 ERR 提示，万一意外退出至少知道是哪一行。
trap 'rc=$?; echo "[X] 脚本在第 $LINENO 行意外退出 (rc=$rc)" >&2' ERR

VERSION="2.5.3"
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

# 非交互模式（网页面板调用 / 自动化）：ATT_NONINTERACTIVE=1，所有 read 改用环境变量或默认值
noninteractive(){ [ "${ATT_NONINTERACTIVE:-0}" = 1 ]; }

# 改配置的操作全局串行：面板和终端同时加/删节点时，后来者等最多 120 秒
cfg_lock(){
  [ -n "${ATT_CFG_LOCKED:-}" ] && return 0
  mkdir -p /run/lock 2>/dev/null || true
  exec 9>/run/lock/att-tunnel.lock
  flock -w 120 9 || die "另一个加/删节点操作正在进行，请稍后再试"
  ATT_CFG_LOCKED=1
}

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
# 与 NodeLite 的 config/reality-targets.json 保持完全同步（2026-10-27：14 个）。
# 2026-10-27 复测新增的 hkstp / visitdubai / dm.gov.ae 均通过 TLS 1.3、HTTP/2、
# 证书匹配；部署时仍会逐个实测，不通的自动跳过。
# 伪装域名列表：域名 | 国家/地区
CANDIDATES_WITH_COUNTRY=(
  "www.atlasobscura.com|美国"
  "www.backblaze.com|美国"
  "www.skao.int|英国"
  "www.sciencemuseum.org.uk|英国"
  "www.4gamer.net|日本"
  "www.famitsu.com|日本"
  "www.a-star.edu.sg|新加坡"
  "www.visitsingapore.com|新加坡"
  "www.fraunhofer.de|德国"
  "www.gog.com|波兰"
  "www.hkstp.org|中国香港"
  "www.discoverhongkong.com|中国香港"
  "www.visitdubai.com|阿联酋"
  "www.dm.gov.ae|阿联酋"
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
  local wg_after=""
  if [ -s "$WG_STATE" ] || grep -q 'wgx-' "$CFG" 2>/dev/null; then
    wg_after=$'\nAfter=wg-quick@attwg.service\nWants=wg-quick@attwg.service'
  fi
  cat > "/etc/systemd/system/$SVC.service" <<EOF
[Unit]
Description=att-tunnel (Xray VLESS Reverse)
After=network-online.target$wg_after
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
# 同时开 BBR：A↔B 是一条长 TCP 隧道，跨国线路偶发丢包时 cubic 会把窗口砍半、掉速很久，
# BBR 按带宽和 RTT 估算发送速率，丢包时掉速小得多。内核 4.9+ 才有；不支持就跳过，不影响隧道。
bbr_supported(){
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
  modprobe tcp_bbr >/dev/null 2>&1 || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

tune_tcp(){
  local f=/etc/sysctl.d/99-att-tunnel.conf bbr=0
  bbr_supported && bbr=1
  {
    echo "# att-tunnel: 快速回收死掉的反向隧道连接（B 换 IP / 断网场景）"
    echo "net.ipv4.tcp_retries2 = 5"
    if [ "$bbr" = 1 ]; then
      echo "# att-tunnel: BBR 拥塞控制 + fq 队列（丢包时不像 cubic 那样大幅掉速）"
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo "net.core.rmem_max = 16777216"
    echo "net.core.wmem_max = 16777216"
    echo "net.ipv4.tcp_rmem = 4096 87380 16777216"
    echo "net.ipv4.tcp_wmem = 4096 65536 16777216"
    echo "net.core.netdev_max_backlog = 16384"
  } > "$f"
  # 开机自动加载 bbr 模块（编进内核的不需要，写了也无害）
  [ "$bbr" = 1 ] && [ -d /etc/modules-load.d ] && echo tcp_bbr > /etc/modules-load.d/att-tunnel-bbr.conf
  # 逐项生效：容器里 default_qdisc 可能不让改，不能连累其它项
  sysctl -w net.ipv4.tcp_retries2=5 >/dev/null 2>&1 && ok "已调优 tcp_retries2=5（僵死隧道 ~20s 回收）" \
    || warn "sysctl 应用失败，僵死连接回收会变慢"
  if [ "$bbr" = 1 ]; then
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
      ok "已开启 BBR（新建连接生效；隧道下次重连起用 BBR）"
    else
      warn "BBR 设置失败（容器 / 受限内核），沿用 $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    fi
  else
    warn "内核不支持 BBR（$(uname -r)），沿用 $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  fi
  for kv in net.ipv4.tcp_slow_start_after_idle=0 net.ipv4.tcp_mtu_probing=1 \
            net.core.rmem_max=16777216 net.core.wmem_max=16777216 \
            net.core.netdev_max_backlog=16384; do
    sysctl -w "$kv" >/dev/null 2>&1 || true
  done
}

# 老机器单独补调优（不重装、不动配置和节点）：--tune
tune_only(){
  need_root
  tune_tcp
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [ "$cc" = bbr ] && systemctl is-active --quiet "$SVC" && [ -f "$STATE/b.env" ]; then
    # 隧道是 B 拨出去的长连接，建连时定下拥塞算法；重启让它立刻换成 BBR，断几秒自动重连
    if noninteractive || [ "${ATT_YES:-}" = 1 ]; then
      systemctl restart "$SVC" && ok "已重启 $SVC，隧道已用 BBR 重连"
    else
      read -rp "重启 $SVC 让现有隧道立刻改用 BBR？会断几秒 [y/N]: " yn
      case "$yn" in [yY]*) systemctl restart "$SVC" && ok "已重启 $SVC，隧道已用 BBR 重连" ;; *) info "不重启：隧道下次重连时自动用 BBR" ;; esac
    fi
  fi
}

open_fw(){
  local p="$1" pr="${2:-tcp}" done_any=0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$p/$pr" >/dev/null 2>&1 && { ok "ufw 已放行 $p/$pr"; done_any=1; }
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/$pr" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && { ok "firewalld 已放行 $p/$pr"; done_any=1; }
  fi
  # 很多 VPS 没有 ufw/firewalld，但 iptables INPUT 默认 DROP 或有拦截规则。
  # 上一版只看 ufw/firewalld，所以反代端口实际被 iptables 拦掉。
  if command -v iptables >/dev/null 2>&1; then
    local pol; pol=$(iptables -L INPUT -n 2>/dev/null | sed -n 1p)
    if echo "$pol" | grep -q 'policy DROP' || iptables -L INPUT -n 2>/dev/null | grep -qE '^(DROP|REJECT)'; then
      if ! iptables -C INPUT -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null \
          && { ok "iptables 已放行 $p/$pr"; done_any=1; }
      else
        ok "iptables 已有 $p/$pr 放行规则"; done_any=1
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
  warn "❗ 云厂商安全组需你自己在控制台放行 $p/$pr（脚本改不了）"
}

# ================= WireGuard 出口（可选，加节点时逐个选） =================
# 方向和 VLESS 反向一样：落地机（B）主动拨 A 的 UDP 口 + PersistentKeepalive，B 照样零公网入站。
#   A：一个接口 attwg（随机 UDP 端口），每个 WG 节点一个 peer、一个隧道 IP（/32），严格 1:1。
#   B：wg 只认 A 这一个 peer；B 上的 Xray 只在自己的隧道 IP 上听一个 VLESS 口。
#   A 的 Xray：user:[节点] -> outbound wgx-<节点>（VLESS 到 B 的隧道 IP），流量从 B 出网。
# 和 VLESS 反向的区别：用户的每条连接各自一条 TCP（跑在 WG/UDP 里），不挤在一条长 TCP 隧道里，
# 线路丢包时不会一条卡住全部。分享链接、订阅、出口探测、流量统计和反向节点完全一样。
# 状态：A 端 $STATE/wg.json（密钥、端口、每个节点的 peer），/etc/wireguard/attwg.conf 由它生成。
WG_IF="attwg"
WG_CONF="/etc/wireguard/$WG_IF.conf"
WG_STATE="$STATE/wg.json"
WG_DROPIN="/etc/systemd/system/$SVC.service.d/10-att-wg.conf"

wg_tools(){
  command -v wg >/dev/null && command -v wg-quick >/dev/null && return 0
  info "安装 wireguard-tools ..."
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends wireguard-tools >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 \
           && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends wireguard-tools >/dev/null 2>&1; } \
      || true
  elif command -v dnf >/dev/null; then dnf install -y -q wireguard-tools >/dev/null 2>&1 || true
  elif command -v yum >/dev/null; then yum install -y -q wireguard-tools >/dev/null 2>&1 || true
  fi
  command -v wg >/dev/null && command -v wg-quick >/dev/null
}

# 内核能不能建 wireguard 接口（5.6+ 自带；OpenVZ / LXC 容器一般不行）
wg_kmod(){
  modprobe wireguard >/dev/null 2>&1 || true
  ip link del attwg-chk >/dev/null 2>&1 || true
  ip link add attwg-chk type wireguard >/dev/null 2>&1 || return 1
  ip link del attwg-chk >/dev/null 2>&1 || true
}

wg_require(){
  wg_tools || die "wireguard-tools 装不上（apt/dnf/yum 都失败），这个节点请改用 VLESS 反向"
  wg_kmod || die "本机内核不支持 WireGuard（OpenVZ/LXC 容器常见），这个节点请改用 VLESS 反向"
}

free_udp_port(){
  local p
  while :; do
    p=$(( RANDOM % 40000 + 20000 ))
    ss -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" || { echo "$p"; return; }
  done
}

# A 端 wg.json 的读写。密钥一律走环境变量（WG_PRIV/WG_PUB/WGP_*），不进命令行。
#   init PORT NET | alloc NAME [保留节点...] | put NAME IP [保留节点...] | del NAME
#   get KEY | get NAME KEY | conf（输出 attwg.conf）
wg_state(){
  ATT_WG_STATE="$WG_STATE" python3 - "$@" <<'PY'
import ipaddress,json,os,sys
f=os.environ['ATT_WG_STATE']; a=sys.argv[1:]; act=a[0]; E=os.environ.get
def load():
    with open(f) as h: return json.load(h)
def save(d):
    tmp=f+'.tmp'
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as h: json.dump(d,h,indent=1)
    os.replace(tmp,f)
if act=='init':
    save({'port':int(a[1]),'net':a[2],'mtu':int(a[3]) if len(a)>3 else 1380,
          'priv':E('WG_PRIV'),'pub':E('WG_PUB'),'peers':{}})
elif act=='alloc':
    # 给 NAME 挑隧道 IP；不在保留列表里的残留 peer（加节点中途失败留下的）不占位
    d=load(); name=a[1]; keep=set(a[2:])
    used={p['ip'] for n,p in d['peers'].items() if n in keep and n!=name}
    for i in range(2,255):
        ip='%s.%d'%(d['net'],i)
        if ip not in used:
            print(ip); break
    else:
        sys.exit('FULL')
elif act=='put':
    d=load(); name,ip=a[1],a[2]; keep=set(a[3:])|{name}
    d['peers']={n:p for n,p in d['peers'].items() if n in keep}
    d['peers'][name]={'ip':ip,'xport':int(E('WGP_XPORT')),'priv':E('WGP_PRIV'),'pub':E('WGP_PUB'),
                      'psk':E('WGP_PSK'),'uuid':E('WGP_UUID')}
    save(d)
elif act=='del':
    d=load(); d['peers'].pop(a[1],None); save(d)
elif act=='get':
    d=load()
    if len(a)==2 and a[1]=='mtu':
        v=d.get('mtu',1380)
    else:
        v=d.get(a[1]) if len(a)==2 else (d['peers'].get(a[1]) or {}).get(a[2])
    if v is None or isinstance(v,dict): sys.exit(1)
    print(v)
elif act=='conf':
    d=load()
    out=['# att-tunnel 生成，别手改：以 %s 为准，加/删 WireGuard 节点时重写'%f,
         '[Interface]','Address = %s.1/24'%d['net'],'ListenPort = %d'%d['port'],
         'PrivateKey = %s'%d['priv'],'MTU = %d'%d.get('mtu',1380)]
    for n,p in sorted(d['peers'].items(), key=lambda x: ipaddress.ip_address(x[1]['ip'])):
        out+=['','# node: %s'%n,'[Peer]','PublicKey = %s'%p['pub'],'PresharedKey = %s'%p['psk'],
              'AllowedIPs = %s/32'%p['ip']]
    print('\n'.join(out))
else:
    sys.exit('bad action')
PY
}

# 按 wg.json 重写 attwg.conf 并生效：接口已在就 syncconf 热更新（不断其它落地机），不在就拉起
wg_apply(){
  mkdir -p /etc/wireguard; chmod 700 /etc/wireguard
  local tmp; tmp=$(mktemp)
  wg_state conf > "$tmp" || { rm -f "$tmp"; die "生成 WireGuard 配置失败"; }
  install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
  local mtu; mtu=$(wg_state get mtu 2>/dev/null || echo 1380)
  systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1 || true
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_CONF") || die "WireGuard 配置热更新失败"
  else
    systemctl restart "wg-quick@$WG_IF" || {
      journalctl -u "wg-quick@$WG_IF" -n 10 --no-pager 2>&1 | tail -8
      die "WireGuard 接口 $WG_IF 起不来"; }
  fi
  ip link set dev "$WG_IF" mtu "$mtu" >/dev/null 2>&1 || warn "WireGuard MTU 设置失败（$mtu）"
  ip link show "$WG_IF" >/dev/null 2>&1 || die "WireGuard 接口 $WG_IF 没起来"
}

# A 端：第一次加 WireGuard 节点时初始化（密钥 + 随机 UDP 口），之后只确保接口在
wg_server_ensure(){
  wg_require
  if [ ! -s "$WG_STATE" ]; then
    local port="${ATT_WG_PORT:-}" net="${ATT_WG_NET:-10.77.0}" mtu="${ATT_WG_MTU:-1380}" priv pub
    [ -n "$port" ] || port=$(free_udp_port)
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "ATT_WG_PORT 不对：$port"
    [[ "$net" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "ATT_WG_NET 要写成三段，如 10.77.0"
    [[ "$mtu" =~ ^[0-9]{4}$ ]] && [ "$mtu" -ge 1280 ] && [ "$mtu" -le 1420 ] || die "ATT_WG_MTU 不对：$mtu（1280-1420）"
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    mkdir -p "$STATE"
    WG_PRIV="$priv" WG_PUB="$pub" wg_state init "$port" "$net" "$mtu"
    ok "WireGuard 已初始化：UDP $port，隧道网段 $net.0/24"
  fi
  wg_apply
  open_fw "$(wg_state get port)" udp || true
}

# 打印某个 WireGuard 节点的落地机部署命令（token 含落地机私钥，等同隧道密钥）
print_wg_cmd(){
  local name="$1"
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  [ -s "$WG_STATE" ] || die "本机还没有 WireGuard 节点"
  local ip; ip=$(wg_state get "$name" ip) || die "WireGuard 里没有节点 $name 的记录（跑菜单 8 自检）"
  local token
  token=$(printf 'wg2|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$A_IP" "$(wg_state get port)" "$(wg_state get pub)" \
    "$(wg_state get "$name" priv)" "$(wg_state get "$name" psk)" "$ip" "$(wg_state get net).1" \
    "$(wg_state get "$name" xport)" "$(wg_state get "$name" uuid)" \
    "$(wg_state get mtu)" "${ATT_WG_KEEPALIVE:-15}" | base64 -w0)
  echo
  echo "${BLD}到这个节点的落地机${name:+（$name，WireGuard）}上执行：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL $RAW_URL) --wg-bridge $token${RST}"
  echo
  echo "${YEL}这串 token 含 WireGuard 私钥，只在你自己两台机器间使用，不要外发。${RST}"
}

# 落地机从 WireGuard 改回 VLESS 反向：只停/移走 att-tunnel 自己的 attwg，不碰别的 wg 接口
wg_b_off(){
  if [ -f "$WG_CONF" ] && grep -q '^# att-tunnel' "$WG_CONF" 2>/dev/null; then
    systemctl disable --now "wg-quick@$WG_IF" >/dev/null 2>&1 || true
    mv "$WG_CONF" "$WG_CONF.bak-$(date +%Y%m%d%H%M%S)"
    ok "已停用本机原来的 WireGuard 出口（$WG_IF）"
  fi
  rm -f "$WG_DROPIN"
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
  # WireGuard 出口的 token（菜单 2 粘贴时自动识别）
  case "$dec" in wg1\|*) deploy_wg_b "$token"; return ;; esac
  IFS='|' read -r aip rport buuid enc tstyle <<<"$dec"
  [ -n "$aip" ] && [ -n "$rport" ] && [ -n "$buuid" ] && [ -n "$enc" ] || die "token 内容不完整"

  install_deps; install_xray
  # 这台落地机之前若是 WireGuard 出口，先停掉它自己的 attwg
  wg_b_off

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

# ================= 服务器 B：WireGuard 出口 =================
# token = base64(wg2|A公网IP|A的UDP口|A公钥|B私钥|预共享密钥|B隧道IP|A隧道IP|B的Xray口|uuid|MTU|Keepalive)
# 兼容旧 wg1 token（无 MTU/keepalive 字段，自动用默认值）
# B 主动拨 A（PersistentKeepalive），公网零入站；Xray 只听在自己的隧道 IP 上，WG 只认 A 一个 peer。
deploy_wg_b(){
  need_root
  local token="${1:-}"
  [ -n "$token" ] || die "缺少 token，请用 A 端输出的完整命令"
  [ -f "$STATE/a.env" ] && die "本机是 A 端（入口机），不能同时当落地机"
  local dec ver aip wport apub bpriv psk bip ain xport uuid wg_mtu wg_keepalive
  dec=$(printf '%s' "$token" | base64 -d 2>/dev/null) || die "token 解析失败"
  IFS='|' read -r ver aip wport apub bpriv psk bip ain xport uuid wg_mtu wg_keepalive <<<"$dec"
  [ "$ver" = wg1 ] || [ "$ver" = wg2 ] || die "这不是 WireGuard 出口的 token（VLESS 反向用 --bridge）"
  wg_mtu="${wg_mtu:-1380}"; wg_keepalive="${wg_keepalive:-15}"
  [[ "$wg_mtu" =~ ^[0-9]{4}$ ]] && [ "$wg_mtu" -ge 1280 ] && [ "$wg_mtu" -le 1420 ] \
    || die "token 里的 WG MTU 不对：$wg_mtu（1280-1420）"
  [[ "$wg_keepalive" =~ ^[0-9]{1,2}$ ]] && [ "$wg_keepalive" -ge 5 ] && [ "$wg_keepalive" -le 60 ] \
    || die "token 里的 WG keepalive 不对：$wg_keepalive（5-60）"
  local k='^[A-Za-z0-9+/]{43}=$' i4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
  [[ "$aip" =~ ^[A-Za-z0-9.:-]{2,253}$ ]] && [[ "$wport" =~ ^[0-9]{1,5}$ ]] && [[ "$xport" =~ ^[0-9]{1,5}$ ]] \
    && [[ "$apub" =~ $k ]] && [[ "$bpriv" =~ $k ]] && [[ "$psk" =~ $k ]] \
    && [[ "$bip" =~ $i4 ]] && [[ "$ain" =~ $i4 ]] && [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] \
    || die "token 内容不完整或格式不对"

  install_deps; install_xray; wg_require
  info "将用 WireGuard 主动拨向 A: $aip:$wport/udp（本机隧道 IP $bip）"

  mkdir -p /etc/wireguard; chmod 700 /etc/wireguard
  if [ -f "$WG_CONF" ] && ! grep -q '^# att-tunnel' "$WG_CONF"; then
    die "$WG_CONF 已存在且不是 att-tunnel 生成的，没动它"
  fi
  local ep="$aip"; [[ "$aip" == *:* ]] && ep="[$aip]"
  local wtmp; wtmp=$(mktemp)
  cat > "$wtmp" <<EOF
# att-tunnel 落地机（WireGuard 出口），由 --wg-bridge 生成，重跑会覆盖
[Interface]
Address = $bip/32
PrivateKey = $bpriv
MTU = $wg_mtu

[Peer]
PublicKey = $apub
PresharedKey = $psk
Endpoint = $ep:$wport
AllowedIPs = $ain/32
PersistentKeepalive = $wg_keepalive
EOF
  install -m 600 "$wtmp" "$WG_CONF"; rm -f "$wtmp"
  systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@$WG_IF" || {
    journalctl -u "wg-quick@$WG_IF" -n 10 --no-pager 2>&1 | tail -8
    die "WireGuard 接口 $WG_IF 起不来"; }
  # Xray 要听在隧道 IP 上：开机时必须等 attwg 起来再启动
  mkdir -p "$(dirname "$WG_DROPIN")"
  printf '[Unit]\nBindsTo=wg-quick@%s.service\nAfter=wg-quick@%s.service\nWants=wg-quick@%s.service\n' "$WG_IF" "$WG_IF" "$WG_IF" > "$WG_DROPIN"

  local tmp; tmp=$(mktemp --suffix=.json)
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "wg-in",
      "listen": "$bip",
      "port": $xport,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$uuid", "email": "wg" } ], "decryption": "none" },
      "streamSettings": { "network": "raw", "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 12000 } }
    }
  ],
  "outbounds": [
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
  ]
}
EOF
  apply_cfg "$tmp"
  tune_tcp
  # INPUT 默认 DROP 的机器：放行从隧道进来的这一个端口（只认 attwg 接口，公网照样扫不到）
  if command -v iptables >/dev/null 2>&1 && { iptables -L INPUT -n 2>/dev/null | sed -n 1p | grep -q 'policy DROP' \
       || iptables -L INPUT -n 2>/dev/null | grep -qE '^(DROP|REJECT)'; }; then
    iptables -C INPUT -i "$WG_IF" -p tcp --dport "$xport" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 1 -i "$WG_IF" -p tcp --dport "$xport" -j ACCEPT 2>/dev/null || true
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ]; then iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; fi
  fi

  mkdir -p "$STATE"
  printf 'ROLE=B\nKIND=wg\nA_IP=%s\nWG_PORT=%s\nTUN_IP=%s\n' "$aip" "$wport" "$bip" > "$STATE/b.env"
  chmod 600 "$STATE/b.env"

  echo
  info "等待 WireGuard 握手 ..."
  local i hs=0
  for i in $(seq 1 15); do
    hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2}' | sed -n 1p) || hs=0
    [ "${hs:-0}" -gt 0 ] 2>/dev/null && break
    sleep 2
  done
  echo
  echo "${BLD}=========== 落地机（WireGuard 出口）部署完成 ===========${RST}"
  if [ "${hs:-0}" -gt 0 ] 2>/dev/null; then
    ok "WireGuard 已握手（B → A $aip:$wport/udp）"
  else
    echo "${YEL}${BLD}⚠ WireGuard 还没握手${RST}"
    echo "本机会每 15 秒重试。最常见的原因：${BLD}A 机的 $wport/udp 没对外开放${RST}"
    echo "去 A 机的云厂商安全组放行 ${BLD}$wport/udp${RST}（入方向），放行后不用重跑。"
    echo "确认方法：${CYN}wg show $WG_IF latest-handshakes${RST}（第二列不是 0 就通了）"
  fi
  echo
  ok "落地机公网无入站监听（Xray 只听在隧道 IP $bip 上）"
  ok "落地机换 IP 无需任何操作，WireGuard 会自动重拨"
}

# ================= 节点 / 出口机 管理 =================
# 架构：一个节点 = 一台出口机 = 一个 portal 标签（严格 1:1）
#   A 端 reverse-in 挂多个 bridge client，每个带自己的 reverse.tag
#   路由一节点一条规则：user:[nodeX] -> portal-nodeX
# B 端无需任何改动：它只认 token 里的 uuid，一台 B 一个 uuid 天然分开，
# 多台 B 复用同一个反代端口没问题。

# 输出：节点名 <TAB> 出口标签 <TAB> 出口uuid（一行一个节点）
# 出口标签：portal-<节点> = VLESS 反向；wgx-<节点> = WireGuard
# 出口标签或 uuid 为空 = 该节点没有绑定出口机
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
# WireGuard 出口：outbound wgx-<节点>（VLESS 到落地机的隧道 IP），uuid 在 settings.id
for ob in d.get('outbounds',[]):
    t=str(ob.get('tag',''))
    if t.startswith('wgx-'):
        st=ob.get('settings') or {}
        bridges[t]=st.get('id') or ((st.get('vnext') or [{}])[0].get('users') or [{}])[0].get('id','')
node2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # probe-in 的探测规则（user=probe-<节点>）不是节点规则
    if (ot.startswith('portal') or ot.startswith('wgx-')) and 'probe-in' not in (r.get('inboundTag') or []):
        for u in r.get('user',[]):
            node2portal[u]=ot
for ib in d.get('inbounds',[]):
    # user-in = 主入口；user-in-<端口> = 加节点时指定了别的端口/伪装域名生成的独立入口
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
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
wg_tags=[str(o.get('tag','')) for o in d.get('outbounds',[]) if str(o.get('tag','')).startswith('wgx-')]
for t in sorted({t for t in wg_tags if wg_tags.count(t)>1}):
    err.append('WireGuard 出口标签重复: %s'%t)
exit_tags=set(bridge_tags)|set(wg_tags)
def is_exit(t): return t.startswith('portal') or t.startswith('wgx-')

nodes=[]
ports={}
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
        p=ib.get('port')
        if p in ports:
            err.append('入口端口 %s 被 %s 和 %s 重复使用'%(p,ports[p],ib.get('tag')))
        ports[p]=ib.get('tag')
        for c in ib.get('settings',{}).get('clients',[]):
            nodes.append(c.get('email','node'))
for n in sorted({n for n in nodes if nodes.count(n)>1}):
    err.append('节点名重复: %s'%n)

node2portal={}
probe2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 按 inboundTag 区分：probe-in 的是出口探测规则（user=probe-<节点>），单独校验
    if 'probe-in' in (r.get('inboundTag') or []):
        if is_exit(ot) and ot not in exit_tags:
            err.append('探测路由指向不存在的出口标签: %s'%ot)
        for u in r.get('user',[]):
            probe2portal[u]=ot
        continue
    if not is_exit(ot):
        continue
    if ot not in exit_tags:
        err.append('路由指向不存在的出口标签: %s'%ot)
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

# show_links [NAME]：不带参数列出全部；带 NAME 只输出该节点的一行 vless 链接
show_links(){
  local only="${1:-}" found=0
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  [ -n "$only" ] || echo "${BLD}--- 客户端分享链接 ---${RST}"
  local epath; epath=$(printf '%s' "$XPATH" | sed 's|/|%2F|g')
  local tr="${TRANSPORT:-xhttp}"
  local uport="${USER_PORT:-443}"
  local rows; rows=$(list_exits 2>/dev/null || true)
  local n uuid fl qs np ns
  # flow 由每个用户自己的配置决定，不能一刀切；端口 / 伪装域名按节点所在入站（user-in 或 user-in-<端口>）
  while read -r n uuid fl np ns; do
    [ -z "$n" ] && continue
    [ "$fl" = "-" ] && fl=""
    [ -n "${only:-}" ] && [ "$n" != "$only" ] && continue
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
      case "$ptag" in wgx-*) tip="  出口：${CYN}$ptag${RST}（WireGuard）" ;; *) tip="  出口：${CYN}$ptag${RST}" ;; esac
    fi
    local link="vless://$uuid@$A_IP:${np:-$uport}?encryption=none&security=reality&$qs&sni=${ns:-$SNI}&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID#$n"
    # --link NAME：只输出这一条链接（给面板用）
    if [ -n "${only:-}" ]; then echo "$link"; found=1; continue; fi
    echo
    echo "${CYN}[$n]${RST}$tip"
    echo "$link"
  done < <("$XRAY_BIN" -test -config "$CFG" >/dev/null 2>&1 && ATT_CFG="$CFG" python3 - <<'PY'
import json,os
d=json.load(open(os.environ['ATT_CFG']))
for ib in d['inbounds']:
    t=str(ib.get('tag',''))
    if t=='user-in' or t.startswith('user-in-'):
        rs=(ib.get('streamSettings') or {}).get('realitySettings') or {}
        sni=(rs.get('serverNames') or [''])[0]
        for c in ib['settings']['clients']:
            print(c.get('email','node'), c['id'], c.get('flow','') or '-', ib.get('port',''), sni)
PY
)
  if [ -n "${only:-}" ]; then
    [ "${found:-0}" = 1 ] || die "节点 $only 不存在"
    return 0
  fi
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
  cfg_lock
  local name="${1:-}"
  if [ -z "$name" ] && ! noninteractive; then read -rp "节点名称（如 node2）: " name; fi
  [ -n "$name" ] || die "名称不能为空"
  # 节点名会拼进 portal 标签和分享链接，限制字符集（网页面板用同一条规则）
  printf '%s' "$name" | grep -qE '^[A-Za-z0-9_-]{1,32}$' \
    || die "名称只能用字母/数字/下划线/连字符，最多 32 位"
  list_nodes 2>/dev/null | grep -qxF "$name" && die "节点 $name 已存在（原配置未改动）"

  # 出口方式：ATT_NODE_KIND=reverse（VLESS 反向，默认）| wg（WireGuard）
  local kind="${ATT_NODE_KIND:-}"
  if [ -z "$kind" ] && ! noninteractive; then
    echo "出口方式："
    echo "  1) VLESS 反向（默认，落地机经一条 TCP 长连接拨入）"
    echo "  2) WireGuard（落地机经 UDP 拨入，每条连接各走各的，线路丢包时不互相拖累）"
    read -rp "选择 [1]: " kind
  fi
  case "${kind:-1}" in
    1|reverse|vless) kind=reverse ;;
    2|wg|wireguard)  kind=wg ;;
    *) die "出口方式只能是 reverse 或 wg：$kind" ;;
  esac
  [ "$kind" = wg ] && [ "${REVERSE_STYLE:-new}" != new ] && die "本机 Xray 是旧版 reverse 语法，WireGuard 出口不可用，请改用 VLESS 反向"

  # 入口端口：ATT_NODE_PORT > 交互输入 > 主入口端口
  local uport="${ATT_NODE_PORT:-}"
  if [ -z "$uport" ] && ! noninteractive; then
    read -rp "为这个节点指定入口端口（回车使用已有的 ${USER_PORT:-443}）: " uport
  fi
  [ -n "$uport" ] || uport="${USER_PORT:-443}"
  case "$uport" in (*[!0-9]*) die "端口必须是数字";; esac
  [ "$uport" -ge 1 ] && [ "$uport" -le 65535 ] || die "端口越界（1-65535）"
  uport=$((10#$uport))

  # 伪装域名：只有单独端口的新入口才能自定义；共用已有入口时沿用它的域名
  local nsni="${ATT_NODE_SNI:-}" existing=""
  existing=$(ATT_CFG="$CFG" P="$uport" python3 -c '
import json,os
d=json.load(open(os.environ["ATT_CFG"]))
for ib in d.get("inbounds",[]):
    t=str(ib.get("tag",""))
    if (t=="user-in" or t.startswith("user-in-")) and str(ib.get("port"))==os.environ["P"]:
        rs=(ib.get("streamSettings") or {}).get("realitySettings") or {}
        print((rs.get("serverNames") or ["?"])[0]); break')
  if [ -n "$existing" ]; then
    if [ -n "$nsni" ] && [ "$nsni" != "$existing" ]; then
      warn "端口 $uport 已有入口，伪装域名沿用它的 $existing（忽略 $nsni）"
    fi
    nsni="$existing"
  else
    [ "$uport" = "${REVERSE_PORT:-}" ] && die "端口 $uport 是反代隧道端口，不能当入口"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$uport\$"; then
      die "端口 $uport 已被占用（原配置未改动）"
    fi
    if [ -z "$nsni" ] && ! noninteractive; then
      read -rp "伪装域名（回车沿用主入口的 $SNI；输 list 从预置列表选；或直接输入域名）: " nsni
      if [ "$nsni" = list ]; then pick_sni_interactive || die "没有可用的伪装域名"; nsni="$SNI_PICKED"; fi
    fi
    [ -n "$nsni" ] || nsni="$SNI"
    printf '%s' "$nsni" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' \
      || die "伪装域名格式不对：$nsni"
    if [ "$nsni" != "$SNI" ]; then
      info "实测 $nsni 的 TLS 1.3 ..."
      sni_ok "$nsni" || die "伪装域名 $nsni 不支持 TLS 1.3 或连不上（原配置未改动）"
    fi
    info "节点 $name 将使用单独入口：端口 $uport，伪装域名 $nsni"
  fi

  local uuid buuid
  uuid=$("$XRAY_BIN" uuid)    # 客户端用
  buuid=$("$XRAY_BIN" uuid)   # 这个节点专属出口机用

  # WireGuard：先确保 A 端 attwg 接口在，再给这个节点分一个隧道 IP 和落地机上的 Xray 端口
  local wgip="" wgx=""
  if [ "$kind" = wg ]; then
    wg_server_ensure
    # shellcheck disable=SC2046
    wgip=$(wg_state alloc "$name" $(list_nodes 2>/dev/null)) || die "WireGuard 隧道 IP 已用完（最多 253 个节点）"
    wgx=$(( RANDOM % 40000 + 20000 ))
  fi

  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  NEW_NAME="$name" NEW_UUID="$uuid" NEW_BUUID="$buuid" NEW_PORT="$uport" NEW_SNI="$nsni" \
    NEW_KIND="$kind" NEW_WGIP="$wgip" NEW_WGX="$wgx" \
    ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import copy,json,os
d=json.load(open(os.environ['ATT_CFG']))
name=os.environ['NEW_NAME']
uuid=os.environ['NEW_UUID']; buuid=os.environ['NEW_BUUID']
port=int(os.environ['NEW_PORT']); sni=os.environ['NEW_SNI']
kind=os.environ.get('NEW_KIND','reverse')
ptag=('wgx-%s' if kind=='wg' else 'portal-%s')%name
def is_ui(ib):
    t=str(ib.get('tag',''))
    return t=='user-in' or t.startswith('user-in-')
uis=[ib for ib in d['inbounds'] if is_ui(ib)]
main=[ib for ib in uis if ib.get('tag')=='user-in']
if not main:
    raise SystemExit('NOMAIN')
main=main[0]
for ib in uis:
    if any(c.get('email')==name for c in ib['settings']['clients']):
        raise SystemExit('DUP')

# raw 模式必带 Vision（抗封）；xhttp 不支持 flow
vision=(main.get('streamSettings') or {}).get('network')=='raw'
c={'id':uuid,'email':name}
if vision:
    c['flow']='xtls-rprx-vision'

# 节点放进同端口的入口；该端口还没有入口时，按主入口克隆一个 user-in-<端口>
# （同一套 REALITY 密钥 / shortId，只换端口和伪装域名）
tgt=[ib for ib in uis if ib.get('port')==port]
if tgt:
    tgt[0]['settings']['clients'].append(c)
else:
    ib=copy.deepcopy(main)
    ib['tag']='user-in-%d'%port
    ib['port']=port
    ib['settings']['clients']=[c]
    rs=(ib.get('streamSettings') or {}).get('realitySettings')
    if rs is not None:
        rs['serverNames']=[sni]
        if 'target' in rs: rs['target']='%s:443'%sni
        if 'dest' in rs: rs['dest']='%s:443'%sni
    d['inbounds'].insert(d['inbounds'].index(uis[-1])+1, ib)

if kind=='wg':
    # WireGuard：一个专属出站，VLESS 到落地机的隧道 IP（WG 已加密，这层不再加密）
    obs=d.setdefault('outbounds',[])
    if any(o.get('tag')==ptag for o in obs):
        raise SystemExit('DUPTAG')
    obs.append({'tag':ptag,'protocol':'vless',
                'settings':{'address':os.environ['NEW_WGIP'],'port':int(os.environ['NEW_WGX']),
                            'id':buuid,'encryption':'none'},
                'streamSettings':{'network':'raw','sockopt':{'tcpKeepAliveInterval':10,'tcpKeepAliveIdle':30,'tcpUserTimeout':12000}}})
else:
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
  [ "$uport" = "${USER_PORT:-443}" ] || open_fw "$uport" 2>/dev/null || true
  if [ "$kind" = wg ]; then
    # 节点进了 xray 配置之后再加 peer；顺带清掉加节点中途失败留下的残留 peer
    local kp_priv; kp_priv=$(wg genkey)
    # shellcheck disable=SC2046
    WGP_PRIV="$kp_priv" WGP_PUB="$(printf '%s' "$kp_priv" | wg pubkey)" WGP_PSK="$(wg genpsk)" \
      WGP_UUID="$buuid" WGP_XPORT="$wgx" wg_state put "$name" "$wgip" $(list_nodes 2>/dev/null)
    wg_apply
    ok "节点 $name 已添加（WireGuard 出口 wgx-$name，隧道 IP $wgip，入口端口 $uport，伪装域名 $nsni）"
    warn "这个节点现在还没有落地机，WireGuard 握手前不可用"
    warn "转发机云厂商安全组要放行 $(wg_state get port)/udp（WireGuard 端口，所有 WG 节点共用）"
    print_wg_cmd "$name"
  else
    open_fw "$REVERSE_PORT" 2>/dev/null || true
    ok "节点 $name 已添加（专属出口 portal-$name，入口端口 $uport，伪装域名 $nsni）"
    warn "这个节点现在还没有出口机，隧道未建立前不可用"
    print_b_cmd "$buuid" "$name"
  fi
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
  case "$(printf '%s' "$line" | cut -f2)" in
    wgx-*) print_wg_cmd "$name" ;;
    *)     print_b_cmd "$buuid" "$name" ;;
  esac
}

del_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端删节点"
  ensure_migrated
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || die "配置里没有任何节点"
  local names; names=$(printf '%s\n' "$rows" | cut -f1)
  local total; total=$(printf '%s\n' "$names" | grep -c .)

  cfg_lock
  local name="${1:-}"
  if [ -z "$name" ]; then
    noninteractive && die "非交互模式必须指定节点名：--del NAME"
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
  # 允许删最后一个节点：主入口保留、clients 为空（xray -test 可通过），之后可再加节点
  if [ "$total" -le 1 ]; then
    warn "这是最后一个节点：删完后 A 端暂时没有可用节点，入口端口仍保留，之后可以再加节点"
  fi

  local ptag; ptag=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n{print $2}')
  echo
  warn "将一并删除它的专属出口绑定${ptag:+（$ptag）}"
  warn "对应的出口机会失去连接。它上面的 att-tunnel 需你自己去卸载（否则它会一直重试拨号）"
  local c=""
  if noninteractive; then
    # 非交互（网页面板 / 脚本调用）：必须显式 ATT_YES=1，面板那边已让用户输入节点名确认
    [ "${ATT_YES:-}" = 1 ] || die "非交互删除需要 ATT_YES=1"
    c=yes
  else
    read -rp "确认删除节点 ${BLD}$name${RST}？它的分享链接会立刻失效（输 yes）: " c
  fi
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
    if (ot.startswith('portal') or ot.startswith('wgx-')) and name in r.get('user',[]) and 'probe-in' not in (r.get('inboundTag') or []):
        ptags.add(ot)

found=False
ibs=[]
for ib in d.get('inbounds',[]):
    t=str(ib.get('tag',''))
    if t=='user-in' or t.startswith('user-in-'):
        cs=ib['settings']['clients']
        keep=[c for c in cs if c.get('email')!=name]
        if len(keep)!=len(cs):
            found=True
        if not keep and t!='user-in':
            # 额外入口（user-in-<端口>）空了就整个删掉；主入口保留（clients 可为空）
            continue
        ib['settings']['clients']=keep
    ibs.append(ib)
d['inbounds']=ibs
if not found:
    raise SystemExit('NOTFOUND')

# 1:1：摘掉它专属的 bridge client。仅当没有其他节点共用该标签时才删，
# 防止旧结构（多节点共一个 portal）下误删别人的隧道。
still={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 探测规则（probe-in）不算“共用”，否则 probe-<节点> 会让 bridge 永远删不掉
    if (ot.startswith('portal') or ot.startswith('wgx-')) and 'probe-in' not in (r.get('inboundTag') or []):
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
    # WireGuard 节点：摘掉它的 wgx-<节点> 出站
    d['outbounds']=[o for o in d.get('outbounds',[]) if o.get('tag') not in drop]

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
  # WireGuard 节点：摘掉它的 peer（syncconf 热更新，不影响别的落地机）
  case "$ptag" in wgx-*)
    if [ -s "$WG_STATE" ]; then
      wg_state del "$name"
      if command -v wg >/dev/null; then wg_apply || warn "WireGuard peer 摘除失败，重跑一次 --del 或 --check"; fi
    fi ;;
  esac
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
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
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
    if (ot.startswith('portal') or ot.startswith('wgx-')) and not is_probe(r):
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
# 没有节点时 accounts 为空也合法（xray -test 通过），兜底规则把探测入口送进 blackhole
st['accounts']=[{'user':'probe-'+n,'pass':old.get('probe-'+n) or secrets.token_hex(16)} for n in nodes]
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
WEB_SCRIPT="$WEB_DIR/att-tunnel.sh"
WEB_ENV="$STATE/web.env"
WEB_DATA="/var/lib/att-tunnel"

write_web_py(){
  mkdir -p "$WEB_DIR"
  cat > "$WEB_PY.tmp" <<'ATT_WEB_PY'
#!/usr/bin/env python3
# att-tunnel 网页面板 vATT_VERSION：只用 Python 标准库，无外部 CDN。
# 流量：每 POLL 秒读一次 Xray StatsService 的累计计数（不 -reset），按差值累加进本地 JSON。
#   每个节点两路计数取大者：客户端计数 user>>>节点 和 出口隧道计数 user>>>exit.<portal>
#   （出口隧道计数扣掉探测流量；多节点共用 portal 的旧结构只用客户端计数）。
# 出口 IP：经 127.0.0.1 的 probe-in（socks5+密码）按节点走 portal-<节点>，访问 api.ipify.org。
# 加/删节点：调用本机脚本副本 att-tunnel.sh --add/--del（同一套配置逻辑、校验和回滚），不在这里改配置。
# 安全：随机端口 + 随机路径 + 密码；Cookie HttpOnly/SameSite=Strict；所有 POST 需会话 + CSRF；
#       登录失败限速；分享链接/UUID 只在「查看链接」时按需返回，状态接口里没有。
# 订阅：每个节点一个随机 token（存 web-state.json），<前缀>/sub/<token> 免登录返回 base64 的 vless 链接；
#       token 只在「查看链接」里给出，删节点即作废。
import base64
import hmac
import http.cookies
import http.server
import ipaddress
import json
import os
import re
import secrets
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse

VERSION = 'ATT_VERSION'
CFG = os.environ.get('ATT_CFG', '/usr/local/etc/att-tunnel/config.json')
ENVF = os.environ.get('ATT_WEB_ENV', '/etc/att-tunnel/web.env')
AENV = os.environ.get('ATT_A_ENV', '/etc/att-tunnel/a.env')
STATEF = os.environ.get('ATT_WEB_STATE', '/var/lib/att-tunnel/web-state.json')
XRAY = os.environ.get('ATT_XRAY', '/usr/local/bin/xray')
SCRIPT = os.environ.get('ATT_SCRIPT', '/usr/local/lib/att-tunnel/att-tunnel.sh')
SVC = os.environ.get('ATT_SVC', 'att-tunnel')
POLL = int(os.environ.get('ATT_POLL', '10'))
PROBE_EVERY = int(os.environ.get('ATT_PROBE_EVERY', '300'))
HIST_MAX = 90           # 每节点保留最近 90 个采样点（默认 10s 一个 = 15 分钟）
SESSION_TTL = 12 * 3600
IP_SOURCES = [('api.ipify.org', '/'), ('icanhazip.com', '/'), ('ifconfig.me', '/ip')]
NAME_RE = re.compile(r'^[A-Za-z0-9_-]{1,32}$')     # 与脚本 add_node 同一规则
SUB_RE = re.compile(r'^[A-Za-z0-9_-]{20,64}$')     # 订阅 token
SNI_RE = re.compile(r'^[A-Za-z0-9.-]{1,253}$')
# SSH 直装出口机：主机允许 IPv4 / 域名 / [IPv6]
SSH_HOST_RE = re.compile(r'^[A-Za-z0-9._\-\[\]:]{3,253}$')
SSH_USER_RE = re.compile(r'^[A-Za-z0-9._-]{1,32}$')
# 从脚本输出里拆出来的出口机命令片段，写进远程命令前再校一次
BRIDGE_URL_RE = re.compile(r"^https?://[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]{10,400}$")
BRIDGE_TOKEN_RE = re.compile(r'^[A-Za-z0-9+/=_-]{8,4096}$')
ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def log(*a):
    print(time.strftime('%F %T'), *a, file=sys.stderr, flush=True)


def load_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


ENV = load_env(ENVF)
PORT = int(ENV['WEB_PORT'])
PREFIX = '/' + ENV['WEB_PATH'].strip('/')
PASS = ENV['WEB_PASS']
LISTEN = ENV.get('WEB_LISTEN', '0.0.0.0')
RAW_URL = ENV.get('WEB_RAW_URL', '')
if len(PASS) < 8 or PREFIX == '/':
    sys.exit('web.env 不完整：WEB_PASS 至少 8 位，WEB_PATH 不能为空')

lock = threading.RLock()
save_lock = threading.Lock()
probe_lock = threading.Lock()
mut_lock = threading.Lock()      # 加/删节点串行（脚本里还有一把 flock）
state = {'nodes': {}, 'raw': {}, 'last_poll': 0, 'poll_err': '', 'started': 0}


def now():
    return int(time.time())


def load_state():
    global state
    try:
        with open(STATEF) as f:
            s = json.load(f)
        if isinstance(s, dict) and isinstance(s.get('nodes'), dict):
            s.setdefault('raw', {})
            # v2.1.0 每次都 -reset，它留下的计数基线没有意义
            if s.get('ver') != 2:
                s['raw'] = {}
            if not isinstance(s.get('subs'), dict):
                s['subs'] = {}
            state.update(s)
    except Exception:
        pass
    state['ver'] = 2


def save_state():
    # v2.1.0 的 bug：多线程共用一个临时文件名，并发保存会抛 FileNotFoundError，
    # 而轮询线程没接住这个异常 -> 统计线程静默退出，流量从此不再增长。
    # 现在：串行保存 + 每线程独立临时名 + 调用方全部 try 住。
    with save_lock:
        d = os.path.dirname(STATEF)
        os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = '%s.tmp.%d.%d' % (STATEF, os.getpid(), threading.get_ident())
        with lock:
            data = json.dumps(state, ensure_ascii=False)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATEF)


def safe_save():
    try:
        save_state()
    except Exception as e:
        log('保存状态失败:', e)


def is_user_in(ib):
    t = str(ib.get('tag', ''))
    return t == 'user-in' or t.startswith('user-in-')


def read_cfg():
    """从 config.json 读节点表：名称、入口端口、伪装域名、绑定出口、探测账号、API 地址。"""
    with open(CFG) as f:
        d = json.load(f)
    api = (d.get('api') or {}).get('listen', '')
    nodes, probe_port, probe_acc = [], None, {}
    for ib in d.get('inbounds', []):
        if is_user_in(ib):
            rs = (ib.get('streamSettings') or {}).get('realitySettings') or {}
            sni = (rs.get('serverNames') or [''])[0]
            for c in ib.get('settings', {}).get('clients', []):
                nodes.append((c.get('email', 'node'), ib.get('port'), sni))
        elif ib.get('tag') == 'probe-in':
            probe_port = ib.get('port')
            for a in ib.get('settings', {}).get('accounts', []):
                probe_acc[a.get('user', '')] = a.get('pass', '')
    portal = {}
    for r in d.get('routing', {}).get('rules', []):
        ot = r.get('outboundTag', '')
        if (ot.startswith('portal') or ot.startswith('wgx-')) and 'probe-in' not in (r.get('inboundTag') or []):
            for u in r.get('user', []):
                portal[u] = ot
    use = {}
    for n, _, _ in nodes:
        if portal.get(n):
            use[portal[n]] = use.get(portal[n], 0) + 1
    out = []
    for n, port, sni in nodes:
        ex = portal.get(n, '')
        out.append({'name': n, 'port': port, 'sni': sni, 'exit': ex,
                    'kind': 'wg' if ex.startswith('wgx-') else 'reverse',
                    'shared': use.get(ex, 0) > 1,
                    'probe_user': 'probe-' + n,
                    'probe_pass': probe_acc.get('probe-' + n, '')})
    return {'api': api, 'probe_port': probe_port, 'nodes': out}


def node_rec(name):
    with lock:
        r = state['nodes'].setdefault(name, {})
        for k, v in (('up', 0), ('down', 0), ('since', now()), ('ip', ''), ('ip_ts', 0),
                     ('probe_ok', False), ('probe_ts', 0), ('probe_err', ''), ('hist', []),
                     ('rate_up', 0), ('rate_down', 0), ('cnt_user', 0), ('cnt_exit', 0)):
            r.setdefault(k, v)
        return r


def statsquery(api):
    """读全部累计计数（不清零）。返回 {计数器名: 值}。值为 0 的计数器 Xray 不输出 value 字段。"""
    p = subprocess.run([XRAY, 'api', 'statsquery', '--server=' + api],
                       capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise RuntimeError('xray api statsquery 失败：' +
                           ((p.stderr or p.stdout).strip()[-200:] or 'rc=%d' % p.returncode))
    txt = p.stdout.strip()
    if not txt:
        return {}
    return {s.get('name', ''): int(s.get('value') or 0) for s in (json.loads(txt).get('stat') or [])}


def svc_info(name):
    """(是否 active, 进入 active 的单调时间戳)。时间戳变了 = xray 重启过，计数器已归零。"""
    try:
        p = subprocess.run(['systemctl', 'show', name, '-p', 'ActiveState',
                            '-p', 'ActiveEnterTimestampMonotonic', '-p', 'ActiveEnterTimestamp'],
                           capture_output=True, text=True, timeout=5)
        kv = dict(l.split('=', 1) for l in p.stdout.splitlines() if '=' in l)
        return (kv.get('ActiveState') == 'active', kv.get('ActiveEnterTimestampMonotonic', ''),
                kv.get('ActiveEnterTimestamp', ''))
    except Exception:
        return (False, '', '')


def poll_stats():
    """读累计计数，按差值累加。xray 重启（计数归零）靠 systemd 的启动时间戳识别。"""
    try:
        c = read_cfg()
        if not c['api']:
            raise RuntimeError('config.json 没有 api 段：请重跑 --web（会自动启用统计并重启 xray）')
        active, mono, since = svc_info(SVC)
        with lock:
            state['xray_active'], state['xray_since'] = active, since
        if not active:
            raise RuntimeError('%s 服务未运行，读不到流量计数' % SVC)
        cur = statsquery(c['api'])
        t = now()
        with lock:
            if state.get('xray_mono') != mono:
                state['raw'] = {}          # xray 重启过：新计数从 0 开始
                state['xray_mono'] = mono
            raw = state['raw']
            dl = {k: (v - raw[k] if k in raw and v >= raw[k] else v) for k, v in cur.items()}
            state['raw'] = cur
            dt = max(1, t - (state.get('last_poll') or t - POLL))
            for n in c['nodes']:
                name, ex = n['name'], n['exit']
                r = node_rec(name)
                u_up = dl.get('user>>>%s>>>traffic>>>uplink' % name, 0)
                u_dn = dl.get('user>>>%s>>>traffic>>>downlink' % name, 0)
                e_up = e_dn = 0
                if ex and not n['shared']:
                    # 出口隧道的方向与客户端相反：B->A(uplink) 就是用户下载
                    p_up = dl.get('user>>>probe-%s>>>traffic>>>uplink' % name, 0)
                    p_dn = dl.get('user>>>probe-%s>>>traffic>>>downlink' % name, 0)
                    e_dn = max(0, dl.get('user>>>exit.%s>>>traffic>>>uplink' % ex, 0) - p_dn)
                    e_up = max(0, dl.get('user>>>exit.%s>>>traffic>>>downlink' % ex, 0) - p_up)
                up, dn = max(u_up, e_up), max(u_dn, e_dn)
                r['up'] += up
                r['down'] += dn
                r['cnt_user'] += u_up + u_dn
                r['cnt_exit'] += e_up + e_dn
                r['rate_up'], r['rate_down'] = up // dt, dn // dt
                r['hist'] = (r['hist'] + [[t, up, dn]])[-HIST_MAX:]
            state['last_poll'] = t
            state['poll_err'] = ''
    except Exception as e:
        with lock:
            state['poll_err'] = str(e)[:300]
        log('统计轮询失败:', e)
    safe_save()


def recv_exact(s, n):
    b = b''
    while len(b) < n:
        x = s.recv(n - len(b))
        if not x:
            raise RuntimeError('socks 连接被关闭')
        b += x
    return b


def socks5_get(port, user, pw, host, path, timeout=12):
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
        raise RuntimeError('HTTP ' + status.decode('latin1')[:40] if status else '出口无响应（隧道未连上？）')
    return body.decode('latin1').strip()


def probe_node(n, probe_port):
    r = node_rec(n['name'])
    err, ip = '', ''
    if not probe_port or not n['probe_pass']:
        err = '未配置探测账号（重跑 --web）'
    elif not n['exit']:
        err = '节点没绑定出口机'
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


def probe_all(only=None, wait=True):
    if not probe_lock.acquire(blocking=wait):
        return False  # 已有一轮在跑
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
    except Exception as e:
        log('探测失败:', e)
    finally:
        probe_lock.release()
    safe_save()
    return True


def worker():
    last_probe = 0
    while True:
        # 任何异常都不能让这个线程退出（v2.1.0 就是线程静默死掉，流量永远不再增长）
        try:
            poll_stats()
            if time.time() - last_probe >= PROBE_EVERY:
                last_probe = time.time()
                threading.Thread(target=probe_all, kwargs={'wait': False}, daemon=True).start()
        except Exception:
            log('worker 异常:', traceback.format_exc())
        time.sleep(POLL)


def tunnel_count(port):
    """数 reverse-in 端口上的 ESTABLISHED 连接（= 已连上的出口机隧道数）。"""
    n = 0
    for fn in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            with open(fn) as f:
                next(f)
                for line in f:
                    p = line.split()
                    if p[3] == '01' and int(p[1].rsplit(':', 1)[1], 16) == port:
                        n += 1
        except Exception:
            pass
    return n


def status_json():
    try:
        c = read_cfg()
        cfg_err = ''
    except Exception as e:
        c, cfg_err = {'nodes': []}, '读配置失败：' + str(e)[:200]
    a = load_env(AENV)
    t = now()
    out = []
    with lock:
        for n in c['nodes']:
            r = node_rec(n['name'])
            online = bool(r['probe_ok'] and t - r['probe_ts'] <= PROBE_EVERY + 2 * POLL + 60)
            out.append({'name': n['name'], 'port': n['port'], 'sni': n['sni'], 'exit': n['exit'],
                        'kind': n['kind'], 'shared': n['shared'], 'online': online, 'ip': r['ip'], 'ip_ts': r['ip_ts'],
                        'probe_ts': r['probe_ts'], 'probe_err': r['probe_err'],
                        'up': r['up'], 'down': r['down'], 'total': r['up'] + r['down'],
                        'rate_up': r['rate_up'], 'rate_down': r['rate_down'],
                        'hist': [h[1] + h[2] for h in r['hist'][-40:]],
                        'src_user': r['cnt_user'], 'src_exit': r['cnt_exit'], 'since': r['since']})
        rp = a.get('REVERSE_PORT', '')
        return {'now': t, 'version': VERSION, 'a_ip': a.get('A_IP', ''), 'wg': wg_info(),
                'reverse_port': rp, 'tunnels': tunnel_count(int(rp)) if rp.isdigit() else 0,
                'xray_active': state.get('xray_active', False), 'xray_since': state.get('xray_since', ''),
                'last_poll': state['last_poll'], 'poll': POLL, 'probe_every': PROBE_EVERY,
                'error': cfg_err or state['poll_err'], 'nodes': out, 'busy': mut_lock.locked(), 'manage': os.path.isfile(SCRIPT)}


WG_STATE = os.environ.get('ATT_WG_STATE', '/etc/att-tunnel/wg.json')


def wg_info():
    """WireGuard 出口概况：UDP 端口 + 最近 180 秒内握手过的落地机数。没有 WG 节点返回 None。"""
    try:
        with open(WG_STATE) as f:
            w = json.load(f)
    except Exception:
        return None
    out = {'port': w.get('port'), 'peers': len(w.get('peers') or {}), 'up': 0}
    try:
        p = subprocess.run(['wg', 'show', 'attwg', 'latest-handshakes'], capture_output=True,
                           text=True, timeout=5)
        t = now()
        out['up'] = sum(1 for l in p.stdout.split('\n') if len(l.split()) == 2
                        and l.split()[1].isdigit() and 0 < t - int(l.split()[1]) < 180)
    except Exception:
        pass
    return out


def run_script(args, extra_env=None, timeout=180):
    """非交互调用脚本副本。返回 (rc, 去掉颜色码的输出)。"""
    if not os.path.isfile(SCRIPT):
        return 127, '找不到脚本副本 %s：请在 A 机上重跑一次 --web' % SCRIPT
    env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
           'HOME': '/root', 'LANG': 'C.UTF-8', 'ATT_NONINTERACTIVE': '1', 'ATT_FROM_WEB': '1'}
    if RAW_URL:
        env['ATT_RAW_URL'] = RAW_URL
    env.update(extra_env or {})
    try:
        p = subprocess.run(['bash', SCRIPT] + args, stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, '脚本执行超时（%ds）' % timeout
    txt = ANSI_RE.sub('', (p.stdout or '') + (p.stderr or ''))
    return p.returncode, txt.strip()[-6000:]


SNI_PRESETS = "ATT_SNI_PRESETS"   # write_web_py 替换成脚本里的预置列表 [[域名, 国家], ...]


def node_names():
    try:
        return [x['name'] for x in read_cfg()['nodes']]
    except Exception:
        return []


def node_vless(name):
    """取节点的 vless:// 分享链接（来自脚本本身）。"""
    rc, out = run_script(['--link', name], timeout=30)
    link = next((l.strip() for l in out.splitlines() if l.strip().startswith('vless://')), '')
    if rc != 0 or not link:
        raise RuntimeError(out or '取分享链接失败')
    return link


def sub_token(name):
    """节点的订阅 token：没有就生成一个并保存。"""
    with lock:
        subs = state.setdefault('subs', {})
        t = subs.get(name)
        if t:
            return t
        t = subs[name] = secrets.token_urlsafe(24)
    safe_save()
    return t


def sub_node(tok):
    """按订阅 token 找节点（常量时间比较），找不到或节点已删返回 None。"""
    if not SUB_RE.match(tok or ''):
        return None
    with lock:
        items = list((state.get('subs') or {}).items())
    hit = None
    for n, t in items:
        if hmac.compare_digest(str(t).encode(), tok.encode()):
            hit = n
    return hit if hit and hit in node_names() else None


def node_link(name):
    """按需取分享链接 + 出口机命令 + 订阅 token。"""
    link = node_vless(name)
    rc, out = run_script(['--exit-cmd', name], timeout=30)
    cmd = next((l.strip() for l in out.splitlines() if '--bridge ' in l or '--wg-bridge ' in l), '')
    if rc != 0 or not cmd:
        raise RuntimeError(out or '取出口机命令失败')
    return {'name': name, 'link': link, 'exit_cmd': cmd, 'sub_token': sub_token(name)}


def after_change(name=None):
    """加/删节点后：清理已删节点的记录，立刻轮询一次，并探测新节点。"""
    keep = set(node_names())
    with lock:
        for k in [k for k in state['nodes'] if k not in keep]:
            del state['nodes'][k]
        subs = state.setdefault('subs', {})
        for k in [k for k in subs if k not in keep]:
            del subs[k]          # 删节点：订阅链接一起作废
    poll_stats()
    if name and name in keep:
        threading.Thread(target=probe_all, kwargs={'only': name}, daemon=True).start()


# ---------------- SSH 直装出口机（可选） ----------------
# 只用系统 ssh（+ sshpass 走密码），不引入任何 Python 第三方库。
# 面板不保存任何 SSH 凭据：密码/私钥只在本次请求内用临时文件传给 ssh，用完即删。
SSH_OPTS = ['-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=8', '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'LogLevel=ERROR']
# 注意：OpenSSH 里同名 -o 选项是「第一次出现的值生效」，所以 BatchMode /
# PreferredAuthentications 不能先在公共参数里给一个默认值再在分支里覆盖，
# 必须只在各自分支里给一次：
#   私钥：BatchMode=yes，被拒就直接失败（不转去等密码，否则 stdin 被
#          远程脚本占着，会一直挂到超时）
#   密码：BatchMode=no，sshpass 靠接密码提示工作


def have(cmd):
    for d in ('/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin', '/sbin', '/bin'):
        if os.path.isfile(os.path.join(d, cmd)):
            return os.path.join(d, cmd)
    return ''


def split_exit_cmd(cmd):
    """把脚本给出的出口机命令拆成 (raw_url, token)。

    不直接把整条命令丢进远程 shell：那条命令是我们自己拼的，但经过 HTTP 往返后
    再当 shell 代码执行，风险没必要承担。拆出两个字段各自严格校验，
    远程只执行我们在这里重新拼的固定形状命令。
    """
    m = re.search(r'(https?://\S+?/install\.sh)', cmd)
    t = re.search(r'--(wg-)?bridge\s+([A-Za-z0-9+/=_-]+)', cmd)
    if not m or not t:
        raise RuntimeError('解析出口机命令失败')
    url, token = m.group(1), t.group(2)
    if not BRIDGE_URL_RE.match(url) or not BRIDGE_TOKEN_RE.match(token):
        raise RuntimeError('出口机命令里的地址或 token 不合规')
    return url, token, ('--wg-bridge' if t.group(1) else '--bridge')
def ssh_install_bridge(host, port, user, password, key_text, exit_cmd, log_cb=None):
    """到出口机上跑 att-tunnel --bridge <token>。返回 (rc, 输出)。

    凭据只落临时文件（0600，用完删），不进命令行（ps 里看不到）、不写日志。
    """
    url, token, flag = split_exit_cmd(exit_cmd)
    sshbin = have('ssh')
    if not sshbin:
        return 127, '本机没有 ssh 客户端（装一下 openssh-client）'

    # 远程只执行这一条固定形状的命令，url / token 已校验并再做一次 shell 转义。
    # 非 root 用户不能直接跑 --bridge（脚本会 need_root），所以这里用 sudo 提权：
    #   1) 能免密 sudo 就直接 sudo -n；
    #   2) 有 SSH 密码就用同一个密码走 sudo -S（面板只有一个密码框）；
    #   3) 只给私钥且没有免密 sudo 时，明确报错，不静默失败。
    # 密码只写进远端脚本的标准输入，不作为 sudo 参数，也不落远端文件。
    remote = r'''set -e
export DEBIAN_FRONTEND=noninteractive
trap 'rm -f /tmp/att-bridge.sh' EXIT
cd /tmp
if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 {url} -o /tmp/att-bridge.sh; then
  :
elif command -v wget >/dev/null 2>&1 && wget -q -O /tmp/att-bridge.sh {url}; then
  :
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' {url} /tmp/att-bridge.sh; then
  :
elif [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1 && apt-get update -qq && apt-get install -y -qq curl >/dev/null && curl -fsSL --max-time 60 {url} -o /tmp/att-bridge.sh; then
  :
elif [ "$(id -u)" -eq 0 ] && command -v dnf >/dev/null 2>&1 && dnf install -y -q curl >/dev/null && curl -fsSL --max-time 60 {url} -o /tmp/att-bridge.sh; then
  :
elif [ "$(id -u)" -eq 0 ] && command -v yum >/dev/null 2>&1 && yum install -y -q curl >/dev/null && curl -fsSL --max-time 60 {url} -o /tmp/att-bridge.sh; then
  :
else
  echo "[X] 出口机上没有可用的下载工具（curl/wget/python3），自动安装 curl 也失败；请先安装 curl，或用一键代码手动安装。" >&2
  exit 127
fi
if [ "$(id -u)" -eq 0 ]; then
  ATT_NONINTERACTIVE=1 ATT_RAW_URL={url} bash /tmp/att-bridge.sh {flag} {token}
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[X] SSH 用户不是 root，且机器上没有 sudo；请改用 root 登录，或用一键代码手动安装。" >&2
    exit 126
  fi
  SUDO_PASS={sudo_pass}
  if sudo -n true 2>/dev/null; then
    sudo -n env DEBIAN_FRONTEND=noninteractive ATT_NONINTERACTIVE=1 ATT_RAW_URL={url} bash /tmp/att-bridge.sh {flag} {token}
  elif [ -n "$SUDO_PASS" ] && printf '%s\n' "$SUDO_PASS" | sudo -S -p '' true 2>/dev/null; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' env DEBIAN_FRONTEND=noninteractive ATT_NONINTERACTIVE=1 ATT_RAW_URL={url} bash /tmp/att-bridge.sh {flag} {token}
  else
    echo "[X] SSH 用户不是 root，且 sudo 不可用或密码不正确。请给该用户配置免密 sudo，或改用 root 登录。" >&2
    exit 126
  fi
fi
'''.format(url=shlex.quote(url), flag=flag, token=shlex.quote(token),
           sudo_pass=shlex.quote(password or ''))

    tmpdir = tempfile.mkdtemp(prefix='att-ssh-')
    env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
           'HOME': '/root', 'LANG': 'C.UTF-8',
           # 别让 ssh 去踩 agent / 默认私钥，也别弹任何图形密码框
           'SSH_ASKPASS_REQUIRE': 'never', 'DISPLAY': ''}
    cmd = [sshbin] + SSH_OPTS + ['-p', str(port),
                                 '-o', 'UserKnownHostsFile=%s/known_hosts' % tmpdir]
    try:
        if key_text:
            kp = os.path.join(tmpdir, 'id')
            with open(kp, 'w') as fh:
                fh.write(key_text if key_text.endswith('\n') else key_text + '\n')
            os.chmod(kp, 0o600)
            cmd += ['-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                    '-o', 'PreferredAuthentications=publickey', '-i', kp]
        elif password:
            sp = have('sshpass')
            if not sp:
                return 127, ('本机没有 sshpass，无法用密码登录。'
                             '在 A 机跑 apt-get install -y sshpass 后重试，'
                             '或改用私钥、或用一键代码自己装。')
            pf = os.path.join(tmpdir, 'pw')
            with open(pf, 'w') as fh:
                fh.write(password)
            os.chmod(pf, 0o600)
            cmd += ['-o', 'BatchMode=no', '-o', 'PubkeyAuthentication=no',
                    '-o', 'PreferredAuthentications=password,keyboard-interactive']
            cmd = [sp, '-f', pf] + cmd
        else:
            return 400, '请填密码或私钥'

        cmd += ['%s@%s' % (user, host), 'bash -s']
        if log_cb:
            log_cb('连接 %s@%s:%s …' % (user, host, port))
        p = subprocess.run(cmd, input=remote, capture_output=True, text=True,
                           timeout=900, env=env)
        txt = ANSI_RE.sub('', (p.stdout or '') + (p.stderr or ''))
        return p.returncode, txt.strip()[-6000:]
    except subprocess.TimeoutExpired:
        return 124, 'SSH 安装超时（900 秒），出口机上可能仍在跑，稍后看节点是否上线'
    except OSError as e:
        return 1, 'SSH 执行失败：%s' % e
    finally:
        for fn in ('id', 'pw', 'known_hosts'):
            try:
                os.remove(os.path.join(tmpdir, fn))
            except OSError:
                pass
        try:
            os.rmdir(tmpdir)
        except OSError:
            pass


# SSH 安装任务：装出口机要跑几分钟，而面板经 hub 代理访问时代理只等 280s，
# 同步做必然 504。所以丢后台线程跑，前端轮询 /api/ssh-status 看进度。
ssh_jobs = {}
SSH_JOB_TTL = 3600


def ssh_job_new(node):
    jid = secrets.token_urlsafe(12)
    with lock:
        t = now()
        for k in [k for k, v in ssh_jobs.items() if v['done'] and t - v['ts'] > SSH_JOB_TTL]:
            del ssh_jobs[k]
        ssh_jobs[jid] = {'node': node, 'state': '正在连接…', 'log': '',
                         'rc': None, 'done': False, 'ts': t}
    return jid


def ssh_job_set(jid, **kw):
    with lock:
        j = ssh_jobs.get(jid)
        if j:
            j.update(kw, ts=now())


def ssh_job_run(jid, node, args):
    """后台线程：在出口机上装 att-tunnel B 端。"""
    try:
        ssh_job_set(jid, state='正在连接出口机并安装（首次要装 xray，可能要几分钟）…')
        rc, out = ssh_install_bridge(*args)
        if rc == 0:
            ssh_job_set(jid, state='安装完成，等隧道上线', log=out, rc=0, done=True)
            threading.Thread(target=probe_all, kwargs={'only': node}, daemon=True).start()
        else:
            ssh_job_set(jid, state='安装失败（rc=%d）' % rc, log=out, rc=rc, done=True)
    except Exception as e:
        log('SSH 安装任务异常:', e)
        ssh_job_set(jid, state='安装异常', log=str(e)[:2000], rc=1, done=True)



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


CSS = '''
:root{--bg:#f3f5f9;--card:#fff;--fg:#0f172a;--mut:#64748b;--line:#e2e8f0;--pri:#2563eb;--pri2:#1d4ed8;
--ok:#16a34a;--okb:#dcfce7;--bad:#dc2626;--badb:#fee2e2;--warn:#b45309;--warnb:#fef3c7;--sh:0 1px 3px #0f172a14,0 4px 16px #0f172a0d}
@media(prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#141b2d;--fg:#e2e8f0;--mut:#94a3b8;--line:#243049;
--pri:#3b82f6;--pri2:#60a5fa;--ok:#4ade80;--okb:#14532d66;--bad:#f87171;--badb:#7f1d1d66;--warn:#fbbf24;--warnb:#78350f66;--sh:0 1px 3px #0006}}
*{box-sizing:border-box}html,body{margin:0}body{font:15px/1.5 system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg)}
button,input,select{font:inherit;color:inherit}
.btn{border:1px solid var(--line);background:var(--card);padding:8px 14px;border-radius:10px;cursor:pointer;white-space:nowrap}
.btn:hover{border-color:var(--pri)}.btn:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--pri);outline-offset:2px}
.btn.p{background:var(--pri);border-color:var(--pri);color:#fff}.btn.p:hover{background:var(--pri2)}
.btn.d{color:var(--bad)}.btn.d:hover{border-color:var(--bad)}.btn.s{padding:5px 10px;font-size:13px}
.btn:disabled{opacity:.55;cursor:not-allowed}
input,select{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--bg)}
label{display:block;font-size:13px;color:var(--mut);margin:10px 0 4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--sh)}
.mut{color:var(--mut)}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;word-break:break-all}
.err{color:var(--bad)}
'''

PAGE_LOGIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
<title>att-tunnel 登录</title><style>{CSS}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}
form{width:min(360px,100%);padding:28px}h1{font-size:20px;margin:0 0 4px}.logo{font-size:28px}
.btn{width:100%;margin-top:16px;padding:11px}</style></head>
<body><form class="card" method="post" action="{P}/login"><div class="logo" aria-hidden="true">🛰️</div>
<h1>att-tunnel 面板</h1><p class="mut" style="margin:0 0 8px">反向隧道 · 流量与节点管理</p>{E}
<label for="pw">密码</label><input id="pw" type="password" name="password" autocomplete="current-password" required autofocus>
<button class="btn p" type="submit">登录</button></form></body></html>'''

PAGE_MAIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
<title>att-tunnel 面板</title><style>{CSS}
.wrap{max-width:1180px;margin:0 auto;padding:16px}
header{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:16px 20px;margin-bottom:16px}
header h1{font-size:19px;margin:0}.hinfo{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px}
.acts{display:flex;gap:8px;flex-wrap:wrap}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:600}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.pill.on{color:var(--ok);background:var(--okb)}.pill.off{color:var(--bad);background:var(--badb)}.pill.w{color:var(--warn);background:var(--warnb)}
.sum{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:16px}
.sum .card{padding:14px 16px}.sum b{display:block;font-size:24px;font-weight:700;margin-top:2px}
.alert{padding:12px 16px;margin-bottom:16px;border-color:var(--bad);color:var(--bad);background:var(--badb);display:none;white-space:pre-wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}
.node{padding:16px}.node h2{font-size:17px;margin:0;display:flex;align-items:center;justify-content:space-between;gap:8px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;margin:12px 0;font-size:14px}.kv dt{color:var(--mut)}.kv dd{margin:0;word-break:break-all}
.tr{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:8px 0}.tr div{background:var(--bg);border-radius:10px;padding:8px 10px}
.tr small{color:var(--mut);display:block;font-size:12px}.tr b{font-size:16px}
.barw{height:6px;background:var(--bg);border-radius:9px;overflow:hidden;margin:6px 0 2px}.bar{height:100%;background:linear-gradient(90deg,var(--pri),#8b5cf6);border-radius:9px}
svg.spark{width:100%;height:34px;display:block}svg.spark path{fill:none;stroke:var(--pri);stroke-width:1.5}
.nact{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px}
.sec{display:flex;align-items:center;justify-content:space-between;margin:20px 0 10px}.sec h3{margin:0;font-size:16px}
.empty{padding:30px;text-align:center}
dialog{border:1px solid var(--line);border-radius:16px;background:var(--card);color:var(--fg);padding:0;width:min(560px,94vw);box-shadow:var(--sh)}
dialog::backdrop{background:#0008}.dh{padding:16px 20px;border-bottom:1px solid var(--line);font-weight:700}
.db{padding:4px 20px 16px}.df{padding:12px 20px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end}
.row{display:flex;gap:8px}.row>*{flex:1}
.copy{display:flex;gap:6px;align-items:flex-start;background:var(--bg);border-radius:10px;padding:8px 10px;margin-top:4px}.copy .mono{flex:1}
.qrs{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:12px 0 4px}.qrs figure{margin:0;text-align:center}.qrs img{width:100%;max-width:240px;background:#fff;border-radius:10px;padding:6px;box-sizing:border-box;image-rendering:pixelated}.qrs figcaption{font-size:13px;margin-top:4px}
pre.out{max-height:220px;overflow:auto;background:var(--bg);padding:10px;border-radius:10px;font-size:12px;white-space:pre-wrap}
#toasts{position:fixed;right:16px;bottom:16px;display:flex;flex-direction:column;gap:8px;z-index:9;max-width:min(380px,90vw)}
.toast{padding:10px 14px;border-radius:12px;color:#fff;background:#0f172a;box-shadow:var(--sh);font-size:14px}
.toast.ok{background:#15803d}.toast.bad{background:#b91c1c}
@media(max-width:760px){.sum{grid-template-columns:repeat(2,1fr)}.sum .card:last-child{grid-column:1/-1}.wrap{padding:10px}header{padding:14px}}
</style></head><body><div class="wrap">
<header class="card"><div><h1>🛰️ att-tunnel 面板 <span class="mut" style="font-size:13px;font-weight:400" id="ver"></span></h1>
<div class="hinfo mut" id="hinfo">加载中…</div></div>
<div class="acts"><button class="btn p" id="bAdd" type="button" hidden>＋ 添加节点</button>
<button class="btn" id="bProbe" type="button">立即探测</button><button class="btn" id="bRef" type="button">刷新</button>
<form method="post" action="{P}/logout" style="margin:0"><input type="hidden" name="csrf" value="{C}"><button class="btn" type="submit">退出</button></form></div></header>
<div class="card alert" id="err" role="alert"></div>
<div class="sum" id="sum"></div>
<div class="sec"><h3>节点</h3><span class="mut" style="font-size:13px" id="meta" aria-live="polite"></span></div>
<div class="grid" id="list"></div></div>
<div id="toasts" aria-live="polite"></div>
'''
PAGE_MAIN += '''
<dialog id="dAdd" aria-labelledby="dAddH"><form id="fAdd" method="dialog"><div class="dh" id="dAddH">添加节点</div><div class="db">
<label for="aName">节点名称（字母/数字/下划线/连字符，最多 32 位）</label><input id="aName" name="name" required maxlength="32" pattern="[A-Za-z0-9_-]{1,32}" placeholder="如 LA2" autocomplete="off">
<label for="aKind">落地机接入方式</label><select id="aKind" name="kind"><option value="reverse">VLESS 反向（默认，一条 TCP 长连接）</option><option value="wg">WireGuard（UDP，每条连接各走各的）</option></select>
<p class="mut" id="aKindH" style="font-size:13px;margin:4px 0 0">落地机主动拨入转发机的反代口（TCP），落地机零入站。</p>
<label for="aPort">入口端口（留空 = 与主入口共用 <span id="defPort"></span>）</label><input id="aPort" name="port" inputmode="numeric" pattern="[0-9]{1,5}" placeholder="留空即可">
<label for="aSni">伪装域名（只在单独端口时生效；共用端口时沿用主入口的 <span id="defSni"></span>）</label><select id="aSni" name="sni"></select>
<div id="aCustW" hidden><label for="aCust">自定义域名（需支持 TLS 1.3）</label><input id="aCust" placeholder="www.example.com" autocomplete="off"></div>
<hr style="border:none;border-top:1px solid var(--line);margin:16px 0 4px">
<p class="mut" style="font-size:13px;margin:0 0 4px"><b>出口机（落地机）SSH—可不填</b><br>
填了就直接 SSH 上去装；不填就只生成一键代码，你自己去跑。凭据只用于本次安装，面板不保存。</p>
<label for="aSshHost">出口机 IP / 域名（留空 = 只生成一键代码）</label><input id="aSshHost" placeholder="如 1.2.3.4" autocomplete="off">
<div id="aSshW" hidden>
<p class="mut" style="font-size:12px;margin:0 0 6px">非 root 用户需要 sudo 权限：填了密码会用同一密码提权；只填私钥时，要求该用户已配置免密 sudo。</p>
<div style="display:flex;gap:8px"><div style="flex:2"><label for="aSshUser">用户名（非 root 需 sudo）</label><input id="aSshUser" value="root" autocomplete="off"></div>
<div style="flex:1"><label for="aSshPort">SSH 端口</label><input id="aSshPort" value="22" inputmode="numeric" pattern="[0-9]{1,5}"></div></div>
<label for="aSshPass">密码（有私钥就不用填）</label><input id="aSshPass" type="password" autocomplete="new-password">
<label for="aSshKey">或贴私钥（与密码二选一，优先用私钥）</label>
<textarea id="aSshKey" rows="3" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----" autocomplete="off" style="width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--bg);font-family:ui-monospace,monospace;font-size:12px"></textarea>
</div>
<p class="mut" style="font-size:13px">添加会重启 att-tunnel，已有连接断开几秒。失败会自动回滚。</p></div>
<div class="df"><button class="btn" type="button" data-close>取消</button><button class="btn p" type="submit" id="aGo">添加</button></div></form></dialog>
<dialog id="dRes" aria-labelledby="dResH"><div class="dh" id="dResH">节点信息</div><div class="db" id="resB"></div>
<div class="df"><button class="btn p" type="button" data-close>关闭</button></div></dialog>
<dialog id="dDel" aria-labelledby="dDelH"><form id="fDel" method="dialog"><div class="dh" id="dDelH">删除节点</div><div class="db">
<p>删除后节点 <b id="delN"></b> 的分享链接立即失效，它的出口机会失去连接（需自己去出口机卸载）。</p>
<label for="delIn">请输入节点名确认</label><input id="delIn" autocomplete="off" required></div>
<div class="df"><button class="btn" type="button" data-close>取消</button><button class="btn d" type="submit" id="delGo" disabled>删除</button></div></form></dialog>
<dialog id="dOut" aria-labelledby="dOutH"><div class="dh err" id="dOutH">操作失败</div><div class="db"><p id="outMsg"></p><pre class="out" id="outTxt"></pre></div>
<div class="df"><button class="btn p" type="button" data-close>关闭</button></div></dialog>
<script>
/* qrcodegen (Nayuki, MIT) */"use strict";var qrcodegen;!function(t){class e{constructor(t,r,n,s){if(this.version=t,this.errorCorrectionLevel=r,this.modules=[],this.isFunction=[],t<e.MIN_VERSION||t>e.MAX_VERSION)throw new RangeError("Version value out of range");if(s<-1||s>7)throw new RangeError("Mask value out of range");this.size=4*t+17;let i=[];for(let t=0;t<this.size;t++)i.push(!1);for(let t=0;t<this.size;t++)this.modules.push(i.slice()),this.isFunction.push(i.slice());this.drawFunctionPatterns();const a=this.addEccAndInterleave(n);if(this.drawCodewords(a),-1==s){let t=1e9;for(let e=0;e<8;e++){this.applyMask(e),this.drawFormatBits(e);const r=this.getPenaltyScore();r<t&&(s=e,t=r),this.applyMask(e)}}o(0<=s&&s<=7),this.mask=s,this.applyMask(s),this.drawFormatBits(s),this.isFunction=[]}static encodeText(r,n){const o=t.QrSegment.makeSegments(r);return e.encodeSegments(o,n)}static encodeBinary(r,n){const o=t.QrSegment.makeBytes(r);return e.encodeSegments([o],n)}static encodeSegments(t,n,i=1,a=40,l=-1,h=!0){if(!(e.MIN_VERSION<=i&&i<=a&&a<=e.MAX_VERSION)||l<-1||l>7)throw new RangeError("Invalid value");let u,c;for(u=i;;u++){const r=8*e.getNumDataCodewords(u,n),o=s.getTotalBits(t,u);if(o<=r){c=o;break}if(u>=a)throw new RangeError("Data too long")}for(const t of[e.Ecc.MEDIUM,e.Ecc.QUARTILE,e.Ecc.HIGH])h&&c<=8*e.getNumDataCodewords(u,t)&&(n=t);let d=[];for(const e of t){r(e.mode.modeBits,4,d),r(e.numChars,e.mode.numCharCountBits(u),d);for(const t of e.getData())d.push(t)}o(d.length==c);const f=8*e.getNumDataCodewords(u,n);o(d.length<=f),r(0,Math.min(4,f-d.length),d),r(0,(8-d.length%8)%8,d),o(d.length%8==0);for(let t=236;d.length<f;t^=253)r(t,8,d);let m=[];for(;8*m.length<d.length;)m.push(0);return d.forEach((t,e)=>m[e>>>3]|=t<<7-(7&e)),new e(u,n,m,l)}getModule(t,e){return 0<=t&&t<this.size&&0<=e&&e<this.size&&this.modules[e][t]}drawFunctionPatterns(){for(let t=0;t<this.size;t++)this.setFunctionModule(6,t,t%2==0),this.setFunctionModule(t,6,t%2==0);this.drawFinderPattern(3,3),this.drawFinderPattern(this.size-4,3),this.drawFinderPattern(3,this.size-4);const t=this.getAlignmentPatternPositions(),e=t.length;for(let r=0;r<e;r++)for(let n=0;n<e;n++)0==r&&0==n||0==r&&n==e-1||r==e-1&&0==n||this.drawAlignmentPattern(t[r],t[n]);this.drawFormatBits(0),this.drawVersion()}drawFormatBits(t){const e=this.errorCorrectionLevel.formatBits<<3|t;let r=e;for(let t=0;t<10;t++)r=r<<1^1335*(r>>>9);const s=21522^(e<<10|r);o(s>>>15==0);for(let t=0;t<=5;t++)this.setFunctionModule(8,t,n(s,t));this.setFunctionModule(8,7,n(s,6)),this.setFunctionModule(8,8,n(s,7)),this.setFunctionModule(7,8,n(s,8));for(let t=9;t<15;t++)this.setFunctionModule(14-t,8,n(s,t));for(let t=0;t<8;t++)this.setFunctionModule(this.size-1-t,8,n(s,t));for(let t=8;t<15;t++)this.setFunctionModule(8,this.size-15+t,n(s,t));this.setFunctionModule(8,this.size-8,!0)}drawVersion(){if(this.version<7)return;let t=this.version;for(let e=0;e<12;e++)t=t<<1^7973*(t>>>11);const e=this.version<<12|t;o(e>>>18==0);for(let t=0;t<18;t++){const r=n(e,t),o=this.size-11+t%3,s=Math.floor(t/3);this.setFunctionModule(o,s,r),this.setFunctionModule(s,o,r)}}drawFinderPattern(t,e){for(let r=-4;r<=4;r++)for(let n=-4;n<=4;n++){const o=Math.max(Math.abs(n),Math.abs(r)),s=t+n,i=e+r;0<=s&&s<this.size&&0<=i&&i<this.size&&this.setFunctionModule(s,i,2!=o&&4!=o)}}drawAlignmentPattern(t,e){for(let r=-2;r<=2;r++)for(let n=-2;n<=2;n++)this.setFunctionModule(t+n,e+r,1!=Math.max(Math.abs(n),Math.abs(r)))}setFunctionModule(t,e,r){this.modules[e][t]=r,this.isFunction[e][t]=!0}addEccAndInterleave(t){const r=this.version,n=this.errorCorrectionLevel;if(t.length!=e.getNumDataCodewords(r,n))throw new RangeError("Invalid argument");const s=e.NUM_ERROR_CORRECTION_BLOCKS[n.ordinal][r],i=e.ECC_CODEWORDS_PER_BLOCK[n.ordinal][r],a=Math.floor(e.getNumRawDataModules(r)/8),l=s-a%s,h=Math.floor(a/s);let u=[];const c=e.reedSolomonComputeDivisor(i);for(let r=0,n=0;r<s;r++){let o=t.slice(n,n+h-i+(r<l?0:1));n+=o.length;const s=e.reedSolomonComputeRemainder(o,c);r<l&&o.push(0),u.push(o.concat(s))}let d=[];for(let t=0;t<u[0].length;t++)u.forEach((e,r)=>{(t!=h-i||r>=l)&&d.push(e[t])});return o(d.length==a),d}drawCodewords(t){if(t.length!=Math.floor(e.getNumRawDataModules(this.version)/8))throw new RangeError("Invalid argument");let r=0;for(let e=this.size-1;e>=1;e-=2){6==e&&(e=5);for(let o=0;o<this.size;o++)for(let s=0;s<2;s++){const i=e-s,a=!(e+1&2)?this.size-1-o:o;!this.isFunction[a][i]&&r<8*t.length&&(this.modules[a][i]=n(t[r>>>3],7-(7&r)),r++)}}o(r==8*t.length)}applyMask(t){if(t<0||t>7)throw new RangeError("Mask value out of range");for(let e=0;e<this.size;e++)for(let r=0;r<this.size;r++){let n;switch(t){case 0:n=(r+e)%2==0;break;case 1:n=e%2==0;break;case 2:n=r%3==0;break;case 3:n=(r+e)%3==0;break;case 4:n=(Math.floor(r/3)+Math.floor(e/2))%2==0;break;case 5:n=r*e%2+r*e%3==0;break;case 6:n=(r*e%2+r*e%3)%2==0;break;case 7:n=((r+e)%2+r*e%3)%2==0;break;default:throw new Error("Unreachable")}!this.isFunction[e][r]&&n&&(this.modules[e][r]=!this.modules[e][r])}}getPenaltyScore(){let t=0;for(let r=0;r<this.size;r++){let n=!1,o=0,s=[0,0,0,0,0,0,0];for(let i=0;i<this.size;i++)this.modules[r][i]==n?(o++,5==o?t+=e.PENALTY_N1:o>5&&t++):(this.finderPenaltyAddHistory(o,s),n||(t+=this.finderPenaltyCountPatterns(s)*e.PENALTY_N3),n=this.modules[r][i],o=1);t+=this.finderPenaltyTerminateAndCount(n,o,s)*e.PENALTY_N3}for(let r=0;r<this.size;r++){let n=!1,o=0,s=[0,0,0,0,0,0,0];for(let i=0;i<this.size;i++)this.modules[i][r]==n?(o++,5==o?t+=e.PENALTY_N1:o>5&&t++):(this.finderPenaltyAddHistory(o,s),n||(t+=this.finderPenaltyCountPatterns(s)*e.PENALTY_N3),n=this.modules[i][r],o=1);t+=this.finderPenaltyTerminateAndCount(n,o,s)*e.PENALTY_N3}for(let r=0;r<this.size-1;r++)for(let n=0;n<this.size-1;n++){const o=this.modules[r][n];o==this.modules[r][n+1]&&o==this.modules[r+1][n]&&o==this.modules[r+1][n+1]&&(t+=e.PENALTY_N2)}let r=0;for(const t of this.modules)r=t.reduce((t,e)=>t+(e?1:0),r);const n=this.size*this.size,s=Math.ceil(Math.abs(20*r-10*n)/n)-1;return o(0<=s&&s<=9),t+=s*e.PENALTY_N4,o(0<=t&&t<=2568888),t}getAlignmentPatternPositions(){if(1==this.version)return[];{const t=Math.floor(this.version/7)+2,e=32==this.version?26:2*Math.ceil((4*this.version+4)/(2*t-2));let r=[6];for(let n=this.size-7;r.length<t;n-=e)r.splice(1,0,n);return r}}static getNumRawDataModules(t){if(t<e.MIN_VERSION||t>e.MAX_VERSION)throw new RangeError("Version number out of range");let r=(16*t+128)*t+64;if(t>=2){const e=Math.floor(t/7)+2;r-=(25*e-10)*e-55,t>=7&&(r-=36)}return o(208<=r&&r<=29648),r}static getNumDataCodewords(t,r){return Math.floor(e.getNumRawDataModules(t)/8)-e.ECC_CODEWORDS_PER_BLOCK[r.ordinal][t]*e.NUM_ERROR_CORRECTION_BLOCKS[r.ordinal][t]}static reedSolomonComputeDivisor(t){if(t<1||t>255)throw new RangeError("Degree out of range");let r=[];for(let e=0;e<t-1;e++)r.push(0);r.push(1);let n=1;for(let o=0;o<t;o++){for(let t=0;t<r.length;t++)r[t]=e.reedSolomonMultiply(r[t],n),t+1<r.length&&(r[t]^=r[t+1]);n=e.reedSolomonMultiply(n,2)}return r}static reedSolomonComputeRemainder(t,r){let n=r.map(t=>0);for(const o of t){const t=o^n.shift();n.push(0),r.forEach((r,o)=>n[o]^=e.reedSolomonMultiply(r,t))}return n}static reedSolomonMultiply(t,e){if(t>>>8!=0||e>>>8!=0)throw new RangeError("Byte out of range");let r=0;for(let n=7;n>=0;n--)r=r<<1^285*(r>>>7),r^=(e>>>n&1)*t;return o(r>>>8==0),r}finderPenaltyCountPatterns(t){const e=t[1];o(e<=3*this.size);const r=e>0&&t[2]==e&&t[3]==3*e&&t[4]==e&&t[5]==e;return(r&&t[0]>=4*e&&t[6]>=e?1:0)+(r&&t[6]>=4*e&&t[0]>=e?1:0)}finderPenaltyTerminateAndCount(t,e,r){return t&&(this.finderPenaltyAddHistory(e,r),e=0),e+=this.size,this.finderPenaltyAddHistory(e,r),this.finderPenaltyCountPatterns(r)}finderPenaltyAddHistory(t,e){0==e[0]&&(t+=this.size),e.pop(),e.unshift(t)}}function r(t,e,r){if(e<0||e>31||t>>>e!=0)throw new RangeError("Value out of range");for(let n=e-1;n>=0;n--)r.push(t>>>n&1)}function n(t,e){return!!(t>>>e&1)}function o(t){if(!t)throw new Error("Assertion error")}e.MIN_VERSION=1,e.MAX_VERSION=40,e.PENALTY_N1=3,e.PENALTY_N2=3,e.PENALTY_N3=40,e.PENALTY_N4=10,e.ECC_CODEWORDS_PER_BLOCK=[[-1,7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],[-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28],[-1,13,22,18,26,18,24,18,22,20,24,28,26,24,20,30,24,28,28,26,30,28,30,30,30,30,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],[-1,17,28,22,16,22,28,26,26,24,28,24,28,22,24,24,30,28,28,26,28,30,24,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30]],e.NUM_ERROR_CORRECTION_BLOCKS=[[-1,1,1,1,1,1,2,2,2,2,4,4,4,4,4,6,6,6,6,7,8,8,9,9,10,12,12,12,13,14,15,16,17,18,19,19,20,21,22,24,25],[-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49],[-1,1,1,2,2,4,4,6,6,8,8,8,10,12,16,12,17,16,18,21,20,23,23,25,27,29,34,34,35,38,40,43,45,48,51,53,56,59,62,65,68],[-1,1,1,2,4,4,4,5,6,8,8,11,11,16,16,18,16,19,21,25,25,25,34,30,32,35,37,40,42,45,48,51,54,57,60,63,66,70,74,77,81]],t.QrCode=e;class s{constructor(t,e,r){if(this.mode=t,this.numChars=e,this.bitData=r,e<0)throw new RangeError("Invalid argument");this.bitData=r.slice()}static makeBytes(t){let e=[];for(const n of t)r(n,8,e);return new s(s.Mode.BYTE,t.length,e)}static makeNumeric(t){if(!s.isNumeric(t))throw new RangeError("String contains non-numeric characters");let e=[];for(let n=0;n<t.length;){const o=Math.min(t.length-n,3);r(parseInt(t.substr(n,o),10),3*o+1,e),n+=o}return new s(s.Mode.NUMERIC,t.length,e)}static makeAlphanumeric(t){if(!s.isAlphanumeric(t))throw new RangeError("String contains unencodable characters in alphanumeric mode");let e,n=[];for(e=0;e+2<=t.length;e+=2){let o=45*s.ALPHANUMERIC_CHARSET.indexOf(t.charAt(e));o+=s.ALPHANUMERIC_CHARSET.indexOf(t.charAt(e+1)),r(o,11,n)}return e<t.length&&r(s.ALPHANUMERIC_CHARSET.indexOf(t.charAt(e)),6,n),new s(s.Mode.ALPHANUMERIC,t.length,n)}static makeSegments(t){return""==t?[]:s.isNumeric(t)?[s.makeNumeric(t)]:s.isAlphanumeric(t)?[s.makeAlphanumeric(t)]:[s.makeBytes(s.toUtf8ByteArray(t))]}static makeEci(t){let e=[];if(t<0)throw new RangeError("ECI assignment value out of range");if(t<128)r(t,8,e);else if(t<16384)r(2,2,e),r(t,14,e);else{if(!(t<1e6))throw new RangeError("ECI assignment value out of range");r(6,3,e),r(t,21,e)}return new s(s.Mode.ECI,0,e)}static isNumeric(t){return s.NUMERIC_REGEX.test(t)}static isAlphanumeric(t){return s.ALPHANUMERIC_REGEX.test(t)}getData(){return this.bitData.slice()}static getTotalBits(t,e){let r=0;for(const n of t){const t=n.mode.numCharCountBits(e);if(n.numChars>=1<<t)return 1/0;r+=4+t+n.bitData.length}return r}static toUtf8ByteArray(t){t=encodeURI(t);let e=[];for(let r=0;r<t.length;r++)"%"!=t.charAt(r)?e.push(t.charCodeAt(r)):(e.push(parseInt(t.substr(r+1,2),16)),r+=2);return e}}s.NUMERIC_REGEX=/^[0-9]*$/,s.ALPHANUMERIC_REGEX=/^[A-Z0-9 $%*+.\\/:-]*$/,s.ALPHANUMERIC_CHARSET="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:",t.QrSegment=s}(qrcodegen||(qrcodegen={})),function(t){!function(t){class e{constructor(t,e){this.ordinal=t,this.formatBits=e}}e.LOW=new e(0,1),e.MEDIUM=new e(1,0),e.QUARTILE=new e(2,3),e.HIGH=new e(3,2),t.Ecc=e}(t.QrCode||(t.QrCode={}))}(qrcodegen||(qrcodegen={})),function(t){!function(t){class e{constructor(t,e){this.modeBits=t,this.numBitsCharCount=e}numCharCountBits(t){return this.numBitsCharCount[Math.floor((t+7)/17)]}}e.NUMERIC=new e(1,[10,12,14]),e.ALPHANUMERIC=new e(2,[9,11,13]),e.BYTE=new e(4,[8,16,16]),e.KANJI=new e(8,[8,10,12]),e.ECI=new e(7,[0,0,0]),t.Mode=e}(t.QrSegment||(t.QrSegment={}))}(qrcodegen||(qrcodegen={}));
const P="{P}",C="{C}",SNIS={SNIS};let D=null,busy=false;
const $=i=>document.getElementById(i);
function fb(n){n=+n||0;const u=["B","KB","MB","GB","TB","PB"];let i=0;while(n>=1024&&i<5){n/=1024;i++}return(i?n.toFixed(n<10?2:n<100?1:0):n)+" "+u[i]}
function ago(t){if(!t)return"从未";const s=Math.max(0,Math.floor(Date.now()/1000)-t);if(s<60)return s+" 秒前";if(s<3600)return Math.floor(s/60)+" 分钟前";if(s<86400)return Math.floor(s/3600)+" 小时前";return new Date(t*1000).toLocaleString("zh-CN",{hour12:false})}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function toast(m,k){const e=document.createElement("div");e.className="toast "+(k||"");e.textContent=m;$("toasts").appendChild(e);setTimeout(()=>e.remove(),k=="bad"?7000:3500)}
function fail(msg,out){$("outMsg").textContent=msg;$("outTxt").textContent=out||"";$("outTxt").hidden=!out;$("dOut").showModal()}
async function post(u,body){const r=await fetch(P+u,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded","X-CSRF-Token":C},body:new URLSearchParams(body||{})});
if(r.status==401){location.href=P+"/";throw new Error("登录已过期")}let j={};try{j=await r.json()}catch(e){}if(!r.ok||!j.ok){const e=new Error(j.error||("HTTP "+r.status));e.out=j.output||"";throw e}return j}
function spark(h){if(!h||h.length<2)return"";const m=Math.max(1,...h),w=100/(h.length-1);return`<svg class="spark" viewBox="0 0 100 34" preserveAspectRatio="none" aria-hidden="true"><path d="${h.map((v,i)=>(i?"L":"M")+(i*w).toFixed(1)+" "+(32-v/m*30).toFixed(1)).join(" ")}"/></svg>`}
'''
PAGE_MAIN += '''
function render(d){D=d;busy=d.busy;
$("ver").textContent="v"+d.version;
const xs=d.xray_active?'<span class="pill on">xray 运行中</span>':'<span class="pill off">xray 未运行</span>';
$("hinfo").innerHTML=`<span>A 机 <b class="mono">${esc(d.a_ip)}</b></span><span>反代口 ${esc(d.reverse_port)}</span><span>隧道连接 ${d.tunnels}</span>${d.wg?`<span>WireGuard UDP ${esc(d.wg.port)} · 握手 ${d.wg.up} / ${d.wg.peers}</span>`:""}${xs}`;
const e=$("err");if(d.error){e.style.display="block";e.textContent="⚠ 统计异常："+d.error}else e.style.display="none";
const on=d.nodes.filter(n=>n.online).length,up=d.nodes.reduce((a,n)=>a+n.up,0),dn=d.nodes.reduce((a,n)=>a+n.down,0);
$("sum").innerHTML=[["节点",d.nodes.length],["在线",on+" / "+d.nodes.length],["总上传",fb(up)],["总下载",fb(dn)],["总流量",fb(up+dn)]].map(x=>`<div class="card"><span class="mut">${x[0]}</span><b>${x[1]}</b></div>`).join("");
const age=d.last_poll?d.now-d.last_poll:-1;
$("meta").textContent=d.last_poll?("流量更新于 "+ago(d.last_poll)+"（每 "+d.poll+" 秒）"+(age>3*d.poll+5?" · 已停止更新！":"")):"尚未取到流量";
const mx=Math.max(1,...d.nodes.map(n=>n.total));
$("list").innerHTML=d.nodes.map(n=>{const st=n.online?'<span class="pill on">在线</span>':(n.probe_ts?'<span class="pill off">离线</span>':'<span class="pill w">待探测</span>');
return`<section class="card node"><h2><span>${esc(n.name)}</span>${st}</h2><dl class="kv">
<dt>出口 IP</dt><dd class="mono">${esc(n.ip||"—")}</dd><dt>最后探测</dt><dd>${ago(n.probe_ts)}${n.ip_ts&&!n.online?" · 上次在线 "+ago(n.ip_ts):""}</dd>
<dt>入口</dt><dd>${esc(n.port)} · ${esc(n.sni)}</dd><dt>出口绑定</dt><dd>${esc(n.exit||"未绑定")}${n.exit?(n.kind=="wg"?" · WireGuard":" · VLESS 反向"):""}${n.shared?" ⚠ 共用":""}</dd></dl>
${(!n.online&&n.probe_err)?`<div class="err" style="font-size:13px">${esc(n.probe_err)}</div>`:""}
<div class="tr"><div><small>↑ 上传</small><b>${fb(n.up)}</b><small>${fb(n.rate_up)}/s</small></div><div><small>↓ 下载</small><b>${fb(n.down)}</b><small>${fb(n.rate_down)}/s</small></div></div>
<div class="barw" title="占全部节点最大值的比例"><div class="bar" style="width:${(n.total/mx*100).toFixed(1)}%"></div></div>
<div class="mut" style="font-size:12px">合计 ${fb(n.total)} · 自 ${ago(n.since)}</div>${spark(n.hist)}
<div class="nact">${d.manage?`<button class="btn s" data-a="link" data-n="${esc(n.name)}" type="button">查看链接 / 出口命令</button>`:""}
<button class="btn s" data-a="probe" data-n="${esc(n.name)}" type="button">探测</button>
<button class="btn s" data-a="reset" data-n="${esc(n.name)}" type="button">清零</button>
${d.manage?`<button class="btn s d" data-a="del" data-n="${esc(n.name)}" type="button">删除</button>`:""}</div></section>`}).join("")||'<div class="card empty mut">还没有节点</div>';
$("bAdd").hidden=!d.manage;$("bAdd").disabled=busy}
async function load(){try{const r=await fetch(P+"/api/status",{cache:"no-store"});if(r.status==401){location.href=P+"/";return}render(await r.json())}catch(e){toast("加载失败："+e.message,"bad")}}
function cp(t,b){(navigator.clipboard?navigator.clipboard.writeText(t):Promise.reject()).then(()=>toast("已复制","ok"),()=>{const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();try{document.execCommand("copy");toast("已复制","ok")}catch(e){toast("复制失败，请手动选择","bad")}a.remove()})}
function qrPng(t){const q=qrcodegen.QrCode.encodeText(t,qrcodegen.QrCode.Ecc.MEDIUM),b=4,z=8,n=(q.size+2*b)*z,c=document.createElement("canvas");c.width=c.height=n;
const g=c.getContext("2d");g.fillStyle="#fff";g.fillRect(0,0,n,n);g.fillStyle="#000";for(let y=0;y<q.size;y++)for(let x=0;x<q.size;x++)if(q.getModule(x,y))g.fillRect((x+b)*z,(y+b)*z,z,z);return c.toDataURL("image/png")}
function qrFig(id,cap,file){return`<figure><img id="${id}" alt="${esc(cap)}"><figcaption>${esc(cap)} · <a id="${id}d" href="#" download="${esc(file)}">下载图片</a></figcaption></figure>`}
function qrSet(id,t){try{const u=qrPng(t);$(id).src=u;$(id+"d").href=u}catch(e){$(id).replaceWith(Object.assign(document.createElement("p"),{className:"err",textContent:"生成二维码失败："+e.message}))}}
function showRes(j,title){$("dResH").textContent=title;const nm=j.name||"node",ok=String(j.link||"").startsWith("vless://"),su=j.sub_token?location.origin+P+"/sub/"+encodeURIComponent(j.sub_token):"";
$("resB").innerHTML=`<label>节点链接（导入后核对 flow=xtls-rprx-vision）</label><div class="copy"><span class="mono" id="rL"></span><button class="btn s" type="button" id="cL">复制</button></div>
${su?`<label>订阅链接（客户端里「添加订阅 / 从 URL 导入」）</label><div class="copy"><span class="mono" id="rS"></span><button class="btn s" type="button" id="cS">复制</button></div>`:""}
${ok?`<div class="qrs">${qrFig("qL","节点链接二维码",nm+"-节点.png")}${su?qrFig("qS","订阅链接二维码",nm+"-订阅.png"):""}</div>`:""}
<label>到这个节点的出口机（B）上执行</label><div class="copy"><span class="mono" id="rC"></span><button class="btn s" type="button" id="cC">复制</button></div>
<p class="err" style="font-size:13px">链接、二维码和命令都含密钥，只在自己设备间使用。</p>`;$("rL").textContent=j.link;$("rC").textContent=j.exit_cmd;
$("cL").onclick=()=>cp(j.link);$("cC").onclick=()=>cp(j.exit_cmd);
if(su){$("rS").textContent=su;$("cS").onclick=()=>cp(su)}
if(ok){qrSet("qL",j.link);if(su)qrSet("qS",su)}
if(j.ssh_job){const d=document.createElement("div");d.id="sshBox";
  d.innerHTML='<label>SSH 直装出口机 '+esc(j.ssh_target||"")+'</label>'
    +'<p class="mono" id="sshState" style="margin:4px 0">正在连接…</p>'
    +'<pre class="out" id="sshOut" hidden></pre>'
    +'<p class="mut" style="font-size:13px">装出口机首次要下 xray，可能要几分钟。关掉这个窗口也不会中断，上面的命令仍可备用。</p>';
  $("resB").appendChild(d)}
else if(j.ssh_error){const d=document.createElement("p");d.className="err";d.style.fontSize="13px";
  d.textContent="SSH 安装没能开始："+j.ssh_error;$("resB").appendChild(d)}
$("dRes").showModal()}
async function pollSsh(job){
  for(let i=0;i<200;i++){
    await new Promise(r=>setTimeout(r,i<3?2000:5000));
    let j;
    try{j=await post("/api/ssh-status",{job})}catch(x){
      const s=$("sshState");if(s)s.textContent="读取进度失败："+x.message;return}
    const s=$("sshState");
    if(s)s.textContent=j.state||"";
    if(j.done){
      const o=$("sshOut");
      if(o&&j.output){o.hidden=false;o.textContent=j.output}
      if(j.rc===0){toast("出口机 "+j.node+" 已装好","ok")}
      else{toast("出口机安装失败，请用上面的一键代码手动装","bad")}
      load();return}
  }
}
document.querySelectorAll("[data-close]").forEach(b=>b.onclick=()=>b.closest("dialog").close());
$("list").addEventListener("click",async e=>{const b=e.target.closest("button[data-a]");if(!b)return;const a=b.dataset.a,n=b.dataset.n;
try{if(a=="link"){if(!confirm("显示节点 "+n+" 的分享链接和出口机命令？\\n含密钥，注意身边没人看屏幕。"))return;b.disabled=true;showRes(await post("/api/link",{node:n}),"节点 "+n)}
else if(a=="probe"){b.disabled=true;b.textContent="探测中…";await post("/api/probe",{node:n});toast("已探测 "+n,"ok");load()}
else if(a=="reset"){if(!confirm("把节点 "+n+" 的累计流量清零？"))return;await post("/api/reset",{node:n});toast("已清零","ok");load()}
else if(a=="del"){$("delN").textContent=n;$("delIn").value="";$("delGo").disabled=true;$("fDel").dataset.n=n;$("dDel").showModal();$("delIn").focus()}}
catch(x){fail(x.message,x.out)}finally{b.disabled=false}});
$("delIn").oninput=()=>{$("delGo").disabled=$("delIn").value!==$("fDel").dataset.n};
$("fDel").onsubmit=async ev=>{ev.preventDefault();const n=$("fDel").dataset.n;if($("delIn").value!==n)return;$("delGo").disabled=true;$("delGo").textContent="删除中…";
try{await post("/api/del",{node:n,confirm:$("delIn").value});$("dDel").close();toast("节点 "+n+" 已删除","ok")}catch(x){$("dDel").close();fail("删除失败："+x.message,x.out)}
finally{$("delGo").textContent="删除";load()}};
$("aSni").innerHTML='<option value="">沿用主入口</option>'+SNIS.map(s=>`<option value="${esc(s[0])}">${esc(s[0])}（${esc(s[1])}）</option>`).join("")+'<option value="__c">自定义…</option>';
$("aSni").onchange=()=>{$("aCustW").hidden=$("aSni").value!="__c"};
$("aSshHost").oninput=()=>{$("aSshW").hidden=!$("aSshHost").value.trim()};
const KH={reverse:"落地机主动拨入转发机的反代口（TCP），落地机零入站。",wg:"落地机用 WireGuard 主动拨入转发机（UDP，落地机零入站）。转发机安全组要放行 WireGuard 的 UDP 端口（首个 WG 节点建好后显示在顶部）。"};
$("aKind").onchange=()=>{$("aKindH").textContent=KH[$("aKind").value]||""};
$("bAdd").onclick=()=>{const m=D&&D.nodes[0];$("defPort").textContent=m?m.port:"";$("defSni").textContent=m?m.sni:"";$("fAdd").reset();$("aKindH").textContent=KH.reverse;$("aCustW").hidden=true;$("aSshW").hidden=true;$("aSshUser").value="root";$("aSshPort").value="22";$("dAdd").showModal();$("aName").focus()};
$("fAdd").onsubmit=async ev=>{ev.preventDefault();const name=$("aName").value.trim(),port=$("aPort").value.trim();let sni=$("aSni").value;if(sni=="__c")sni=$("aCust").value.trim();
if(!/^[A-Za-z0-9_-]{1,32}$/.test(name)){toast("节点名只能用字母/数字/下划线/连字符，最多 32 位","bad");return}
if(port&&!(/^[0-9]+$/.test(port)&&+port>=1&&+port<=65535)){toast("端口必须是 1-65535","bad");return}
if(sni&&!/^[A-Za-z0-9.-]+$/.test(sni)){toast("域名格式不对","bad");return}
const sshHost=$("aSshHost").value.trim(),sshUser=$("aSshUser").value.trim()||"root",
  sshPort=$("aSshPort").value.trim()||"22",sshPass=$("aSshPass").value,sshKey=$("aSshKey").value.trim();
if(sshHost){
  if(!/^[A-Za-z0-9._\-\[\]:]{3,253}$/.test(sshHost)){toast("SSH 主机格式不对","bad");return}
  if(!/^[A-Za-z0-9._-]{1,32}$/.test(sshUser)){toast("SSH 用户名格式不对","bad");return}
  if(!(/^[0-9]+$/.test(sshPort)&&+sshPort>=1&&+sshPort<=65535)){toast("SSH 端口必须是 1-65535","bad");return}
  if(!sshPass&&!sshKey){toast("填了 SSH 主机就要给密码或私钥","bad");return}
}
$("aGo").disabled=true;$("aGo").textContent="添加中…（约 10 秒）";
const kind=$("aKind").value;
try{const j=await post("/api/add",{name,port,sni,kind,ssh_host:sshHost,ssh_user:sshUser,
  ssh_port:sshPort,ssh_pass:sshPass,ssh_key:sshKey});
$("dAdd").close();toast("节点 "+name+" 已添加","ok");
$("aSshPass").value="";$("aSshKey").value="";
showRes(j,"新节点 "+name+" 已添加");if(j.ssh_job)pollSsh(j.ssh_job)}
catch(x){fail("添加失败："+x.message,x.out)}finally{$("aGo").disabled=false;$("aGo").textContent="添加";load()}};
$("bRef").onclick=load;
$("bProbe").onclick=async e=>{const b=e.target;b.disabled=true;b.textContent="探测中…";try{await post("/api/probe",{});toast("探测完成","ok")}catch(x){toast(x.message,"bad")}b.disabled=false;b.textContent="立即探测";load()};
load();setInterval(load,12000);
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
                         "img-src data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(b)

    def jsend(self, code, obj):
        return self.send(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

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

    def login_page(self, code, msg=''):
        e = '<p class="err">%s</p>' % msg if msg else ''
        return self.send(code, PAGE_LOGIN.replace('{CSS}', CSS).replace('{P}', PREFIX).replace('{E}', e))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        if r.startswith('/sub/'):
            return self.do_sub(r[5:])
        sid, s = self.session()
        if r == '/':
            if not s:
                return self.login_page(200)
            page = (PAGE_MAIN.replace('{CSS}', CSS).replace('{P}', PREFIX).replace('{C}', s['csrf'])
                    .replace('{SNIS}', json.dumps(SNI_PRESETS, ensure_ascii=False)))
            return self.send(200, page)
        if r == '/api/status':
            if not s:
                return self.jsend(401, {'error': 'unauthorized'})
            return self.jsend(200, status_json())
        return self.send(404, 'Not Found', 'text/plain')

    def do_sub(self, tok):
        """订阅（免登录，靠 token）：返回 base64(vless 链接)，v2rayN / Shadowrocket 等通用格式。"""
        n = sub_node(tok)
        if not n:
            time.sleep(0.3)
            return self.send(404, 'Not Found', 'text/plain')
        try:
            link = node_vless(n)
        except Exception as e:
            log('订阅取链接失败:', n, e)
            return self.send(503, '暂时取不到链接，请稍后再试', 'text/plain; charset=utf-8')
        body = base64.b64encode((link + '\n').encode()).decode()
        return self.send(200, body, 'text/plain; charset=utf-8',
                         [('Content-Disposition', 'inline; filename="%s.txt"' % n),
                          ('Profile-Update-Interval', '24')])

    def do_POST(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        ip = self.client_address[0]
        if r == '/__upgrade__':
            return self.do_upgrade()
        if r == '/login':
            if rate_limited(ip):
                return self.login_page(429, '失败次数过多，请 10 分钟后再试')
            f = self.form()
            if hmac.compare_digest(f.get('password', '').encode(), PASS.encode()):
                sid = new_session()
                ck = ('att_sid=%s; Path=%s; HttpOnly; SameSite=Strict; Max-Age=%d'
                      % (sid, PREFIX, SESSION_TTL))
                return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
            note_fail(ip)
            time.sleep(1)
            return self.login_page(401, '密码错误')
        sid, s = self.session()
        if not s:
            return self.jsend(401, {'error': 'unauthorized'})
        f = self.form()
        tok = self.headers.get('X-CSRF-Token') or f.get('csrf', '')
        if not hmac.compare_digest(tok.encode(), s['csrf'].encode()):
            return self.jsend(403, {'error': 'CSRF 校验失败，请刷新页面'})
        if r == '/logout':
            with lock:
                sessions.pop(sid, None)
            ck = 'att_sid=; Path=%s; HttpOnly; SameSite=Strict; Max-Age=0' % PREFIX
            return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
        n = f.get('node', '')
        if r in ('/api/reset', '/api/link', '/api/del') and n not in node_names():
            return self.jsend(404, {'error': '节点 %s 不存在' % n})
        if r == '/api/reset':
            with lock:
                rec = node_rec(n)
                rec['up'] = rec['down'] = 0
                rec['hist'] = []
                rec['since'] = now()
            safe_save()
            return self.jsend(200, {'ok': True})
        if r == '/api/probe':
            probe_all(n or None)
            return self.jsend(200, {'ok': True})
        if r == '/api/ssh-status':
            jid = f.get('job', '')
            with lock:
                j = ssh_jobs.get(jid)
                j = dict(j) if j else None
            if not j:
                return self.jsend(404, {'error': '任务不存在或已过期'})
            return self.jsend(200, {'ok': True, 'node': j['node'], 'state': j['state'],
                                    'rc': j['rc'], 'done': j['done'], 'output': j['log']})
        if r in ('/api/link', '/api/add', '/api/del') and not os.path.isfile(SCRIPT):
            return self.jsend(501, {'error': '面板未开启节点管理：请在 A 机重跑一次 --web'})
        if r == '/api/link':
            try:
                return self.jsend(200, dict(node_link(n), ok=True))
            except Exception as e:
                return self.jsend(500, {'error': '取链接失败', 'output': str(e)})
        if r == '/api/add':
            return self.do_add(f)
        if r == '/api/del':
            if f.get('confirm') != n:
                return self.jsend(400, {'error': '确认名称不一致'})
            if not mut_lock.acquire(blocking=False):
                return self.jsend(409, {'error': '另一个加/删操作正在进行，请稍后'})
            try:
                rc, out = run_script(['--del', n], {'ATT_YES': '1'})
                after_change()
            finally:
                mut_lock.release()
            if rc != 0:
                return self.jsend(500, {'error': '脚本返回 %d（配置未改动或已回滚）' % rc, 'output': out})
            return self.jsend(200, {'ok': True, 'output': out})
        return self.send(404, 'Not Found', 'text/plain')

    def do_add(self, f):
        name, port, sni = f.get('name', '').strip(), f.get('port', '').strip(), f.get('sni', '').strip()
        kind = f.get('kind', '').strip() or 'reverse'
        if kind not in ('reverse', 'wg'):
            return self.jsend(400, {'error': '出口方式只能是 VLESS 反向或 WireGuard'})
        if not NAME_RE.match(name):
            return self.jsend(400, {'error': '节点名只能用字母/数字/下划线/连字符，最多 32 位'})
        if port and not (port.isdigit() and 1 <= int(port) <= 65535):
            return self.jsend(400, {'error': '端口必须是 1-65535'})
        if sni and not SNI_RE.match(sni):
            return self.jsend(400, {'error': '伪装域名格式不对'})
        if name in node_names():
            return self.jsend(409, {'error': '节点 %s 已存在' % name})

        # SSH 直装（可选）：填了主机就装，没填就只生成一键代码
        sh = f.get('ssh_host', '').strip()
        su = f.get('ssh_user', '').strip() or 'root'
        sp = f.get('ssh_port', '').strip() or '22'
        spw = f.get('ssh_pass', '')
        skey = f.get('ssh_key', '')
        if sh:
            if not SSH_HOST_RE.match(sh):
                return self.jsend(400, {'error': 'SSH 主机格式不对'})
            if not SSH_USER_RE.match(su):
                return self.jsend(400, {'error': 'SSH 用户名格式不对'})
            if not (sp.isdigit() and 1 <= int(sp) <= 65535):
                return self.jsend(400, {'error': 'SSH 端口必须是 1-65535'})
            if not spw and not skey:
                return self.jsend(400, {'error': '填了 SSH 主机就要给密码或私钥'})
            if skey and 'PRIVATE KEY' not in skey:
                return self.jsend(400, {'error': '私钥内容不像私钥（应包含 PRIVATE KEY）'})

        if not mut_lock.acquire(blocking=False):
            return self.jsend(409, {'error': '另一个加/删操作正在进行，请稍后'})
        try:
            env = {'ATT_NODE_PORT': port, 'ATT_NODE_SNI': sni, 'ATT_NODE_KIND': kind}
            rc, out = run_script(['--add', name], env, timeout=240)
            after_change(name)
        finally:
            mut_lock.release()
        if rc != 0:
            return self.jsend(500, {'error': '脚本返回 %d（配置未改动或已回滚）' % rc, 'output': out})

        try:
            res = dict(node_link(name), ok=True, output=out)
        except Exception as e:
            res = {'ok': True, 'name': name, 'output': out,
                   'link': '（取链接失败：%s）' % e, 'exit_cmd': ''}

        # 节点已建好。填了 SSH 就后台开装：装出口机要几分钟，
        # 这一步不能卡在请求里（经 hub 代理时代理只等 280s）。
        if sh and res.get('exit_cmd'):
            jid = ssh_job_new(name)
            args = (sh, int(sp), su, spw, skey, res['exit_cmd'])
            threading.Thread(target=ssh_job_run, args=(jid, name, args),
                             daemon=True).start()
            res['ssh_job'] = jid
            res['ssh_target'] = '%s@%s:%s' % (su, sh, sp)
        elif sh:
            res['ssh_error'] = '取不到出口机命令，没法 SSH 安装，请用下面的命令手动装'
        return self.jsend(200, res)

    def do_upgrade(self):
        """响应 hub 的升级请求：重新下载并运行安装脚本的 --upgrade。
        这个路由不需要登录，hub 的请求直接到这里。
        """
        if not os.path.isfile(SCRIPT):
            return self.send(501, '面板未开启节点管理，无法升级', 'text/plain')
        # 读取安装时保存的源 URL（bash <(curl ...) 运行时脚本会保存这个）
        aenv = load_env(AENV)
        raw = aenv.get('ATT_RAW_URL', '')
        if not raw or not raw.startswith('http'):
            return self.send(500, '找不到脚本来源 URL，无法自动升级', 'text/plain')
        
        log('收到升级请求，准备从 %s 重新下载并升级' % raw)
        
        # 后台执行升级（下载 + bash script.sh --upgrade），不卡住这个请求
        def upgrade_task():
            try:
                cmd = 'curl -fsSL %s | bash -s -- --upgrade' % shlex.quote(raw)
                log('执行升级命令：%s' % cmd)
                subprocess.run(cmd, shell=True, timeout=300,
                              env=dict(os.environ, ATT_YES='1'),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                log('升级完成')
            except Exception as e:
                log('升级失败：%s' % e)
        
        threading.Thread(target=upgrade_task, daemon=True).start()
        return self.send(200, '升级已开始，约 1-2 分钟后生效', 'text/plain')


class Srv(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    load_state()
    state['started'] = now()
    log('att-tunnel 面板 v%s 启动，监听 %s:%d' % (VERSION, LISTEN, PORT))
    threading.Thread(target=worker, daemon=True).start()
    Srv((LISTEN, PORT), H).serve_forever()


if __name__ == '__main__':
    main()
ATT_WEB_PY
  sed -i "s/ATT_VERSION/$VERSION/g" "$WEB_PY.tmp"
  # 伪装域名预置列表和脚本同源（面板「添加节点」下拉框用）
  ATT_SNIS="$(printf '%s\n' "${CANDIDATES_WITH_COUNTRY[@]}")" python3 - "$WEB_PY.tmp" <<'PY' || { rm -f "$WEB_PY.tmp"; die "面板程序生成失败"; }
import json,os,sys
f=sys.argv[1]; s=open(f).read()
l=[x.split('|',1) for x in os.environ['ATT_SNIS'].splitlines() if '|' in x]
open(f,'w').write(s.replace('"ATT_SNI_PRESETS"', json.dumps(l, ensure_ascii=False), 1))
PY
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$WEB_PY.tmp" 2>/dev/null || { rm -f "$WEB_PY.tmp"; die "面板程序生成失败（python3 语法检查不通过）"; }
  chmod 700 "$WEB_PY.tmp"; mv "$WEB_PY.tmp" "$WEB_PY"
}

web_url(){
  # shellcheck disable=SC1090,SC1091
  source "$STATE/a.env"
  # shellcheck disable=SC1090,SC1091
  source "$WEB_ENV"
  echo "http://$A_IP:$WEB_PORT/$WEB_PATH/"
}

# 面板加/删节点调用的是本机脚本副本（同一套配置逻辑、校验和回滚，不在面板里重写）。
# 本地文件运行：直接复制自己；bash <(curl ...) 运行（\$0 是管道读不回来）：按 RAW_URL 重新下载，
# 并核对版本号一致，防止拉到别的分支。
install_script_copy(){
  mkdir -p "$WEB_DIR"
  local tmp; tmp=$(mktemp)
  if [ -f "$0" ] && [ -r "$0" ] && grep -q '^VERSION="'"$VERSION"'"' "$0" 2>/dev/null; then
    cp "$0" "$tmp"
  elif ! curl -fsSL --max-time 60 -o "$tmp" "$RAW_URL"; then
    rm -f "$tmp"; warn "下载脚本副本失败（$RAW_URL），面板暂不能加/删节点"; return 1
  fi
  if ! grep -q '^VERSION="'"$VERSION"'"' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "脚本副本版本与当前不一致（$RAW_URL 不是 v$VERSION），面板暂不能加/删节点"
    warn "用 ATT_RAW_URL 指向本版本的 install.sh 再跑一次 --web"
    return 1
  fi
  install -m 700 -o root -g root "$tmp" "$WEB_SCRIPT"; rm -f "$tmp"
  ok "脚本副本已更新：$WEB_SCRIPT（v$VERSION）"
}

# 把本次用的脚本地址记进 web.env，面板生成的出口机命令指向同一版本
save_web_raw_url(){
  [ -f "$WEB_ENV" ] || return 0
  sed -i '/^WEB_RAW_URL=/d' "$WEB_ENV"
  printf 'WEB_RAW_URL=%s\n' "$RAW_URL" >> "$WEB_ENV"
}

web_enable(){
  need_root
  [ -f "$STATE/a.env" ] || die "网页面板只在 A 端（入口机）上用"
  command -v python3 >/dev/null || die "缺 python3"
  command -v flock >/dev/null || die "缺 flock（util-linux）"
  # 面板「添加节点」可以填 SSH 直接装出口机：私钥用 ssh 就够，
  # 密码登录要 sshpass。装不上不影响面板，只是密码那条路不可用。
  command -v ssh >/dev/null || warn "本机没有 ssh 客户端，面板里的 SSH 直装出口机不可用"
  if ! command -v sshpass >/dev/null; then
    info "安装 sshpass（面板用 SSH 密码装出口机时需要）"
    if command -v apt-get >/dev/null; then apt-get install -y -qq sshpass >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null; then dnf install -y -q sshpass >/dev/null 2>&1 || true
    elif command -v yum >/dev/null; then yum install -y -q sshpass >/dev/null 2>&1 || true
    fi
    command -v sshpass >/dev/null \
      || warn "sshpass 没装上：面板里用密码 SSH 会提示不可用，改用私钥或一键代码即可"
  fi
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
  install_script_copy || true
  save_web_raw_url
  mkdir -p "$WEB_DATA"; chmod 700 "$WEB_DATA"
  cat > "/etc/systemd/system/$WEB_SVC.service" <<EOF
[Unit]
Description=att-tunnel 流量面板
After=network-online.target $SVC.service

[Service]
Type=simple
Environment=ATT_CFG=$CFG ATT_WEB_ENV=$WEB_ENV ATT_WEB_STATE=$WEB_DATA/web-state.json ATT_XRAY=$XRAY_BIN
Environment=ATT_SCRIPT=$WEB_SCRIPT ATT_A_ENV=$STATE/a.env ATT_SVC=$SVC
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
  [ -f "$STATE/a.env" ] && install_script_copy || true
  if systemctl is-active --quiet "$WEB_SVC" 2>/dev/null; then
    read -rp "面板运行中，关闭它？（输 yes）: " c
    [ "$c" = yes ] && web_disable || warn "未改动"
  else
    web_enable
  fi
}

# ================= 自检 =================
check_bbr(){
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  [ "$cc" = bbr ] && ok "拥塞控制 BBR" || warn "拥塞控制是 ${cc:-未知}，建议 BBR：bash install.sh --tune"
}

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
    if [ -s "$WG_STATE" ]; then
      echo
      if ip link show "$WG_IF" >/dev/null 2>&1; then
        ok "WireGuard 接口 $WG_IF 运行中（UDP $(wg_state get port)）"
        local t0 pk hs; t0=$(date +%s)
        while read -r pk hs; do
          [ -z "$pk" ] && continue
          if [ "${hs:-0}" -gt 0 ] && [ $((t0-hs)) -lt 180 ]; then
            echo "    peer ${pk:0:10}…  最近握手 $((t0-hs)) 秒前"
          else
            echo "    peer ${pk:0:10}…  ${YEL}没有握手（落地机未部署 / UDP 端口没放行）${RST}"
          fi
        done < <(wg show "$WG_IF" latest-handshakes 2>/dev/null)
      else
        echo "${RED}[X]${RST} 有 WireGuard 节点，但接口 $WG_IF 没起来：systemctl restart wg-quick@$WG_IF"
      fi
    fi
    local r2; r2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)
    [ "$r2" = 5 ] && ok "tcp_retries2=5（僵死隧道快速回收）" || warn "tcp_retries2=$r2，建议为 5"
    check_bbr
    echo; info "逐个节点验收：连上后查出口 IP，必须等于${BLD}它对应那台出口机的实时公网 IP${RST}"
    info "如果显示的是 A 的 IP（$A_IP），说明该节点的流量没进 portal"
    info "如果两个节点查出同一个出口 IP，说明它们共用了出口，不是 1:1"
  elif [ -f "$STATE/b.env" ]; then
    source "$STATE/b.env"
    if [ "${KIND:-}" = wg ]; then
      echo "角色: ${BLD}B（出口端，WireGuard）${RST}   拨向: $A_IP:$WG_PORT/udp   隧道 IP: $TUN_IP"
      local hs t0; t0=$(date +%s); hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2}' | sed -n 1p) || hs=0
      if [ "${hs:-0}" -gt 0 ] 2>/dev/null && [ $((t0-hs)) -lt 180 ]; then
        ok "WireGuard 最近握手 $((t0-hs)) 秒前"
      else
        echo "${RED}[X]${RST} WireGuard 没有握手，检查 A 侧安全组是否放行 $WG_PORT/udp"
      fi
    else
    echo "角色: ${BLD}B（出口端）${RST}   拨向: $A_IP:$REVERSE_PORT"
    if ss -tn state established 2>/dev/null | grep -q "$A_IP:$REVERSE_PORT"; then
      ok "隧道 ESTAB 正常"
    else
      echo "${RED}[X]${RST} 隧道未建立，检查 A 侧防火墙/安全组 $REVERSE_PORT/tcp"
    fi
    fi
    local listen; listen=$(ss -ltn 2>/dev/null | grep -vE '127.0.0.1|::1|State' | wc -l)
    ok "对外监听端口数（含 SSH）: $listen"
    if [ "${KIND:-}" = wg ]; then
      ok "B 的 Xray 只听隧道 IP ${TUN_IP:-?}（公网零暴露）"
    else
      grep -q '"inbounds": \[\]' "$CFG" && ok "B 无任何用户入站（零暴露）" || warn "B 端出现了 inbound，与设计不符"
    fi
    check_bbr
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
  rm -rf "/etc/systemd/system/$SVC.service.d"
  # 只停 att-tunnel 自己生成的 attwg，别的 WireGuard 不碰
  if [ -f "$WG_CONF" ] && grep -q '^# att-tunnel' "$WG_CONF" 2>/dev/null; then
    systemctl disable --now "wg-quick@$WG_IF" 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  local bdir="/root/att-tunnel-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$bdir"
  [ -f "$CFG" ] && cp "$CFG" "$bdir/" 2>/dev/null || true
  [ -d "$STATE" ] && cp -r "$STATE" "$bdir/" 2>/dev/null || true
  [ -d "$WEB_DATA" ] && cp -r "$WEB_DATA" "$bdir/" 2>/dev/null || true
  if [ -f "$WG_CONF" ] && grep -q '^# att-tunnel' "$WG_CONF" 2>/dev/null; then
    cp "$WG_CONF" "$bdir/" 2>/dev/null || true; rm -f "$WG_CONF"
  fi
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
    echo "  5) 加一个节点（选 VLESS 反向或 WireGuard，生成它专属出口机的部署命令）"
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
  --wg-bridge) need_root; deploy_wg_b "${2:-}" ;;
  --server-a) deploy_a ;;
  --check)    selfcheck ;;
  --tune)     tune_only ;;
  --links)    show_links ;;
  --add)      add_node "${2:-}" ;;
  --del|--delete|--remove) del_node "${2:-}" ;;
  --list)     show_exits ;;
  --exit-cmd) show_exit_cmd "${2:-}" ;;
  --link)     [ -n "${2:-}" ] || die "用法：--link NAME"; show_links "$2" ;;
  --migrate)  migrate_cfg ;;
  --enable-stats) enable_stats ;;
  --web)      web_enable ;;
  --web-off)  web_disable ;;
  --web-info) web_info ;;
  --version)  echo "att-tunnel v$VERSION" ;;
  "")         menu ;;
  *)          die "未知参数: $1（可用：--server-a | --bridge TOKEN | --wg-bridge TOKEN | --check | --tune | --links | --list | --add NAME | --del NAME | --exit-cmd NAME | --link NAME | --migrate | --enable-stats | --web | --web-off | --web-info）" ;;
esac
