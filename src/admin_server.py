#!/usr/bin/env python3
import os
import re
import json
import signal
import socket
import struct
import subprocess
import glob
import threading
import time
from datetime import datetime
from flask import Flask, jsonify, request, send_file, make_response

app = Flask(__name__)

DATA_DIR = '/data'
TMP_DIR = '/tmp'
REDIS_SOCK = '/tmp/redis.sock'
CUSTOM_ENV_FILE = os.path.join(DATA_DIR, 'custom_env.ini')
ENV_CONF_FILE = os.path.join(TMP_DIR, 'env.conf')
MOSDNS_LOG = os.path.join(TMP_DIR, 'mosdns.log')
ANSWER_LOG = os.path.join(DATA_DIR, 'query_answer_log.jsonl')
PERIODIC_ROOT = '/etc/periodic'
RELOAD_TIMEOUT = 180
DNS_PROXY_LISTEN_PORT = int(os.environ.get('DNS_PROXY_LISTEN_PORT', '53'))
DNS_PROXY_UPSTREAM_PORT = int(os.environ.get('DNS_PROXY_UPSTREAM_PORT', '5353'))
ANSWER_MATCH_WINDOW = 10
DEFAULT_QUERY_LOG_MAX_MB = 10
DEFAULT_QUERY_LOG_CLEAN_INTERVAL = 600
DEFAULT_QUERY_ANSWER_LOG_MAX_LINES = 5000
CACHE_DBS = [
    {'db': 0, 'source': '本地递归', 'desc': 'unbound raw cachedb'},
    {'db': 1, 'source': '转发递归', 'desc': 'unbound forward cachedb'},
]

QTYPE_NAMES = {
    1: 'A',
    2: 'NS',
    5: 'CNAME',
    12: 'PTR',
    15: 'MX',
    16: 'TXT',
    28: 'AAAA',
    33: 'SRV',
    64: 'SVCB',
    65: 'HTTPS',
}

RCODE_NAMES = {
    0: 'NOERROR',
    1: 'FORMERR',
    2: 'SERVFAIL',
    3: 'NXDOMAIN',
    4: 'NOTIMP',
    5: 'REFUSED',
}

ROUTE_LABELS = {
    'route_mosdns_cache': 'mosdns 缓存',
    'route_cn_local_unbound': 'CN 本地递归 5301',
    'route_cn_local_unbound_fall': 'CN 本地递归 5301',
    'route_cn_fall_public': 'CN 回退公共 DNS',
    'route_force_recurse_local_unbound': '强制本地递归 5301',
    'route_force_dnscrypt_forward_unbound': '强制加密DNS: 转发递归 5304',
    'route_force_dnscrypt_dnscrypt': '强制加密DNS: dnscrypt 5302',
    'route_custom_forward': 'CUSTOM_FORWARD',
    'route_auto_check_private': 'AUTO_FORWARD 检查: 内网地址',
    'route_foreign_first_cn_local_unbound': '国外优先 -> 国内本地递归 5301',
    'route_foreign_first_cn_local_unbound_fall': '国外优先 -> 国内本地递归 5301',
    'route_foreign_first_custom_forward': '国外优先 -> CUSTOM_FORWARD',
    'route_gfwlist_cn_local_unbound': 'gfwlist -> 国内本地递归 5301',
    'route_gfwlist_cn_local_unbound_fall': 'gfwlist -> 国内本地递归 5301',
    'route_not_a_aaaa_local_unbound': '非 A/AAAA: 本地递归 5301',
    'route_not_a_aaaa_forward_unbound': '非 A/AAAA: 转发递归 5304',
}

DOMAIN_LISTS = {
    'force_dnscrypt': 'force_dnscrypt_list.txt',
    'force_recurse': 'force_recurse_list.txt',
    'force_forward': 'force_forward_list.txt',
    'force_nocn': 'force_nocn_list.txt',
    'force_cn': 'force_cn_list.txt',
}

DOMAIN_LIST_LABELS = {
    'force_dnscrypt': '强制加密DNS (非CN)',
    'force_recurse': '强制本地递归 (CN)',
    'force_forward': '强制转发',
    'force_nocn': '强制非CN',
    'force_cn': '强制CN',
}

DOMAIN_LIST_DESCS = {
    'force_cn': '把域名标记为 CN，让后续自动分流按国内域名处理；适合自动误判为非 CN、但你确认应走国内链路的域名。',
    'force_dnscrypt': '强制走非 CN 加密 DNS 链路，绕过 AUTO_FORWARD/CUSTOM_FORWARD；适合境外域名需要真实解析、不想拿 fake-ip 的场景。',
    'force_forward': '强制转发到 CUSTOM_FORWARD；如果 CUSTOM_FORWARD 是旁路网关或代理 DNS，通常会返回 fake-ip。',
    'force_nocn': '把域名标记为非 CN，再交给非 CN 自动流程；如果 AUTO_FORWARD=yes，后续仍可能转到 CUSTOM_FORWARD。',
    'force_recurse': '强制走本地递归 CN 链路；适合国内域名或本地递归调试，不建议用于大多数境外域名。',
}

TOGGLE_SETTINGS = [
    {'key': 'UPDATE', 'label': '规则更新周期', 'desc': 'no=关闭；daily=每天约 02:00；weekly=每周六约 03:00；monthly=每月 1 日约 05:00', 'values': ['no', 'daily', 'weekly', 'monthly']},
    {'key': 'CNFALL', 'label': 'CN回退', 'desc': 'CN解析失败时回退到加密DNS', 'values': ['yes', 'no']},
    {'key': 'CN_RECURSE', 'label': 'CN本地递归', 'desc': 'CNFALL=yes 时先尝试本地递归 5301；根递归不通时建议关闭，直接走公共 DNS 回退', 'values': ['yes', 'no']},
    {'key': 'AUTO_FORWARD', 'label': '自动转发', 'desc': '自动转发非CN域名到CUSTOM_FORWARD', 'values': ['yes', 'no']},
    {'key': 'AUTO_FORWARD_CHECK', 'label': '转发检查', 'desc': '自动转发前检查域名是否为CN', 'values': ['yes', 'no']},
    {'key': 'ROUTE_MODE', 'label': '分流模式', 'desc': 'cn_first=先按国内解析判断；foreign_first=先匹配国外域名规则，未命中一律走国内；gfwlist=先匹配 gfwlist，未命中一律走国内', 'values': ['cn_first', 'foreign_first', 'gfwlist']},
    {'key': 'USE_MARK_DATA', 'label': '预分类数据', 'desc': '使用预分类域名数据库加速分流', 'values': ['yes', 'no']},
    {'key': 'CN_TRACKER', 'label': 'Tracker分流', 'desc': 'BT Tracker域名走非CN解析', 'values': ['yes', 'no']},
    {'key': 'IPV6', 'label': 'IPv6模式', 'desc': 'no=禁用；yes=仅国内双栈；only6=仅 IPv6-only；yes_only6=国内双栈+国外 IPv6-only；raw=原样返回全部 AAAA', 'values': ['no', 'yes', 'only6', 'yes_only6', 'raw']},
    {'key': 'ADDINFO', 'label': '附加信息', 'desc': 'DNS响应中附加解析路径信息', 'values': ['yes', 'no']},
    {'key': 'SHUFFLE', 'label': 'IP随机排序', 'desc': '响应中的IP地址随机排序', 'values': ['no', 'yes', 'lite', 'trnc']},
    {'key': 'EXPIRED_FLUSH', 'label': '过期刷新', 'desc': '过期缓存主动刷新', 'values': ['yes', 'no']},
    {'key': 'HTTP_FILE', 'label': 'HTTP文件服务', 'desc': '7889端口提供/data目录文件服务', 'values': ['yes', 'no']},
]

