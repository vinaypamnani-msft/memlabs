#!/usr/bin/env python3
"""memlabs Proxy Admin - Squid blocklist manager."""
import os, re, subprocess
from flask import Flask, request, redirect, url_for
from markupsafe import escape as _escape

app = Flask(__name__)
BLOCKLIST = "/etc/squid/blocklist.txt"

# Matches: domain names (.example.com, example.com), IPv4, IPv4/CIDR
_VALID_ENTRY = re.compile(
    r'^(?:'
    r'\.?[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?)*'
    r'|'
    r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?:/\d{1,2})?'
    r')$'
)

def _read_blocklist():
    if not os.path.isfile(BLOCKLIST):
        return []
    with open(BLOCKLIST, "r") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]

def _write_blocklist(entries):
    with open(BLOCKLIST, "w") as f:
        for e in sorted(set(entries)):
            f.write(e + "\n")
    subprocess.run(["squid", "-k", "reconfigure"], capture_output=True, timeout=10)

def _render(entries, error=None, success=None):
    rows = ""
    for e in entries:
        rows += (
            '<tr><td>{entry}</td><td>'
            '<form method="post" action="/delete" style="margin:0">'
            '<input type="hidden" name="entry" value="{entry}">'
            '<button type="submit" class="btn btn-sm btn-del">Remove</button>'
            '</form></td></tr>'
        ).format(entry=_escape(e))
    if not entries:
        rows = '<tr><td colspan="2" class="empty">No entries — all traffic is allowed through Squid.</td></tr>'
    alert = ""
    if error:
        alert = '<div class="alert alert-error">{}</div>'.format(_escape(error))
    if success:
        alert = '<div class="alert alert-ok">{}</div>'.format(_escape(success))
    return '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Proxy Admin</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,system-ui,"Segoe UI",Roboto,sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh;padding:2rem}
h1{font-size:1.5rem;margin-bottom:.25rem;color:#89b4fa}
.subtitle{color:#6c7086;margin-bottom:1.5rem;font-size:.9rem}
.card{background:#313244;border-radius:8px;padding:1.25rem;margin-bottom:1.25rem;border:1px solid #45475a}
table{width:100%%;border-collapse:collapse}
th{text-align:left;padding:.5rem;border-bottom:2px solid #45475a;color:#89b4fa;font-size:.85rem;text-transform:uppercase;letter-spacing:.05em}
td{padding:.5rem;border-bottom:1px solid #45475a;font-family:"Cascadia Code",Consolas,monospace;font-size:.9rem}
.empty{color:#6c7086;font-style:italic;text-align:center;padding:1.5rem;font-family:inherit}
.add-form{display:flex;gap:.5rem}
.add-form input[type=text]{flex:1;padding:.5rem .75rem;border:1px solid #45475a;border-radius:6px;background:#1e1e2e;color:#cdd6f4;font-size:.9rem;font-family:"Cascadia Code",Consolas,monospace}
.add-form input[type=text]:focus{outline:none;border-color:#89b4fa}
.btn{padding:.4rem .75rem;border:none;border-radius:6px;cursor:pointer;font-size:.85rem;font-weight:500;transition:background .15s}
.btn-add{background:#a6e3a1;color:#1e1e2e}.btn-add:hover{background:#94e2d5}
.btn-del{background:#f38ba8;color:#1e1e2e}.btn-del:hover{background:#eba0ac}
.btn-sm{padding:.25rem .5rem;font-size:.8rem}
.alert{padding:.75rem 1rem;border-radius:6px;margin-bottom:1rem;font-size:.9rem}
.alert-error{background:#45475a;border:1px solid #f38ba8;color:#f38ba8}
.alert-ok{background:#45475a;border:1px solid #a6e3a1;color:#a6e3a1}
.help{color:#6c7086;font-size:.8rem;margin-top:.75rem}
</style></head><body>
<h1>Proxy Admin</h1>
<p class="subtitle">Squid blocklist manager &mdash; blocked domains and IPs are denied through the proxy.</p>
''' + alert + '''
<div class="card">
<form method="post" action="/add" class="add-form">
<input type="text" name="entry" placeholder=".example.com or 1.2.3.4 or 10.0.0.0/8" required autofocus>
<button type="submit" class="btn btn-add">Block</button>
</form>
<p class="help">Prefix with a dot to block all subdomains (e.g. <code>.windowsupdate.com</code> blocks <code>www.windowsupdate.com</code>). Plain domains block exact matches. IPv4 addresses and CIDR ranges also accepted.</p>
</div>
<div class="card">
<table><thead><tr><th>Blocked Entry</th><th style="width:100px">Action</th></tr></thead>
<tbody>''' + rows + '''</tbody></table>
</div>
</body></html>'''

@app.route("/")
def index():
    return _render(_read_blocklist(), success=request.args.get("ok"))

@app.route("/add", methods=["POST"])
def add():
    entry = (request.form.get("entry") or "").strip().lower()
    if not entry:
        return _render(_read_blocklist(), error="Entry cannot be empty.")
    if not _VALID_ENTRY.match(entry):
        return _render(_read_blocklist(), error="Invalid entry. Use a domain (.example.com), IP (1.2.3.4), or CIDR (10.0.0.0/8).")
    if len(entry) > 253:
        return _render(_read_blocklist(), error="Entry too long (max 253 characters).")
    entries = _read_blocklist()
    if entry in entries:
        return _render(entries, error="'{}' is already blocked.".format(entry))
    entries.append(entry)
    _write_blocklist(entries)
    return redirect(url_for("index", ok="Added '{}'.".format(entry)))

@app.route("/delete", methods=["POST"])
def delete():
    entry = (request.form.get("entry") or "").strip()
    entries = _read_blocklist()
    entries = [e for e in entries if e != entry]
    _write_blocklist(entries)
    return redirect(url_for("index", ok="Removed '{}'.".format(entry)))

@app.route("/health")
def health():
    return "ok", 200

if __name__ == "__main__":
    os.makedirs(os.path.dirname(BLOCKLIST), exist_ok=True)
    if not os.path.isfile(BLOCKLIST):
        open(BLOCKLIST, "a").close()
    app.run(host="0.0.0.0", port=8443)
