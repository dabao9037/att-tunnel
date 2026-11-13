"""Web 面板升级入口的静态顺序与本地 HTTP 行为验证（不触碰线上配置/服务）。

从 install.sh 里抽出内嵌的 web.py，用临时 env/state 启动一个本地实例；
do_upgrade 被替换成只回固定字符串，绝不会真的下载或执行升级脚本。
"""
import importlib.util
import http.cookiejar
import os
import pathlib
import re
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
src = (ROOT / 'install.sh').read_text()
m = re.search(r"cat > \"\$WEB_PY\.tmp\" <<'ATT_WEB_PY'\n([\s\S]*?)\nATT_WEB_PY\n", src)
assert m, '找不到内嵌 web.py'
web_src = m.group(1).replace('ATT_VERSION', 'test')


def section(name, nxt):
    return web_src[web_src.index('    def %s(' % name):web_src.index('    def %s(' % nxt)]


post = section('do_POST', 'do_add')
order = [post.index('self.session()'), post.index('self.same_origin()'),
         post.index("X-CSRF-Token"), post.index("'/__upgrade__'")]
assert order == sorted(order), '升级入口必须在会话、同源、CSRF 校验之后: %r' % order
assert 'def same_origin' in web_src
assert 'raw = RAW_URL or aenv.get' in web_src, '面板升级必须能回退到 WEB_RAW_URL'
assert 'ATT_RAW_URL=%s bash -s -- --upgrade' in web_src and '?ts=%d' in web_src, '升级子进程必须继承当前来源 URL'
print('PASS: static order session -> same-origin -> CSRF -> /__upgrade__')

# --upgrade 只能刷新程序，不能重写节点配置（防止再次出现 11-13 的节点绑定被抹）
assert re.search(r'^\s*--upgrade\)\s+upgrade_program', src, re.M), '缺少 --upgrade 分发'
up = src[src.index('upgrade_program(){'):src.index('web_disable(){')]
for forbidden in ('apply_cfg', 'deploy_a', 'deploy_b', '--server-a', '--migrate'):
    assert forbidden not in up, '--upgrade 不应调用 %s' % forbidden
for needed in ('write_web_py', 'install_script_copy', 'systemctl restart',
               'RAW_EXPLICIT', 'ATT_RAW_URL'):
    assert needed in up or needed in src, '--upgrade 缺少 %s' % needed
assert '[ "$RAW_EXPLICIT" = 1 ] && save_web_raw_url' not in src, '来源覆盖必须用 if，避免 set -e 陷阱'
assert 'att-hub-agent/agent.py' in src and 'raw.githubusercontent.com/dabao9037/att-tunnel-hub/main/agent.py' in src, '缺少 hub agent 引导更新'
print('PASS: --upgrade refreshes program/panel only, never rewrites node config')

with tempfile.TemporaryDirectory() as tmp:
    p = pathlib.Path(tmp)
    (p / 'web.py').write_text(web_src)
    (p / 'web.env').write_text('WEB_PORT=1\nWEB_PATH=test\nWEB_PASS=testpass123\n')
    (p / 'config.json').write_text('{"inbounds":[],"outbounds":[]}')
    os.environ['ATT_WEB_ENV'] = str(p / 'web.env')
    os.environ['ATT_CFG'] = str(p / 'config.json')
    os.environ['ATT_WEB_STATE'] = str(p / 'web-state.json')
    os.environ['ATT_SCRIPT'] = str(p / 'no-such-install.sh')
    spec = importlib.util.spec_from_file_location('att_web_test', p / 'web.py')
    web = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(web)
    web.H.do_upgrade = lambda self: self.send(200, 'UPGRADE_REACHED', 'text/plain; charset=utf-8')
    server = web.Srv(('127.0.0.1', 0), web.H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = '127.0.0.1:%d' % server.server_port
    base = 'http://' + host + '/test'
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def post(path, data, headers=None):
        req = urllib.request.Request(base + path, urllib.parse.urlencode(data).encode(), method='POST')
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            r = opener.open(req, timeout=5)
            return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    try:
        st, _ = post('/__upgrade__', {})
        assert st == 401, '未登录升级未被拒绝: %s' % st
        opener.open(urllib.request.Request(base + '/login',
                    urllib.parse.urlencode({'password': 'testpass123'}).encode(), method='POST'), timeout=5).read()
        st, _ = post('/__upgrade__', {})
        assert st == 403, '缺 CSRF 的升级未被拒绝: %s' % st
        # 登录后取 CSRF（页面里的 const C="..."）
        page = opener.open(base + '/', timeout=5).read().decode()
        csrf = re.search(r'const P="[^"]+",C="([^"]+)"', page).group(1)
        st, _ = post('/__upgrade__', {'csrf': csrf}, {'Origin': 'https://evil.example'})
        assert st == 403, '跨站 Origin 未被拒绝: %s' % st
        st, _ = post('/__upgrade__', {'csrf': csrf}, {'Sec-Fetch-Site': 'cross-site'})
        assert st == 403, '跨站 Sec-Fetch-Site 未被拒绝: %s' % st
        st, body = post('/__upgrade__', {'csrf': csrf}, {'Origin': base.rsplit('/test', 1)[0], 'Host': host})
        assert st == 200 and body == 'UPGRADE_REACHED', '同源升级未放行: %s %r' % (st, body)
        st, body = post('/__upgrade__', {'csrf': csrf})
        assert st == 200 and body == 'UPGRADE_REACHED', '非浏览器 agent 升级未放行: %s %r' % (st, body)
        try:
            opener.open(base + '/__upgrade__', timeout=5)
            raise AssertionError('GET 不应触发升级')
        except urllib.error.HTTPError as e:
            assert e.code == 404
        print('PASS: local HTTP rejects unauthenticated/missing-CSRF/cross-site upgrades; '
              'allows same-origin and agent (session+CSRF) upgrade')
    finally:
        server.shutdown()
        server.server_close()
