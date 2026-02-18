#!/usr/bin/env bash
set -euo pipefail
umask 027

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

APP_NAME="google-egress-check"
APP_DIR="/opt/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
UPLOAD_DIR="${STATE_DIR}/uploads"
LOG_DIR="/var/log/${APP_NAME}"
APP_FILE="${APP_DIR}/app.py"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
XRAY_DROPIN_DIR="/etc/systemd/system/xray.service.d"
XRAY_DROPIN_FILE="${XRAY_DROPIN_DIR}/10-runtime-user.conf"
SKIP_APT="${SKIP_APT:-0}"

step(){ echo "[$1] $2"; }

wait_pkg(){
  local timeout=900 waited=0
  while pgrep -x unattended-upgr >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      echo "Timed out waiting for apt lock"
      return 1
    fi
    echo "Waiting for package manager lock... ${waited}/${timeout}s"
    sleep 5
    waited=$((waited+5))
  done
}

install_deps(){
  step "1/8" "Installing dependencies"
  if [[ "${SKIP_APT}" == "1" ]]; then
    echo "SKIP_APT=1 set; skipping apt install step"
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  wait_pkg || true
  apt-get -o DPkg::Lock::Timeout=1200 update -y
  apt-get -o DPkg::Lock::Timeout=1200 install -y python3 python3-venv curl jq dnsutils sudo ca-certificates
}

install_xray(){
  if command -v xray >/dev/null 2>&1; then
    step "2/8" "Xray already installed"
    return
  fi
  step "2/8" "Installing Xray"
  local t
  t="$(mktemp)"
  curl -fsSL "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$t"
  bash "$t" install
  rm -f "$t"
}

ensure_xray_identity(){
  step "3/8" "Configuring Xray runtime user"
  getent group xray >/dev/null 2>&1 || groupadd --system xray
  id -u xray >/dev/null 2>&1 || useradd --system --gid xray --home-dir /nonexistent --shell /usr/sbin/nologin xray
  mkdir -p "$XRAY_DROPIN_DIR"
  cat > "$XRAY_DROPIN_FILE" <<'EOF'
[Service]
User=xray
Group=xray
EOF
}

detect_cfg(){
  [[ -f /usr/local/etc/xray/config.json ]] && { echo /usr/local/etc/xray/config.json; return; }
  [[ -f /etc/xray/config.json ]] && { echo /etc/xray/config.json; return; }
  echo /usr/local/etc/xray/config.json
}

xray_user(){
  local u
  u="$(systemctl show -p User --value xray 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$u" ]] && echo "$u" || echo root
}

xray_group(){
  local g
  g="$(systemctl show -p Group --value xray 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$g" ]]; then
    local u
    u="$(xray_user)"
    g="$(id -gn "$u" 2>/dev/null || true)"
  fi
  [[ -n "$g" ]] && echo "$g" || echo root
}

cfg_perms(){
  local cfg="$1" u g d
  u="$(xray_user)"
  g="$(xray_group)"
  d="$(dirname "$cfg")"
  if [[ "$u" == "root" ]]; then
    chown root:root "$d" 2>/dev/null || true
    chmod 0750 "$d" 2>/dev/null || true
    chown root:root "$cfg"
    chmod 0600 "$cfg"
    return
  fi
  getent group "$g" >/dev/null 2>&1 || g=root
  chown root:"$g" "$d" 2>/dev/null || true
  chmod 0750 "$d" 2>/dev/null || true
  chown root:"$g" "$cfg" || chown root:root "$cfg"
  chmod 0640 "$cfg"
}

