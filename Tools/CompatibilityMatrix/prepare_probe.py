# -*- coding: utf-8 -*-
"""A tiny LSP client to observe SourceKit-LSP: progress, diagnostics, how soon completion works.

usage: lsp_probe.py ROOT FILE_REL LANG APPEND_TEXT EXPECT [--init JSON] [--seconds N] [--args "..."] [--noroot]
Opens FILE (with APPEND_TEXT added at the end, unsaved), polls completion at the end every 2 s until
a label containing EXPECT appears or time runs out. Prints a timeline.
"""
import json, os, subprocess, sys, threading, time, queue, signal

def main():
    a = sys.argv[1:]
    root, rel, lang, append, expect = a[:5]
    init = {}
    seconds = 90
    extra = []
    noroot = False
    i = 5
    while i < len(a):
        if a[i] == '--init': init = json.loads(a[i+1]); i += 2
        elif a[i] == '--seconds': seconds = int(a[i+1]); i += 2
        elif a[i] == '--args': extra = a[i+1].split(); i += 2
        elif a[i] == '--noroot': noroot = True; i += 1
        else: raise SystemExit('bad arg ' + a[i])

    exe = subprocess.check_output(['xcrun', '--find', 'sourcekit-lsp']).decode().strip()
    t0 = time.time()
    def now(): return '%6.2fs' % (time.time() - t0)
    p = subprocess.Popen([exe] + extra, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=root)
    inbox = queue.Queue()
    def reader():
        f = p.stdout
        while True:
            headers = {}
            while True:
                line = f.readline()
                if not line: inbox.put(None); return
                line = line.strip()
                if not line: break
                k, _, v = line.decode().partition(':')
                headers[k.lower()] = v.strip()
            n = int(headers.get('content-length', 0))
            body = f.read(n)
            inbox.put(json.loads(body))
    threading.Thread(target=reader, daemon=True).start()
    nid = [0]
    def send(obj):
        data = json.dumps(obj).encode()
        p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(data) + data); p.stdin.flush()
    def request(method, params):
        nid[0] += 1; send({'jsonrpc': '2.0', 'id': nid[0], 'method': method, 'params': params}); return nid[0]
    def notify(method, params): send({'jsonrpc': '2.0', 'method': method, 'params': params})

    rooturi = 'file://' + os.path.realpath(root)
    path = os.path.join(os.path.realpath(root), rel)
    uri = 'file://' + path
    text = open(path).read() + append
    lines = text.split('\n')
    pos = {'line': len(lines) - 1, 'character': len(lines[-1])}

    params = {'processId': os.getpid(), 'rootUri': None if noroot else rooturi,
              'capabilities': {'window': {'workDoneProgress': True},
                               'textDocument': {'publishDiagnostics': {'versionSupport': True},
                                                'completion': {'completionItem': {'snippetSupport': False}}},
                               'workspace': {'configuration': True}},
              'initializationOptions': init}
    request('initialize', params)
    events = []
    def log(s): events.append(now() + ' ' + s); print(now(), s, flush=True)

    state = {'init': False, 'opened': False, 'pending': None, 'found': None, 'first_diag': None, 'asked': 0, 'last_ask': 0}
    deadline = t0 + seconds
    def short(x, n=160):
        s = json.dumps(x, ensure_ascii=False); return s if len(s) <= n else s[:n] + '…'
    while time.time() < deadline and state['found'] is None:
        try: m = inbox.get(timeout=0.5)
        except queue.Empty: m = 'tick'
        if m is None: log('server exited'); break
        if m != 'tick':
            if 'method' in m and 'id' in m:                       # request from the server
                meth = m['method']
                if meth == 'workspace/configuration': send({'jsonrpc': '2.0', 'id': m['id'], 'result': [None] * len(m['params'].get('items', []))})
                else: send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
                log('server request ' + meth + ' ' + (short(m['params'], 600) if meth in ('window/workDoneProgress/create', 'window/showMessageRequest') else ''))
            elif 'method' in m:
                meth = m['method']
                if meth == '$/progress':
                    v = m['params']['value']
                    log('progress %s %s %s' % (v.get('kind'), v.get('title', ''), v.get('message', '')))
                elif meth == 'textDocument/publishDiagnostics':
                    d = m['params']['diagnostics']
                    if state['first_diag'] is None: state['first_diag'] = now()
                    log('diagnostics n=%d version=%s %s' % (len(d), m['params'].get('version'), short([x['message'] for x in d][:3])))
                elif meth in ('window/logMessage', 'window/showMessage'):
                    msg = m['params']['message']
                    if 'swift build' in msg or 'prepare' in msg.lower(): log(meth + ' ' + short(msg, 900))
                    else: log(meth + ' ' + short(msg, 200))
                else: log('notification ' + meth)
            else:                                                  # a response
                if m['id'] == 1:
                    caps = m['result'].get('capabilities', {})
                    log('initialized; server=%s' % short(m['result'].get('serverInfo')))
                    notify('initialized', {})
                    notify('textDocument/didOpen', {'textDocument': {'uri': uri, 'languageId': lang, 'version': 1, 'text': text}})
                    state['init'] = state['opened'] = True
                elif m['id'] == state['pending']:
                    state['pending'] = None
                    if 'error' in m: log('completion error ' + short(m['error'], 120))
                    else:
                        r = m['result'] or {}
                        items = r.get('items', r) if isinstance(r, dict) else r
                        labels = [it.get('label', '') for it in items]
                        hit = [l for l in labels if expect in l]
                        log('completion %d items, incomplete=%s, hit=%s' % (len(items), r.get('isIncomplete') if isinstance(r, dict) else None, hit[:2]))
                        if hit: state['found'] = now()
        if state['opened'] and state['pending'] is None and time.time() - state['last_ask'] > 2:
            state['pending'] = request('textDocument/completion', {'textDocument': {'uri': uri}, 'position': pos})
            state['last_ask'] = time.time(); state['asked'] += 1
    # drain a little for late progress notifications after the first success
    t_end = time.time() + float(os.environ.get('DRAIN', '3'))
    while time.time() < t_end:
        try: m = inbox.get(timeout=0.5)
        except queue.Empty: continue
        if m and m.get('method') == '$/progress':
            v = m['params']['value']; log('progress %s %s %s' % (v.get('kind'), v.get('title', ''), v.get('message', '')))
        elif m and m.get('method') == 'textDocument/publishDiagnostics':
            d = m['params']['diagnostics']; log('diagnostics n=%d %s' % (len(d), short([x['message'] for x in d][:3])))
        elif m and m.get('method') == 'window/logMessage' and os.environ.get('LOGS'):
            log('logMessage ' + short(m['params']['message'], 140))
    print('RESULT found=%s first_diagnostics=%s asked=%d' % (state['found'], state['first_diag'], state['asked']))
    try:
        request('shutdown', None); time.sleep(0.5); notify('exit', None)
    except Exception: pass
    time.sleep(0.5)
    p.kill()

if __name__ == '__main__':
    main()