TEXT_SETTINGS = [
    {'key': 'CUSTOM_FORWARD', 'label': '自定义转发', 'desc': 'AUTO_FORWARD 和强制转发列表使用的上游 DNS，格式 IP:PORT 或 [IPv6]:PORT', 'placeholder': '8.8.8.8:53'},
    {'key': 'CUSTOM_FORWARD_TTL', 'label': '转发 TTL', 'desc': 'CUSTOM_FORWARD 响应 TTL 下限，0 表示不修改', 'placeholder': '0'},
    {'key': 'CNFALL_QTIME', 'label': 'CN回退等待', 'desc': 'CNFALL=yes 时等待本地递归 5301 的时间，单位毫秒；调大可减少新域名首查超时报错', 'placeholder': '3', 'default': '3'},
    {'key': 'QUERY_LOG_MAX_MB', 'label': '查询日志上限', 'desc': 'mosdns 查询日志最大容量，单位 MB；超限后保留最新内容', 'placeholder': '10', 'default': '10'},
    {'key': 'QUERY_LOG_CLEAN_INTERVAL', 'label': '日志检查间隔', 'desc': '定时检查查询日志的间隔，单位秒', 'placeholder': '600', 'default': '600'},
    {'key': 'QUERY_ANSWER_LOG_MAX_LINES', 'label': '响应日志行数', 'desc': '查询响应摘要最多保留的行数', 'placeholder': '5000', 'default': '5000'},
]

READONLY_SETTINGS = [
    {'key': 'CNAUTO', 'label': 'CN 自动分流', 'desc': '启用 mosdns/unbound/dnscrypt 组合分流架构，关闭后使用基础递归模式'},
    {'key': 'SOCKS5', 'label': 'Socks5 代理', 'desc': 'dnscrypt 上游代理地址，影响启动时生成的 dnscrypt 和 unbound 转发配置'},
    {'key': 'DNSPORT', 'label': 'DNS 监听端口', 'desc': '容器内 DNS 服务监听端口，通常通过容器端口映射暴露到宿主机'},
    {'key': 'DNS_SERVERNAME', 'label': 'DNS 服务名', 'desc': 'Unbound 使用的服务器身份名称，用于响应和服务标识'},
    {'key': 'SERVER_IP', 'label': '服务域名 IP', 'desc': 'paopao.dns 的实际解析 IP；默认 auto 在启动时自动探测当前出站 IPv4'},
]


def get_redis(db=1):
    import redis
    return redis.Redis(unix_socket_path=REDIS_SOCK, db=db, decode_responses=False)