ensure_base_cfg(){
  step "4/8" "Ensuring Xray base config"
  local cfg tmp
  cfg="$(detect_cfg)"
  mkdir -p "$(dirname "$cfg")"
  if [[ ! -f "$cfg" ]]; then
    cat > "$cfg" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "google-egress-socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {}}]
}
JSON
  fi
  jq empty "$cfg" >/dev/null
  tmp="$(mktemp)"
  jq '(.inbounds //= []) | (.outbounds //= []) |
      (if any(.inbounds[]?; (.protocol=="socks") and (((.port|tonumber?)//-1)==10808))
       then . else .inbounds += [{"tag":"google-egress-socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true}}] end) |
      (if (.outbounds|length)==0 then .outbounds=[{"tag":"direct","protocol":"freedom","settings":{}}] else . end)' "$cfg" > "$tmp"
  install -m 0640 -o root -g root "$tmp" "$cfg"
  rm -f "$tmp"
  cfg_perms "$cfg"
}

write_app(){
  step "5/8" "Writing Python web app"
  rm -f /usr/local/sbin/google-egress-xray-test /usr/local/sbin/google-egress-xray-logctl /etc/sudoers.d/google-egress-check
  systemctl disable --now google-egress-check.service >/dev/null 2>&1 || true
  mkdir -p "$APP_DIR" "$STATE_DIR" "$UPLOAD_DIR" "$LOG_DIR"
  chmod 0750 "$APP_DIR" "$STATE_DIR" "$UPLOAD_DIR" "$LOG_DIR"
  chown root:root "$APP_DIR" "$STATE_DIR" "$UPLOAD_DIR" "$LOG_DIR"
  cat > "$APP_FILE" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import cgi
import copy
import fcntl
import io
import ipaddress
import json
import logging
import os
import re
import stat
import subprocess
import tempfile
import threading
from collections import Counter
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

APP="google-egress-check"
STATE=Path("/var/lib/google-egress-check")
UPLOAD=STATE/"uploads"
LOG=Path("/var/log/google-egress-check")
STATUS=STATE/"latest_status.json"
LOCK=STATE/"upload.lock"
ACCESS=LOG/"xray-access.log"
ERROR=LOG/"xray-error.log"
CANDS=(Path("/usr/local/etc/xray/config.json"),Path("/etc/xray/config.json"))
PROXY="socks5h://127.0.0.1:10808"
DOH_TXT="https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT"
DOH_A="https://dns.google/resolve?name=www.google.com&type=A"
MAX_UPLOAD=1_000_000
MAX_BODY=1_100_000

LOGR=logging.getLogger(APP)
SLOCK=threading.Lock()
ULOCK=threading.Lock()
IP_RE=re.compile(r"\\b(?:\\d{1,3}(?:\\.\\d{1,3}){3}|[0-9A-Fa-f:]{2,})\\b")
SENS=re.compile(r'("?(?:id|uuid|password|pass|privatekey|private_key|shortid|short_id|token|secret)"?\\s*:\\s*")([^"]+)(")',re.I)
UUID_RE=re.compile(r"\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b")
TOKEN_RE=re.compile(r"\\b[A-Za-z0-9+=_-]{24,}\\b")
LATEST={"status":"idle","message":"Upload config.json to run Google egress validation","checked_at":""}

HTML="""<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Google Egress Accuracy Validator</title><style>body{margin:0;font-family:Arial,sans-serif;background:linear-gradient(140deg,#071426,#1b3e66);color:#13243a}.w{max-width:1100px;margin:24px auto;padding:16px}.p{background:#fff;border-radius:14px;overflow:hidden}.h{display:flex;justify-content:space-between;padding:12px 16px;border-bottom:1px solid #dce7f2;background:#eef6ff}.chip{padding:6px 10px;border-radius:999px;font-weight:700}.idle{background:#dbeafe}.ok{background:#d1fae5}.bad{background:#fee2e2}.g{display:grid;grid-template-columns:repeat(12,1fr);gap:10px;padding:14px}.c{border:1px solid #e2e8f0;border-radius:10px;padding:10px}.w12{grid-column:span 12}.w6{grid-column:span 6}.w3{grid-column:span 3}.k{color:#4f637a;font-size:.8rem;text-transform:uppercase}.v{font-size:1.05rem;font-weight:700;word-break:break-word}.m{font-family:Consolas,monospace}input{width:100%;padding:10px}button{padding:10px 14px;border:0;border-radius:8px;background:#0284c7;color:#fff;font-weight:700}pre{margin:8px 0 0;padding:10px;background:#0f172a;color:#e2e8f0;border-radius:8px;max-height:260px;overflow:auto}.err{display:none;margin-top:8px;padding:8px;border:1px solid #fecaca;background:#fef2f2;color:#991b1b}@media(max-width:900px){.w6,.w3{grid-column:span 12}}</style></head><body><div class='w'><h2 style='color:#e6f3ff'>Google Egress Accuracy Validator</h2><div class='p'><div class='h'><div id='chip' class='chip idle'>Status: idle</div><div>API: /api/status | Health: /healthz</div></div><div class='g'><div class='c w12'><div class='k'>Upload Xray Config</div><form id='f' style='display:grid;grid-template-columns:1fr auto;gap:8px'><input id='file' type='file' required><button id='btn'>Submit</button></form><div style='font-size:.82rem;color:#4f637a;margin-top:6px'>Max file size: 1MB. Previous active Xray config is always restored after each test.</div><div id='err' class='err'></div></div><div class='c w6'><div class='k'>Google-Seen IP</div><div id='google' class='v m'>-</div></div><div class='c w6'><div class='k'>Generic Public IP</div><div id='generic' class='v m'>-</div></div><div class='c w3'><div class='k'>Outbound Tag</div><div id='tag' class='v m'>-</div></div><div class='c w3'><div class='k'>Routing Split</div><div id='split' class='v'>-</div></div><div class='c w3'><div class='k'>DNS Leak</div><div id='dns' class='v'>-</div></div><div class='c w3'><div class='k'>IPv6 Leak</div><div id='ipv6' class='v'>-</div></div><div class='c w12'><div class='k'>Country / ISP / ASN</div><div id='geo' class='v'>-</div><div id='ts' style='color:#4f637a;font-size:.82rem'>-</div></div><div class='c w6'><div class='k'>Latest JSON</div><pre id='json' class='m'>{}</pre></div><div class='c w6'><div class='k'>Xray Journal Tail</div><pre id='jr' class='m'></pre></div></div></div></div><script>const by=id=>document.getElementById(id);const yn=v=>v?'Yes':'No';function chip(s){const c=by('chip');c.className='chip '+(s==='success'?'ok':(s==='invalid_config'?'bad':'idle'));c.textContent='Status: '+(s||'idle')}function r(d){by('json').textContent=JSON.stringify(d,null,2);by('google').textContent=d.google_seen_ip||'-';by('generic').textContent=d.generic_ip||'-';by('tag').textContent=d.google_outbound_tag||'-';by('split').textContent=d.routing_split===undefined?'-':yn(!!d.routing_split);by('dns').textContent=d.dns_leak===undefined?'-':yn(!!d.dns_leak);by('ipv6').textContent=d.ipv6_leak===undefined?'-':yn(!!d.ipv6_leak);by('geo').textContent=[d.country||'-',d.isp||'-',d.asn||'-'].join(' / ');by('ts').textContent=d.checked_at||'-';chip(d.status);if(d.status==='invalid_config'){by('err').style.display='block';by('err').textContent='This config is not working / cannot connect: '+(d.error||'invalid');by('jr').textContent=d.xray_journal_tail||''}else{by('err').style.display='none';by('jr').textContent=''}}async function load(){try{const x=await fetch('/api/status',{cache:'no-store'});r(await x.json())}catch{r({status:'invalid_config',error:'Unable to load status'})}}by('f').addEventListener('submit',async e=>{e.preventDefault();const fl=by('file');if(!fl.files||!fl.files.length)return;const f=fl.files[0];if(f.size>1000000){r({status:'invalid_config',error:'File exceeds 1MB limit'});return}const b=by('btn');b.disabled=true;b.textContent='Testing...';try{const fd=new FormData();fd.append('config',f);const x=await fetch('/upload',{method:'POST',body:fd});r(await x.json())}catch{r({status:'invalid_config',error:'Upload failed'})}finally{b.disabled=false;b.textContent='Submit'}});load()</script></body></html>"""

def now(): return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def run(args:list[str],timeout:int=30): return subprocess.run(args,capture_output=True,text=True,timeout=timeout,shell=False)

def mask(t:str)->str:
    t=SENS.sub(r"\\1***MASKED***\\3",t)
    t=UUID_RE.sub("***UUID***",t)
    def repl(m):
        v=m.group(0)
        return v if ("." in v and "/" not in v) else "***TOKEN***"
    return TOKEN_RE.sub(repl,t)

def sani(v:Any)->Any:
    if isinstance(v,dict): return {str(k):sani(x) for k,x in v.items()}
    if isinstance(v,list): return [sani(x) for x in v]
    if isinstance(v,str): return mask(v)
    return v

def ensure_dirs():
    for p in (STATE,UPLOAD,LOG): p.mkdir(parents=True,exist_ok=True)
    for p in (STATE,UPLOAD,LOG): os.chmod(p,0o750)

def save_status(d:dict[str,Any]):
    d=sani(d); d.setdefault("checked_at",now())
    with SLOCK:
        global LATEST
        LATEST=d
        STATUS.write_text(json.dumps(d,ensure_ascii=True,separators=(",",":")),encoding="utf-8")

def load_status()->dict[str,Any]:
    if not STATUS.exists(): return copy.deepcopy(LATEST)
    try:
        d=json.loads(STATUS.read_text(encoding="utf-8"))
        return sani(d) if isinstance(d,dict) else copy.deepcopy(LATEST)
    except Exception:
        return copy.deepcopy(LATEST)

def cfg_path()->Path:
    for p in CANDS:
        if p.exists(): return p
    raise RuntimeError("Xray config path not found")

def xray_identity()->tuple[str,str]:
    u=run(["systemctl","show","-p","User","--value","xray"],10).stdout.strip() or "root"
    g=run(["systemctl","show","-p","Group","--value","xray"],10).stdout.strip()
    if not g:
        try: g=run(["id","-gn",u],10).stdout.strip()
        except Exception: g=""
    return u,(g or "root")

def apply_perms(p:Path,u:str,g:str):
    d=p.parent
    if u=="root":
        os.chown(d,0,0); os.chmod(d,0o750); os.chown(p,0,0); os.chmod(p,0o600); return
    gid=0
    try: gid=run(["getent","group",g],10).returncode==0 and __import__("grp").getgrnam(g).gr_gid or 0
    except Exception: gid=0
    os.chown(d,0,gid); os.chmod(d,0o750); os.chown(p,0,gid); os.chmod(p,0o640)

def write_cfg(path:Path,obj:dict[str,Any],u:str,g:str):
    t=path.with_suffix(f".tmp.{os.getpid()}")
    t.write_text(json.dumps(obj,ensure_ascii=True,separators=(",",":")),encoding="utf-8")
    os.replace(t,path)
    apply_perms(path,u,g)

def prep_cfg(c:dict[str,Any])->dict[str,Any]:
    x=copy.deepcopy(c)
    ins=x.get("inbounds") if isinstance(x.get("inbounds"),list) else []
    outs=x.get("outbounds") if isinstance(x.get("outbounds"),list) else []
    ok=False
    for i in ins:
        if isinstance(i,dict) and str(i.get("protocol","")).lower()=="socks":
            try:
                if int(i.get("port",-1))==10808: ok=True; break
            except Exception: pass
    if not ok: ins.append({"tag":"google-egress-socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":True}})
    if not outs: outs=[{"tag":"direct","protocol":"freedom","settings":{}}]
    lg=x.get("log") if isinstance(x.get("log"),dict) else {}
    lg.pop("access",None); lg.pop("error",None); lg.setdefault("loglevel","warning")
    x["inbounds"]=ins; x["outbounds"]=outs; x["log"]=lg
    return x

def restart_xray()->bool:
    if run(["systemctl","restart","xray"],45).returncode!=0: return False
    p=run(["systemctl","is-active","xray"],10)
    return p.returncode==0 and p.stdout.strip()=="active"

def curl_text(url:str,proxy:bool=True,max_time:int=20,ipv6:bool=False,extra:list[str]|None=None)->str:
    a=["curl","-sS","-L","--max-time",str(max_time),"--connect-timeout","8"]
    if proxy: a.extend(["--proxy",PROXY])
    if ipv6: a.append("-6")
    if extra: a.extend(extra)
    a.append(url)
    p=run(a,max_time+15)
    return p.stdout.strip() if p.returncode==0 else ""

def curl_code(url:str,proxy:bool=True,max_time:int=20)->str:
    a=["curl","-sS","-L","--max-time",str(max_time),"--connect-timeout","8","-o","/dev/null","-w","%{http_code}"]
    if proxy: a.extend(["--proxy",PROXY])
    a.append(url)
    p=run(a,max_time+15)
    return p.stdout.strip() if p.returncode==0 else ""

def first_ip(t:str)->str:
    for z in IP_RE.findall(t or ""):
        try: ipaddress.ip_address(z); return z
        except Exception: pass
    return ""

def google_ip(txt:str)->str:
    try:
        d=json.loads(txt)
        ans=d.get("Answer",[])
        if isinstance(ans,list):
            for r in ans:
                if isinstance(r,dict):
                    s=str(r.get("data","")).replace('"','').strip()
                    try: ipaddress.ip_address(s); return s
                    except Exception:
                        z=first_ip(s)
                        if z: return z
    except Exception:
        pass
    return first_ip(txt)

def maj(v:list[str])->str:
    v=[x for x in v if x]
    return Counter(v).most_common(1)[0][0] if v else ""

def parse_tag(t:str)->str:
    tag=""
    pats=[re.compile(r"\\[[^\\]]*->\\s*([A-Za-z0-9._-]+)\\]"),re.compile(r'outboundTag[=: ]"?([A-Za-z0-9._-]+)"?'),re.compile(r'"outboundTag"\\s*:\\s*"([A-Za-z0-9._-]+)"')]
    for ln in (t or "").splitlines():
        ll=ln.lower()
        if "google" not in ll and "dns.google" not in ll: continue
        for p in pats:
            m=p.search(ln)
            if m: tag=m.group(1)
    return tag or "unknown"

def journal()->str:
    p=run(["journalctl","-u","xray","-n","80","--no-pager"],30)
    return mask((p.stdout or "")+(p.stderr or ""))[:16000]

def geo(ip:str)->tuple[str,str,str]:
    if not ip: return "","", ""
    t=curl_text(f"http://ip-api.com/json/{ip}?fields=status,country,isp,as",proxy=False,max_time=12)
    if not t: return "","", ""
    try:
        d=json.loads(t)
        if d.get("status")!="success": return "","", ""
        return str(d.get("country","") or ""),str(d.get("isp","") or ""),str(d.get("as","") or "")
    except Exception:
        return "","", ""

def dns_leak()->bool:
    d=run(["dig","+short","A","www.google.com"],15).stdout.splitlines()
    direct=sorted({x.strip() for x in d if re.fullmatch(r"\\d+\\.\\d+\\.\\d+\\.\\d+",x.strip())})
    p=curl_text(DOH_A,proxy=True,max_time=15)
    proxy=[]
    try:
        j=json.loads(p)
        for r in j.get("Answer",[]):
            if isinstance(r,dict):
                x=str(r.get("data","")).strip()
                if re.fullmatch(r"\\d+\\.\\d+\\.\\d+\\.\\d+",x): proxy.append(x)
    except Exception:
        pass
    proxy=sorted(set(proxy))
    return bool(direct and proxy and direct!=proxy)

def ipv6_leak()->bool:
    if not run(["ip","-6","route","show","default"],10).stdout.strip(): return False
    dv6=first_ip(curl_text("https://api64.ipify.org",proxy=False,max_time=12,ipv6=True))
    pv6=first_ip(curl_text("https://api64.ipify.org",proxy=True,max_time=12,ipv6=True))
    return bool(dv6 and not pv6)

def invalid(msg:str,fn:str=""):
    d={"status":"invalid_config","error":mask(msg)[:6000],"xray_journal_tail":journal(),"checked_at":now()}
    if fn: d["uploaded_filename"]=fn
    return d

def analyze(cfg:dict[str,Any],fn:str)->dict[str,Any]:
    p=None; old=None; st=None
    try:
        p=cfg_path(); old=p.read_bytes(); st=p.stat(); u,g=xray_identity()
        c=prep_cfg(cfg)
        write_cfg(p,c,u,g)
        if not restart_xray(): return invalid("Xray failed to restart with uploaded config",fn)
        code=curl_code("https://www.google.com",proxy=True,max_time=20)
        if not re.fullmatch(r"\\d{3}",code) or code=="000": return invalid("Proxied request to Google failed",fn)
        gs=[]
        for _ in range(2):
            ip=google_ip(curl_text(DOH_TXT,proxy=True,max_time=20))
            if ip: gs.append(ip)
        gip=maj(gs)
        if not gip: return invalid("Google DoH did not return a valid google_seen_ip",fn)
        ps=[]
        for _ in range(2):
            ip=first_ip(curl_text("https://api.ipify.org",proxy=True,max_time=15))
            if ip: ps.append(ip)
        pip=maj(ps)
        lc=copy.deepcopy(c)
        lg=lc.get("log") if isinstance(lc.get("log"),dict) else {}
        lg["access"]=str(ACCESS); lg["error"]=str(ERROR); lg["loglevel"]="info"
        lc["log"]=lg
        LOG.mkdir(parents=True,exist_ok=True)
        ACCESS.write_text("",encoding="utf-8"); ERROR.write_text("",encoding="utf-8")
        os.chmod(ACCESS,0o640); os.chmod(ERROR,0o640)
        write_cfg(p,lc,u,g)
        if not restart_xray(): return invalid("Failed to enable temporary Xray access log",fn)
        _=curl_code("https://www.google.com",proxy=True,max_time=20)
        tag=parse_tag(ACCESS.read_text(encoding="utf-8",errors="ignore") if ACCESS.exists() else "")
        write_cfg(p,c,u,g)
        if not restart_xray(): return invalid("Failed to restore uploaded config after log tracing",fn)
        dnl=dns_leak(); i6=ipv6_leak(); split=bool(gip and pip and gip!=pip)
        country,isp,asn=geo(gip or pip)
        return {"status":"success","google_seen_ip":gip,"google_outbound_tag":tag,"generic_ip":pip,"routing_split":split,"country":country,"isp":isp,"asn":asn,"dns_leak":dnl,"ipv6_leak":i6,"checked_at":now(),"uploaded_filename":fn}
    except Exception as e:
        LOGR.exception("analysis failed")
        return invalid(f"Unhandled error: {e}",fn)
    finally:
        if p is not None and old is not None and st is not None:
            try:
                with tempfile.NamedTemporaryFile("wb",delete=False,dir=str(p.parent)) as f:
                    f.write(old); t=Path(f.name)
                os.replace(t,p)
                os.chown(p,st.st_uid,st.st_gid)
                os.chmod(p,stat.S_IMODE(st.st_mode))
                restart_xray()
            except Exception:
                LOGR.exception("restore failed")

class H(BaseHTTPRequestHandler):
    server_version="GoogleEgress/2.0"
    def log_message(self,fmt,*args): LOGR.info("%s - %s",self.address_string(),mask(fmt%args))
    def js(self,code,obj):
        b=json.dumps(sani(obj),ensure_ascii=True,separators=(",",":")).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type","application/json; charset=utf-8"); self.send_header("Cache-Control","no-store"); self.send_header("X-Content-Type-Options","nosniff"); self.send_header("X-Frame-Options","DENY"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def html(self,code,s):
        b=s.encode("utf-8")
        self.send_response(code); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Cache-Control","no-store"); self.send_header("X-Content-Type-Options","nosniff"); self.send_header("X-Frame-Options","DENY"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=urlparse(self.path).path
        if p in ("/","/index.html"): self.html(HTTPStatus.OK,HTML); return
        if p=="/api/status":
            with SLOCK: d=copy.deepcopy(LATEST)
            self.js(HTTPStatus.OK,d); return
        if p=="/healthz": self.js(HTTPStatus.OK,{"status":"ok"}); return
        self.js(HTTPStatus.NOT_FOUND,{"status":"not_found"})
    def do_POST(self):
        if urlparse(self.path).path!="/upload": self.js(HTTPStatus.NOT_FOUND,{"status":"not_found"}); return
        if not ULOCK.acquire(blocking=False): self.js(HTTPStatus.CONFLICT,{"status":"busy","error":"Another upload is currently being processed"}); return
        fd=None
        try:
            cl=self.headers.get("Content-Length","0").strip()
            if not cl.isdigit() or int(cl)<=0: raise ValueError("Empty request body")
            if int(cl)>MAX_BODY: raise ValueError("Payload too large (max 1MB)")
            ct=self.headers.get("Content-Type","")
            t,_=cgi.parse_header(ct)
            if t!="multipart/form-data": raise ValueError("Content-Type must be multipart/form-data")
            body=self.rfile.read(int(cl))
            if len(body)!=int(cl): raise ValueError("Incomplete upload body")
            form=cgi.FieldStorage(fp=io.BytesIO(body),headers=self.headers,environ={"REQUEST_METHOD":"POST","CONTENT_TYPE":ct,"CONTENT_LENGTH":cl})
            field=form["config"] if "config" in form else (form["file"] if "file" in form else None)
            if field is None: raise ValueError("Missing file field 'config'")
            if isinstance(field,list): field=field[0]
            if not getattr(field,"file",None): raise ValueError("Missing file content")
            name=("".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in (getattr(field,"filename","") or "config.json")))[:80] or "config.json"
            raw=field.file.read(MAX_UPLOAD+1)
            if isinstance(raw,str): raw=raw.encode("utf-8")
            if not raw: raise ValueError("Uploaded file is empty")
            if len(raw)>MAX_UPLOAD: raise ValueError("config.json exceeds 1MB limit")
            try:
                txt=raw.decode("utf-8")
                cfg=json.loads(txt)
            except Exception as e:
                raise ValueError(f"Invalid JSON: {e}")
            if not isinstance(cfg,dict): raise ValueError("Xray config root must be a JSON object")
            LOCK.parent.mkdir(parents=True,exist_ok=True)
            fd=os.open(str(LOCK),os.O_CREAT|os.O_RDWR,0o640)
            fcntl.flock(fd,fcntl.LOCK_EX)
            res=analyze(cfg,name)
        except Exception as e:
            res=invalid(str(e))
        finally:
            if fd is not None:
                try: fcntl.flock(fd,fcntl.LOCK_UN); os.close(fd)
                except Exception: pass
            ULOCK.release()
        save_status(res)
        self.js(HTTPStatus.OK,res)

def main():
    logging.basicConfig(level=logging.INFO,format="%(asctime)s %(levelname)s %(message)s")
    ensure_dirs()
    with SLOCK:
        global LATEST
        LATEST=load_status()
    srv=ThreadingHTTPServer(("0.0.0.0",80),H)
    srv.daemon_threads=True
    LOGR.info("Listening on port 80")
    srv.serve_forever()

if __name__=="__main__":
    main()
PY
  chmod 0750 "$APP_FILE"
}

write_service(){
  step "6/8" "Writing systemd unit"
  cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Google Egress Upload Validator
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/google-egress-check
ExecStart=/usr/bin/python3 /opt/google-egress-check/app.py
Restart=always
RestartSec=2
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT
}

start_all(){
  step "7/8" "Starting xray and web service"
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
  if ! systemctl is-active --quiet xray; then
    echo "xray service is not active"
    journalctl -u xray -n 80 --no-pager || true
    exit 1
  fi
  systemctl enable --now "$APP_NAME.service"
  systemctl restart "$APP_NAME.service"
  if ! systemctl is-active --quiet "$APP_NAME.service"; then
    echo "$APP_NAME.service failed"
    journalctl -u "$APP_NAME.service" -n 80 --no-pager || true
    exit 1
  fi
  local ok=0
  for _ in 1 2 3 4 5; do
    if curl -fsS --max-time 5 http://127.0.0.1/healthz | jq -e '.status=="ok"' >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [[ "$ok" == "1" ]] || { echo "Health check failed"; exit 1; }
}

finish(){
  step "8/8" "Completed"
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$ip" ]]; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  [[ -n "$ip" ]] || ip="SERVER_IP"
  echo "Install complete. Visit http://${ip}/"
}

install_deps
install_xray
ensure_xray_identity
systemctl daemon-reload
ensure_base_cfg
write_app
write_service
start_all
finish