def read_env_conf():
    result = {}
    if not os.path.exists(ENV_CONF_FILE):
        return result
    with open(ENV_CONF_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('====') or not line:
                continue
            m = re.match(r'^(\w+):-(.+)-$', line)
            if m:
                result[m.group(1)] = m.group(2)
    return result


def read_custom_env():
    result = {}
    if not os.path.exists(CUSTOM_ENV_FILE):
        return result
    with open(CUSTOM_ENV_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^([_a-zA-Z0-9]+)="(.*)"', line)
            if m:
                result[m.group(1)] = m.group(2)
    return result


def write_custom_env(settings):
    lines = []
    if os.path.exists(CUSTOM_ENV_FILE):
        with open(CUSTOM_ENV_FILE, 'r') as f:
            lines = f.readlines()
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'

    existing_keys = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        m = re.match(r'^#?([_a-zA-Z0-9]+)="', stripped)
        if m and m.group(1) in settings:
            key = m.group(1)
            existing_keys.add(key)
            new_lines.append(f'{key}="{settings[key]}"\n')
        else:
            new_lines.append(line)

    for key, val in settings.items():
        if key not in existing_keys:
            new_lines.append(f'{key}="{val}"\n')

    with open(CUSTOM_ENV_FILE, 'w') as f:
        f.writelines(new_lines)


def configure_update_schedule(period):
    task_name = 'paopaodns-update'
    periods = ('daily', 'weekly', 'monthly')
    for item in periods:
        directory = os.path.join(PERIODIC_ROOT, item)
        os.makedirs(directory, exist_ok=True)
        for filename in (task_name, 'data_update.sh'):
            filepath = os.path.join(directory, filename)
            if os.path.lexists(filepath):
                os.remove(filepath)
    if period in periods:
        os.symlink('/usr/sbin/data_update.sh', os.path.join(PERIODIC_ROOT, period, task_name))
        crond_running = subprocess.run(
            ['pgrep', '-x', 'crond'], capture_output=True, timeout=5
        ).returncode == 0
        if not crond_running:
            subprocess.run(['crond'], check=True, timeout=5)


def validate_setting(key, val):
    val = str(val).strip()
    toggle = next((s for s in TOGGLE_SETTINGS if s['key'] == key), None)
    if toggle:
        if val not in toggle['values']:
            return None, f'{key} invalid value'
        return val, None

    if key == 'CUSTOM_FORWARD':
        if not re.match(r'^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9_.-]+):[0-9]{1,5}$', val):
            return None, 'CUSTOM_FORWARD must be IP:PORT or [IPv6]:PORT'
        port = int(val.rsplit(':', 1)[1])
        if port < 1 or port > 65535:
            return None, 'CUSTOM_FORWARD port out of range'
        return val, None

    if key == 'CUSTOM_FORWARD_TTL':
        if not re.match(r'^[0-9]+$', val):
            return None, 'CUSTOM_FORWARD_TTL must be a number'
        ttl = int(val)
        if ttl < 0 or ttl > 604800:
            return None, 'CUSTOM_FORWARD_TTL out of range'
        return str(ttl), None

    if key == 'CNFALL_QTIME':
        if not re.match(r'^[0-9]+$', val):
            return None, 'CNFALL_QTIME must be a number'
        qtime = int(val)
        if qtime < 1 or qtime > 5000:
            return None, 'CNFALL_QTIME out of range'
        return str(qtime), None

    numeric_settings = {
        'QUERY_LOG_MAX_MB': (1, 1024),
        'QUERY_LOG_CLEAN_INTERVAL': (60, 86400),
        'QUERY_ANSWER_LOG_MAX_LINES': (100, 100000),
    }
    if key in numeric_settings:
        if not re.match(r'^[0-9]+$', val):
            return None, f'{key} must be a number'
        number = int(val)
        minimum, maximum = numeric_settings[key]
        if number < minimum or number > maximum:
            return None, f'{key} must be between {minimum} and {maximum}'
        return str(number), None

    return None, f'{key} is not editable'


def read_domain_list(list_type):
    filename = DOMAIN_LISTS.get(list_type)
    if not filename:
        return None
    filepath = os.path.join(DATA_DIR, filename)
    if not os.path.exists(filepath):
        return []
    domains = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                domains.append(line)
    return domains


def write_domain_list(list_type, domains):
    filename = DOMAIN_LISTS.get(list_type)
    if not filename:
        return False
    filepath = os.path.join(DATA_DIR, filename)
    with open(filepath, 'w') as f:
        for d in domains:
            f.write(d + '\n')
    return True


@app.route('/')
def index():
    resp = make_response(send_file('/usr/sbin/admin.html'))
    resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    resp.headers['Pragma'] = 'no-cache'
    return resp


@app.route('/api/status')
def status():
    try:
        ps = subprocess.run(['ps', '-ef'], capture_output=True, text=True, timeout=5)
        lines = ps.stdout.strip().split('\n')
    except Exception:
        lines = []
    services = {
        'mosdns': False,
        'unbound': False,
        'redis': False,
        'dnscrypt': False,
    }
    for line in lines:
        if 'mosdns.yaml' in line and 'grep' not in line:
            services['mosdns'] = True
        if 'unbound' in line and 'grep' not in line:
            services['unbound'] = True
        if 'redis-server' in line and 'grep' not in line:
            services['redis'] = True
        if 'dnscrypt-proxy' in line and 'grep' not in line:
            services['dnscrypt'] = True
    return jsonify(services)


@app.route('/api/update-schedule')
def update_schedule():
    settings = read_env_conf()
    settings.update(read_custom_env())
    period = settings.get('UPDATE', 'weekly')
    schedule_labels = {
        'no': '已关闭',
        'daily': '每天约 02:00',
        'weekly': '每周六约 03:00',
        'monthly': '每月 1 日约 05:00',
    }
    task_path = os.path.join(PERIODIC_ROOT, period, 'paopaodns-update') if period != 'no' else ''
    return jsonify({
        'period': period,
        'label': schedule_labels.get(period, period),
        'enabled': period != 'no' and os.path.exists(task_path),
        'task_path': task_path,
    })


@app.route('/api/config', methods=['GET'])
def get_config():
    env_conf = read_env_conf()
    custom_env = read_custom_env()

    merged = {}
    for key in set(list(env_conf.keys()) + list(custom_env.keys())):
        merged[key] = custom_env.get(key, env_conf.get(key, ''))

    settings = []
    for s in TOGGLE_SETTINGS:
        settings.append({
            'key': s['key'],
            'label': s['label'],
            'desc': s['desc'],
            'values': s['values'],
            'current': merged.get(s['key'], s['values'][0]),
            'readonly': False,
            'type': 'select',
        })

    text_settings = []
    for s in TEXT_SETTINGS:
        text_settings.append({
            'key': s['key'],
            'label': s['label'],
            'desc': s['desc'],
            'placeholder': s['placeholder'],
            'current': merged.get(s['key'], s.get('default', '')),
            'readonly': False,
            'type': 'text',
        })

    readonly = []
    for s in READONLY_SETTINGS:
        current = merged.get(s['key'], '')
        display = current
        if s['key'] == 'SERVER_IP':
            current = env_conf.get('SERVER_IP', current)
            configured = custom_env.get('SERVER_IP', env_conf.get('SERVER_IP_CONFIG', ''))
            if configured == 'auto':
                display = f'{current}（自动探测）'
            elif configured == 'none':
                display = '未启用'
        readonly.append({
            'key': s['key'],
            'label': s['label'],
            'desc': s['desc'],
            'current': current,
            'display': display,
            'readonly': True,
        })

    return jsonify({'settings': settings, 'text_settings': text_settings, 'readonly': readonly})


@app.route('/api/config', methods=['POST'])
def update_config():
    data = request.get_json()
    if not data or 'settings' not in data:
        return jsonify({'error': 'missing settings'}), 400

    allowed_keys = {s['key'] for s in TOGGLE_SETTINGS + TEXT_SETTINGS}
    to_update = {}
    for key, val in data['settings'].items():
        if key in allowed_keys:
            cleaned, error = validate_setting(key, val)
            if error:
                return jsonify({'error': error}), 400
            to_update[key] = cleaned

    if not to_update:
        return jsonify({'error': 'no valid settings'}), 400

    if 'UPDATE' in to_update:
        try:
            configure_update_schedule(to_update['UPDATE'])
        except OSError as e:
            return jsonify({'error': f'failed to update schedule: {e}'}), 500
    write_custom_env(to_update)
    return jsonify({'ok': True, 'updated': to_update})


@app.route('/api/reload', methods=['POST'])
def reload_mosdns():
    try:
        proc = subprocess.Popen(
            ['/usr/sbin/regen_mosdns.sh'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=RELOAD_TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                stdout, stderr = proc.communicate()
            return jsonify({
                'ok': False,
                'error': f'timeout after {RELOAD_TIMEOUT}s',
                'stdout': stdout[-2000:] if stdout else '',
                'stderr': stderr[-2000:] if stderr else '',
            }), 500

        return jsonify({
            'ok': proc.returncode == 0,
            'stdout': stdout[-2000:] if stdout else '',
            'stderr': stderr[-2000:] if stderr else '',
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/domains/<list_type>', methods=['GET'])
def get_domains(list_type):
    if list_type not in DOMAIN_LISTS:
        return jsonify({'error': 'invalid list type'}), 400
    domains = read_domain_list(list_type)
    return jsonify({
        'list_type': list_type,
        'label': DOMAIN_LIST_LABELS.get(list_type, list_type),
        'desc': DOMAIN_LIST_DESCS.get(list_type, ''),
        'domains': domains,
        'count': len(domains),
    })


@app.route('/api/domains/<list_type>', methods=['POST'])
def add_domain(list_type):
    if list_type not in DOMAIN_LISTS:
        return jsonify({'error': 'invalid list type'}), 400
    data = request.get_json()
    domain = data.get('domain', '').strip() if data else ''
    if not domain:
        return jsonify({'error': 'empty domain'}), 400

    if not re.match(r'^(domain:|full:|keyword:|regexp:)', domain):
        domain = 'domain:' + domain

    domains = read_domain_list(list_type)
    if domain in domains:
        return jsonify({'error': 'domain already exists'}), 409
    domains.append(domain)
    write_domain_list(list_type, domains)
    return jsonify({'ok': True, 'domain': domain})


@app.route('/api/domains/<list_type>', methods=['DELETE'])
def delete_domain(list_type):
    if list_type not in DOMAIN_LISTS:
        return jsonify({'error': 'invalid list type'}), 400
    data = request.get_json()
    domain = data.get('domain', '').strip() if data else ''
    if not domain:
        return jsonify({'error': 'empty domain'}), 400

    domains = read_domain_list(list_type)
    if domain not in domains:
        return jsonify({'error': 'domain not found'}), 404
    domains.remove(domain)
    write_domain_list(list_type, domains)
    return jsonify({'ok': True})


@app.route('/api/domains/all', methods=['GET'])
def get_all_domains():
    result = {}
    for lt in DOMAIN_LISTS:
        result[lt] = {
            'label': DOMAIN_LIST_LABELS.get(lt, lt),
            'desc': DOMAIN_LIST_DESCS.get(lt, ''),
            'domains': read_domain_list(lt),
        }
    return jsonify(result)


@app.route('/api/cache/stats', methods=['GET'])
def cache_stats():
    try:
        r = get_redis(CACHE_DBS[0]['db'])
        info = r.info('memory')
        stats_info = r.info('stats')
        dbs = []
        db_size = 0
        for cfg in CACHE_DBS:
            db_client = get_redis(cfg['db'])
            size = db_client.dbsize()
            db_size += size
            dbs.append({
                'db': cfg['db'],
                'source': cfg['source'],
                'desc': cfg['desc'],
                'size': size,
            })
        return jsonify({
            'used_memory_human': info.get('used_memory_human', 'N/A'),
            'used_memory': info.get('used_memory', 0),
            'maxmemory_human': info.get('maxmemory_human', 'N/A'),
            'maxmemory': info.get('maxmemory', 0),
            'db_size': db_size,
            'dbs': dbs,
            'keyspace_hits': stats_info.get('keyspace_hits', 0),
            'keyspace_misses': stats_info.get('keyspace_misses', 0),
            'evicted_keys': stats_info.get('evicted_keys', 0),
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def parse_cache_cursor(cursor):
    text = str(cursor or '0')
    try:
        if ':' in text:
            db_index, scan_cursor = text.split(':', 1)
            return max(0, int(db_index)), max(0, int(scan_cursor))
        return 0, max(0, int(text))
    except ValueError:
        return 0, 0


@app.route('/api/cache/keys', methods=['GET'])
def cache_keys():
    pattern = request.args.get('pattern', '*')
    cursor = request.args.get('cursor', '0')
    count = min(int(request.args.get('count', 50)), 200)

    try:
        search = '' if pattern == '*' else pattern.lower()
        decoded = []
        db_index, scan_cursor = parse_cache_cursor(cursor)
        db_index = min(db_index, len(CACHE_DBS))
        next_cursor = '0:0'
        has_more = False

        while len(decoded) < count and db_index < len(CACHE_DBS):
            cfg = CACHE_DBS[db_index]
            r = get_redis(cfg['db'])
            loops = 0

            while len(decoded) < count:
                scan_cursor, keys = r.scan(cursor=scan_cursor, match='*', count=count)
                for k in keys:
                    detail = build_cache_entry(r, k, cfg)
                    if search and search not in cache_entry_search_text(detail):
                        continue
                    decoded.append(detail)
                    if len(decoded) >= count:
                        break
                loops += 1
                if scan_cursor == 0 or loops >= 50:
                    break

            if scan_cursor != 0:
                next_cursor = f'{db_index}:{scan_cursor}'
                has_more = True
                break

            db_index += 1
            scan_cursor = 0
            if db_index < len(CACHE_DBS):
                next_cursor = f'{db_index}:0'
                has_more = True

        if db_index >= len(CACHE_DBS):
            next_cursor = '0:0'
            has_more = False

        return jsonify({
            'cursor': next_cursor,
            'keys': decoded,
            'has_more': has_more,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def build_cache_entry(redis_client, key, db_info=None):
    key_text = key.decode('utf-8', errors='replace') if isinstance(key, bytes) else str(key)
    db_info = db_info or {}
    entry = {
        'key': key_text,
        'db': db_info.get('db'),
        'source': db_info.get('source', ''),
        'source_desc': db_info.get('desc', ''),
        'type': '',
        'redis_ttl': -2,
        'size': 0,
        'domain': '',
        'qtype': '',
        'rcode': '',
        'answer_count': 0,
        'ttl_min': None,
        'answers': [],
    }

    try:
        key_type = redis_client.type(key)
        entry['type'] = key_type.decode('utf-8', errors='replace') if isinstance(key_type, bytes) else str(key_type)
        entry['redis_ttl'] = redis_client.ttl(key)
        value = redis_client.get(key) if entry['type'] == 'string' else None
        if value:
            entry['size'] = len(value)
            parsed = parse_dns_cache_value(value)
            if parsed:
                entry.update(parsed)
    except Exception as e:
        entry['error'] = str(e)

    return entry


def cache_entry_search_text(entry):
    parts = [
        entry.get('key', ''),
        entry.get('source', ''),
        entry.get('source_desc', ''),
        entry.get('domain', ''),
        entry.get('qtype', ''),
        entry.get('rcode', ''),
    ]
    for answer in entry.get('answers', []):
        parts.extend([answer.get('name', ''), answer.get('type', ''), answer.get('data', '')])
    return ' '.join(str(p) for p in parts).lower()


def parse_dns_cache_value(data):
    if len(data) < 12:
        return None

    try:
        _, flags, qd_count, an_count, ns_count, ar_count = struct.unpack('!HHHHHH', data[:12])
        offset = 12
        questions = []

        for _ in range(qd_count):
            name, offset = read_dns_name(data, offset)
            qtype, qclass = struct.unpack('!HH', data[offset:offset + 4])
            offset += 4
            questions.append({'name': name, 'qtype': qtype, 'qclass': qclass})

        answers = []
        ttl_values = []
        sections = [('answer', an_count), ('authority', ns_count), ('additional', ar_count)]
        for section, section_count in sections:
            for _ in range(section_count):
                if offset + 10 > len(data):
                    raise ValueError('truncated record')
                name, offset = read_dns_name(data, offset)
                rr_type, rr_class, ttl, rdlength = struct.unpack('!HHIH', data[offset:offset + 10])
                offset += 10
                rdata_offset = offset
                offset += rdlength
                if offset > len(data):
                    raise ValueError('truncated rdata')

                if section == 'answer':
                    answer = {
                        'name': name,
                        'type': QTYPE_NAMES.get(rr_type, str(rr_type)),
                        'ttl': ttl,
                        'data': format_dns_rdata(data, rdata_offset, rdlength, rr_type),
                    }
                    answers.append(answer)
                    ttl_values.append(ttl)

        question = questions[0] if questions else {}
        rcode = flags & 0x000f
        return {
            'domain': question.get('name', ''),
            'qtype': QTYPE_NAMES.get(question.get('qtype'), str(question.get('qtype', ''))),
            'rcode': RCODE_NAMES.get(rcode, str(rcode)),
            'answer_count': an_count,
            'ttl_min': min(ttl_values) if ttl_values else None,
            'answers': answers,
        }
    except Exception:
        return None


def read_dns_name(packet, offset, depth=0):
    if depth > 20:
        raise ValueError('dns pointer loop')

    labels = []
    jumped = False
    next_offset = offset

    while True:
        if offset >= len(packet):
            raise ValueError('name out of range')
        length = packet[offset]

        if length & 0xc0 == 0xc0:
            if offset + 1 >= len(packet):
                raise ValueError('bad pointer')
            pointer = ((length & 0x3f) << 8) | packet[offset + 1]
            if not jumped:
                next_offset = offset + 2
            offset = pointer
            jumped = True
            depth += 1
            if depth > 20:
                raise ValueError('dns pointer loop')
            continue

        if length == 0:
            offset += 1
            if not jumped:
                next_offset = offset
            break

        offset += 1
        label = packet[offset:offset + length].decode('utf-8', errors='replace')
        labels.append(label)
        offset += length
        if not jumped:
            next_offset = offset

    return '.'.join(labels), next_offset


def format_dns_rdata(packet, offset, length, rr_type):
    rdata = packet[offset:offset + length]
    try:
        if rr_type == 1 and length == 4:
            return socket.inet_ntoa(rdata)
        if rr_type == 28 and length == 16:
            return socket.inet_ntop(socket.AF_INET6, rdata)
        if rr_type in (2, 5, 12):
            name, _ = read_dns_name(packet, offset)
            return name
        if rr_type == 15 and length >= 3:
            preference = struct.unpack('!H', packet[offset:offset + 2])[0]
            exchange, _ = read_dns_name(packet, offset + 2)
            return f'{preference} {exchange}'
        if rr_type == 16:
            chunks = []
            pos = 0
            while pos < len(rdata):
                chunk_len = rdata[pos]
                pos += 1
                chunks.append(rdata[pos:pos + chunk_len].decode('utf-8', errors='replace'))
                pos += chunk_len
            return ' '.join(chunks)
    except Exception:
        pass
    return rdata.hex()


ANSWER_LOG_LOCK = threading.Lock()
MOSDNS_LOG_LOCK = threading.Lock()


def get_log_cleanup_settings():
    settings = read_env_conf()
    settings.update(read_custom_env())

    def get_number(key, default, minimum, maximum):
        try:
            value = int(settings.get(key, default))
        except (TypeError, ValueError):
            value = default
        return max(minimum, min(value, maximum))

    return {
        'max_bytes': get_number('QUERY_LOG_MAX_MB', DEFAULT_QUERY_LOG_MAX_MB, 1, 1024) * 1024 * 1024,
        'interval': get_number('QUERY_LOG_CLEAN_INTERVAL', DEFAULT_QUERY_LOG_CLEAN_INTERVAL, 60, 86400),
        'answer_lines': get_number('QUERY_ANSWER_LOG_MAX_LINES', DEFAULT_QUERY_ANSWER_LOG_MAX_LINES, 100, 100000),
    }


def trim_mosdns_log(max_bytes):
    try:
        if os.path.getsize(MOSDNS_LOG) <= max_bytes:
            return False
        keep_bytes = max(1, max_bytes * 3 // 4)
        with MOSDNS_LOG_LOCK:
            with open(MOSDNS_LOG, 'r+b') as log_file:
                log_file.seek(0, os.SEEK_END)
                size = log_file.tell()
                log_file.seek(max(0, size - keep_bytes))
                content = log_file.read()
                if size > keep_bytes:
                    newline = content.find(b'\n')
                    if newline >= 0:
                        content = content[newline + 1:]
                log_file.seek(0)
                log_file.write(content)
                log_file.truncate()
        return True
    except (FileNotFoundError, OSError):
        return False


def run_log_cleanup():
    last_cleanup = 0
    while True:
        settings = get_log_cleanup_settings()
        now = time.monotonic()
        if now - last_cleanup >= settings['interval']:
            trim_mosdns_log(settings['max_bytes'])
            with ANSWER_LOG_LOCK:
                trim_answer_log(settings['answer_lines'])
            last_cleanup = now
        time.sleep(min(60, settings['interval']))


def start_log_cleanup():
    threading.Thread(target=run_log_cleanup, daemon=True).start()


def start_dns_answer_proxy():
    threading.Thread(target=run_udp_dns_proxy, daemon=True).start()
    threading.Thread(target=run_tcp_dns_proxy, daemon=True).start()


def run_udp_dns_proxy():
    try:
        sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(('::', DNS_PROXY_LISTEN_PORT))
    except Exception as e:
        print(f'DNS UDP proxy disabled: {e}', flush=True)
        return

    while True:
        try:
            data, client_addr = sock.recvfrom(4096)
            threading.Thread(
                target=handle_udp_dns_query,
                args=(sock, data, client_addr),
                daemon=True,
            ).start()
        except Exception:
            continue


def handle_udp_dns_query(server_sock, data, client_addr):
    try:
        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        upstream.settimeout(10)
        upstream.sendto(data, ('127.0.0.1', DNS_PROXY_UPSTREAM_PORT))
        response, _ = upstream.recvfrom(65535)
        upstream.close()
        record_dns_answer_snapshot(data, response, client_addr[0], 'udp')
        server_sock.sendto(response, client_addr)
    except Exception:
        try:
            upstream.close()
        except Exception:
            pass


def run_tcp_dns_proxy():
    try:
        server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        server.bind(('::', DNS_PROXY_LISTEN_PORT))
        server.listen(128)
    except Exception as e:
        print(f'DNS TCP proxy disabled: {e}', flush=True)
        return

    while True:
        try:
            conn, client_addr = server.accept()
            threading.Thread(
                target=handle_tcp_dns_client,
                args=(conn, client_addr),
                daemon=True,
            ).start()
        except Exception:
            continue


def handle_tcp_dns_client(conn, client_addr):
    with conn:
        conn.settimeout(10)
        while True:
            try:
                length_data = recv_exact(conn, 2)
                if not length_data:
                    return
                query_len = struct.unpack('!H', length_data)[0]
                query = recv_exact(conn, query_len)
                if not query:
                    return

                upstream = socket.create_connection(('127.0.0.1', DNS_PROXY_UPSTREAM_PORT), timeout=10)
                with upstream:
                    upstream.sendall(length_data + query)
                    resp_len_data = recv_exact(upstream, 2)
                    if not resp_len_data:
                        return
                    resp_len = struct.unpack('!H', resp_len_data)[0]
                    response = recv_exact(upstream, resp_len)
                    if not response:
                        return
                record_dns_answer_snapshot(query, response, client_addr[0], 'tcp')
                conn.sendall(resp_len_data + response)
            except Exception:
                return


def recv_exact(conn, length):
    chunks = []
    remaining = length
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            return b''
        chunks.append(chunk)
        remaining -= len(chunk)
    return b''.join(chunks)


def record_dns_answer_snapshot(query_packet, response_packet, client, protocol):
    parsed = parse_dns_message(response_packet)
    if not parsed or not parsed.get('domain') or not parsed.get('qtype'):
        parsed = parse_dns_message(query_packet) or {}
    if not parsed.get('domain') or not parsed.get('qtype'):
        return

    answers = compact_answers(parsed.get('answers', []), parsed.get('qtype', ''))
    record = {
        'ts': time.time(),
        'client': client,
        'protocol': protocol,
        'domain': parsed.get('domain', '').rstrip('.'),
        'qtype': parsed.get('qtype', ''),
        'rcode': parsed.get('rcode', ''),
        'answers': answers,
        'answers_text': ', '.join(answers),
    }
    append_answer_snapshot(record)


def append_answer_snapshot(record):
    with ANSWER_LOG_LOCK:
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
            with open(ANSWER_LOG, 'a') as f:
                f.write(json.dumps(record, ensure_ascii=False) + '\n')
            trim_answer_log()
        except Exception:
            pass


def trim_answer_log(max_lines=None):
    if max_lines is None:
        max_lines = get_log_cleanup_settings()['answer_lines']
    try:
        with open(ANSWER_LOG, 'r') as f:
            lines = f.readlines()
        if len(lines) <= max_lines:
            return
        with open(ANSWER_LOG, 'w') as f:
            f.writelines(lines[-max_lines:])
    except Exception:
        pass


def parse_dns_message(packet):
    if len(packet) < 12:
        return None
    try:
        _, flags, qd_count, an_count, ns_count, ar_count = struct.unpack('!HHHHHH', packet[:12])
        offset = 12
        questions = []
        for _ in range(qd_count):
            name, offset = read_dns_name(packet, offset)
            qtype, qclass = struct.unpack('!HH', packet[offset:offset + 4])
            offset += 4
            questions.append({'name': name, 'qtype': qtype, 'qclass': qclass})

        answers = []
        sections = [('answer', an_count), ('authority', ns_count), ('additional', ar_count)]
        for section, section_count in sections:
            for _ in range(section_count):
                if offset + 10 > len(packet):
                    raise ValueError('truncated record')
                name, offset = read_dns_name(packet, offset)
                rr_type, rr_class, ttl, rdlength = struct.unpack('!HHIH', packet[offset:offset + 10])
                offset += 10
                rdata_offset = offset
                offset += rdlength
                if offset > len(packet):
                    raise ValueError('truncated rdata')
                if section == 'answer':
                    answers.append({
                        'name': name,
                        'type': QTYPE_NAMES.get(rr_type, str(rr_type)),
                        'ttl': ttl,
                        'data': format_dns_rdata(packet, rdata_offset, rdlength, rr_type),
                    })

        question = questions[0] if questions else {}
        rcode = flags & 0x000f
        return {
            'domain': question.get('name', ''),
            'qtype': QTYPE_NAMES.get(question.get('qtype'), str(question.get('qtype', ''))),
            'rcode': RCODE_NAMES.get(rcode, str(rcode)),
            'answers': answers,
        }
    except Exception:
        return None


def read_answer_snapshots():
    records = []
    try:
        with open(ANSWER_LOG, 'r') as f:
            max_lines = get_log_cleanup_settings()['answer_lines']
            for line in f.readlines()[-max_lines:]:
                try:
                    records.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        pass
    return records


def parse_log_epoch(timestamp):
    try:
        fixed = re.sub(r'([+-]\d{2})(\d{2})$', r'\1:\2', timestamp)
        return datetime.fromisoformat(fixed).timestamp()
    except Exception:
        return None


def attach_recorded_answers(entries):
    snapshots = read_answer_snapshots()
    if not snapshots:
        return

    by_key = {}
    for item in snapshots:
        key = (str(item.get('domain', '')).lower().rstrip('.'), item.get('qtype', ''))
        by_key.setdefault(key, []).append(item)

    for entry in entries:
        if entry.get('level') == 'WARN':
            continue
        key = (entry.get('domain', '').lower().rstrip('.'), entry.get('qtype', ''))
        candidates = by_key.get(key, [])
        if not candidates:
            continue
        log_ts = parse_log_epoch(entry.get('time', ''))
        if log_ts is None:
            chosen = candidates[-1]
        else:
            chosen = min(candidates, key=lambda item: abs(float(item.get('ts', 0)) - log_ts))
            if abs(float(chosen.get('ts', 0)) - log_ts) > ANSWER_MATCH_WINDOW:
                continue
        entry['answers'] = chosen.get('answers', [])
        entry['answers_text'] = chosen.get('answers_text', '')
        entry['answer_source'] = '当时响应'


@app.route('/api/cache/flush', methods=['DELETE'])
def cache_flush():
    try:
        flushed = []
        for cfg in CACHE_DBS:
            r = get_redis(cfg['db'])
            r.flushdb()
            flushed.append({'db': cfg['db'], 'source': cfg['source']})
        return jsonify({'ok': True, 'flushed': flushed})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/query-log', methods=['GET'])
def query_log():
    lines_count = min(int(request.args.get('lines', 200)), 1000)
    search = request.args.get('search', '').lower()

    settings = get_log_cleanup_settings()
    log_size = os.path.getsize(MOSDNS_LOG) if os.path.exists(MOSDNS_LOG) else 0
    log_meta = {
        'size': log_size,
        'max_size': settings['max_bytes'],
        'clean_interval': settings['interval'],
        'answer_max_lines': settings['answer_lines'],
    }

    if not os.path.exists(MOSDNS_LOG):
        return jsonify({'entries': [], 'total': 0, 'log': log_meta})

    try:
        result = subprocess.run(
            ['tail', '-n', str(lines_count * 3), MOSDNS_LOG],
            capture_output=True, text=True, timeout=5
        )
        raw_lines = result.stdout.strip().split('\n') if result.stdout.strip() else []
    except Exception:
        raw_lines = []

    parsed_lines = []
    routes = {}
    routes_by_uqid = {}
    for idx, line in enumerate(raw_lines):
        parsed = parse_mosdns_log_line(line)
        if not parsed:
            continue
        parsed['_seq'] = idx
        if parsed.get('kind') == 'route':
            route_info = {
                'route': parsed.get('route', ''),
                'route_label': parsed.get('route_label', ''),
                '_seq': idx,
            }
            if parsed.get('uqid') is not None:
                routes_by_uqid[parsed['uqid']] = route_info
            key = route_key(parsed)
            if key:
                routes[key] = route_info
            continue
        parsed_lines.append(parsed)

    entries = []
    for parsed in parsed_lines:
        route_info = routes.get(route_key(parsed))
        if not route_info and parsed.get('uqid') is not None:
            route_info = routes_by_uqid.get(parsed['uqid'])
        if route_info:
            parsed['route'] = route_info.get('route', '')
            parsed['route_label'] = route_info.get('route_label', '')
        entries.append(parsed)

    attach_recorded_answers(entries)
    attach_cached_answers(entries)
    if search:
        entries = [
            entry for entry in entries
            if search in entry.get('domain', '').lower()
            or search in entry.get('message', '').lower()
            or search in entry.get('route_label', '').lower()
            or search in entry.get('answers_text', '').lower()
        ]
    entries.sort(key=lambda item: (item.get('time', ''), item.get('_seq', 0)), reverse=True)
    entries = entries[:lines_count]
    for entry in entries:
        entry.pop('_seq', None)
        entry.pop('kind', None)
        entry.pop('uqid', None)
    return jsonify({'entries': entries, 'total': len(entries), 'log': log_meta})


@app.route('/api/query-log', methods=['DELETE'])
def clear_query_log():
    try:
        with MOSDNS_LOG_LOCK:
            with open(MOSDNS_LOG, 'w'):
                pass
        with ANSWER_LOG_LOCK:
            with open(ANSWER_LOG, 'w'):
                pass
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def route_key(entry):
    uqid = entry.get('uqid')
    if uqid is None:
        return None
    return (uqid, entry.get('domain', ''), entry.get('qtype', ''))


def attach_cached_answers(entries):
    wanted = {
        (entry.get('domain', '').lower().rstrip('.'), entry.get('qtype', ''))
        for entry in entries
        if entry.get('domain') and entry.get('qtype') and entry.get('level') != 'WARN'
    }
    if not wanted:
        return

    lookup = find_cached_answers(wanted)
    for entry in entries:
        if entry.get('level') == 'WARN':
            continue
        if entry.get('answers_text'):
            continue
        key = (entry.get('domain', '').lower().rstrip('.'), entry.get('qtype', ''))
        cached = lookup.get(key)
        if not cached:
            continue
        entry['answers'] = cached.get('answers', [])
        entry['answers_text'] = cached.get('answers_text', '')
        entry['answer_source'] = cached.get('source', '')


def find_cached_answers(wanted):
    lookup = {}
    for cfg in CACHE_DBS:
        try:
            r = get_redis(cfg['db'])
            cursor = 0
            loops = 0
            while True:
                cursor, keys = r.scan(cursor=cursor, match='*', count=500)
                for key in keys:
                    entry = build_cache_entry(r, key, cfg)
                    cache_key = (
                        entry.get('domain', '').lower().rstrip('.'),
                        entry.get('qtype', ''),
                    )
                    if cache_key not in wanted or cache_key in lookup:
                        continue
                    answers = compact_answers(entry.get('answers', []), entry.get('qtype', ''))
                    if not answers:
                        continue
                    lookup[cache_key] = {
                        'answers': answers,
                        'answers_text': ', '.join(answers),
                        'source': entry.get('source', ''),
                    }
                    if len(lookup) >= len(wanted):
                        return lookup
                loops += 1
                if cursor == 0 or loops >= 100:
                    break
        except Exception:
            continue
    return lookup


def compact_answers(answers, qtype):
    if not answers:
        return []

    preferred_types = {qtype}
    if qtype in ('A', 'AAAA'):
        preferred_types = {qtype, 'CNAME'}

    values = []
    for answer in answers:
        answer_type = answer.get('type', '')
        if answer_type not in preferred_types:
            continue
        data = answer.get('data', '')
        if data and data not in values:
            values.append(data)
        if len(values) >= 6:
            break

    if values:
        return values

    for answer in answers:
        data = answer.get('data', '')
        if data and data not in values:
            values.append(data)
        if len(values) >= 6:
            break
    return values


def parse_mosdns_log_line(line):
    m = re.match(
        r'(\d{4}-\d{2}-\d{2}T[\d:.]+[+-]\d{2}:?\d{2})\s+'
        r'(\w+)\s+'
        r'(.+)',
        line
    )
    if not m:
        return None

    timestamp = m.group(1)
    level = m.group(2)
    message = m.group(3)

    domain = ''
    qtype = ''
    uqid = None
    route = ''
    kind = 'query'
    detail = message

    json_start = message.find('{')
    if json_start >= 0:
        prefix = message[:json_start].strip()
        prefix_parts = prefix.split()
        route_parts = [part for part in prefix_parts if part.startswith('route_')]
        if route_parts:
            route = route_parts[-1]
            kind = 'route'
        try:
            payload = json.loads(message[json_start:])
            domain = str(payload.get('qname') or '').rstrip('.')
            uqid = payload.get('uqid')
            qtype_value = payload.get('qtype')
            if isinstance(qtype_value, int):
                qtype = QTYPE_NAMES.get(qtype_value, str(qtype_value))
            elif qtype_value is not None:
                qtype = str(qtype_value)

            parts = []
            if payload.get('client'):
                parts.append(f"client={payload['client']}")
            if payload.get('rcode') is not None:
                parts.append(f"rcode={payload['rcode']}")
            if payload.get('elapsed'):
                parts.append(f"elapsed={payload['elapsed']}")
            if kind == 'route':
                detail = ROUTE_LABELS.get(route, route)
            else:
                detail = ' '.join(parts) or message
        except Exception:
            pass

    if not domain:
        domain_match = re.search(r'"qname":\s*"([^"]+)"', message)
        if domain_match:
            domain = domain_match.group(1).rstrip('.')

    if not qtype:
        qtype_match = re.search(r'"qtype":\s*(\d+|"[^"]+")', message)
        if qtype_match:
            raw_qtype = qtype_match.group(1).strip('"')
            if raw_qtype.isdigit():
                qtype = QTYPE_NAMES.get(int(raw_qtype), raw_qtype)
            else:
                qtype = raw_qtype

    if uqid is None:
        uqid_match = re.search(r'"uqid":\s*(\d+)', message)
        if uqid_match:
            uqid = int(uqid_match.group(1))

    if not route:
        route_match = re.search(r'\b(route_[A-Za-z0-9_]+)\b', message)
        if route_match:
            route = route_match.group(1)
            kind = 'route'

    if not domain:
        legacy_match = re.search(r'"([^"]+)"\s+(\w+)', message)
        if legacy_match:
            domain = legacy_match.group(1).rstrip('.')
            qtype = legacy_match.group(2)

    if not domain:
        return None

    return {
        'kind': kind,
        'time': timestamp,
        'level': level,
        'domain': domain,
        'qtype': qtype,
        'uqid': uqid,
        'route': route,
        'route_label': ROUTE_LABELS.get(route, route) if route else '',
        'message': detail[:300],
    }


def build_dns_query(domain, qtype):
    qtype_codes = {'A': 1, 'AAAA': 28, 'TXT': 16, 'HTTPS': 65}
    qtype_code = qtype_codes[qtype]
    query_id = int.from_bytes(os.urandom(2), 'big')
    labels = domain.rstrip('.').split('.')
    encoded_labels = [label.encode('idna') for label in labels]
    qname = b''.join(bytes([len(label)]) + label for label in encoded_labels) + b'\x00'
    header = struct.pack('!HHHHHH', query_id, 0x0100, 1, 0, 0, 0)
    return header + qname + struct.pack('!HH', qtype_code, 1)


def query_local_dns(domain, qtype):
    query_packet = build_dns_query(domain, qtype)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(10)
    started = time.monotonic()
    try:
        sock.sendto(query_packet, ('127.0.0.1', DNS_PROXY_LISTEN_PORT))
        response_packet, _ = sock.recvfrom(65535)
    finally:
        sock.close()
    elapsed_ms = round((time.monotonic() - started) * 1000, 2)
    parsed = parse_dns_message(response_packet) or {}
    answers = compact_answers(parsed.get('answers', []), qtype)
    return {
        'rcode': parsed.get('rcode', ''),
        'answers': answers,
        'answers_text': ', '.join(answers),
        'elapsed_ms': elapsed_ms,
    }


def find_route_after_offset(offset, domain, qtype, timeout=3):
    deadline = time.monotonic() + timeout
    domain = domain.lower().rstrip('.')
    while time.monotonic() < deadline:
        try:
            size = os.path.getsize(MOSDNS_LOG)
            if size < offset:
                offset = 0
            with open(MOSDNS_LOG, 'r', errors='replace') as log_file:
                log_file.seek(offset)
                lines = log_file.readlines()
        except OSError:
            lines = []

        parsed_lines = [parse_mosdns_log_line(line) for line in lines]
        parsed_lines = [item for item in parsed_lines if item]
        route_by_uqid = {
            item.get('uqid'): item
            for item in parsed_lines
            if item.get('kind') == 'route' and item.get('uqid') is not None
        }
        candidates = [
            item for item in parsed_lines
            if item.get('kind') != 'route'
            and item.get('domain', '').lower().rstrip('.') == domain
            and item.get('qtype') == qtype
        ]
        for candidate in reversed(candidates):
            route = route_by_uqid.get(candidate.get('uqid'))
            if route:
                return {
                    'route': route.get('route', ''),
                    'route_label': route.get('route_label', ''),
                    'message': candidate.get('message', ''),
                    'time': candidate.get('time', ''),
                }
        time.sleep(0.1)
    return {'route': '', 'route_label': '', 'message': '', 'time': ''}


def domain_matches_rule(domain, rule):
    rule = rule.strip()
    if not rule or rule.startswith('#'):
        return False
    if rule.startswith('full:'):
        return domain == rule[5:].lower().rstrip('.')
    if rule.startswith('domain:'):
        suffix = rule[7:].lower().rstrip('.')
        return domain == suffix or domain.endswith('.' + suffix)
    if rule.startswith('keyword:'):
        return rule[8:].lower() in domain
    if rule.startswith('regexp:'):
        try:
            return re.search(rule[7:], domain) is not None
        except re.error:
            return False
    suffix = rule.lower().rstrip('.')
    return domain == suffix or domain.endswith('.' + suffix)


def find_matching_rule(domain):
    settings = read_env_conf()
    settings.update(read_custom_env())
    route_mode = settings.get('ROUTE_MODE', 'cn_first')
    candidates = [
        ('强制转发', '/tmp/force_forward_list.txt'),
        ('强制加密 DNS', '/tmp/force_dnscrypt_list.txt'),
        ('强制本地递归', '/tmp/force_recurse_list.txt'),
    ]
    if route_mode == 'gfwlist':
        candidates.append(('GFWList', '/tmp/gfwlist.txt'))
    elif settings.get('USE_MARK_DATA', 'yes') == 'yes':
        candidates.extend([
            ('预分类 CN', '/tmp/cn_mark.dat'),
            ('预分类非 CN', '/tmp/global_mark.dat'),
        ])

    for source, filepath in candidates:
        try:
            with open(filepath, 'r', errors='replace') as rule_file:
                for line in rule_file:
                    rule = line.strip()
                    if domain_matches_rule(domain, rule):
                        return {'source': source, 'rule': rule, 'file': filepath}
        except OSError:
            continue
    return {'source': '动态解析判断', 'rule': '', 'file': ''}


@app.route('/api/route-test', methods=['POST'])
def route_test():
    data = request.get_json() or {}
    domain = str(data.get('domain', '')).strip().lower().rstrip('.')
    qtype = str(data.get('qtype', 'A')).strip().upper()
    if not domain or len(domain) > 253:
        return jsonify({'error': 'invalid domain'}), 400
    try:
        ascii_domain = domain.encode('idna').decode('ascii')
    except UnicodeError:
        return jsonify({'error': 'invalid domain'}), 400
    if not re.match(r'^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))*$', ascii_domain):
        return jsonify({'error': 'invalid domain'}), 400
    if qtype not in ('A', 'AAAA', 'TXT', 'HTTPS'):
        return jsonify({'error': 'unsupported query type'}), 400

    try:
        log_offset = os.path.getsize(MOSDNS_LOG)
    except OSError:
        log_offset = 0
    try:
        result = query_local_dns(ascii_domain, qtype)
    except (OSError, socket.timeout) as e:
        return jsonify({'error': f'DNS query failed: {e}'}), 502
    result.update(find_route_after_offset(log_offset, ascii_domain, qtype))
    result.update({
        'domain': domain,
        'ascii_domain': ascii_domain,
        'qtype': qtype,
        'matched_rule': find_matching_rule(ascii_domain),
    })
    settings = read_env_conf()
    settings.update(read_custom_env())
    ipv6_mode = settings.get('IPV6', 'no')
    result['ipv6_mode'] = ipv6_mode
    if qtype == 'AAAA' and not result.get('answers') and ipv6_mode != 'raw':
        result['notice'] = f'当前 IPv6 模式为 {ipv6_mode}，该模式可能主动过滤此域名的 AAAA；如需原样返回，请选择 raw'
    return jsonify(result)


if __name__ == '__main__':
    start_log_cleanup()
    start_dns_answer_proxy()
    app.run(host='0.0.0.0', port=8080, debug=False)
