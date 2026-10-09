/* 工作台原型静态服务 + Mole CLI 桥
 * /api/mole → spawn Mole/bin/status-go --json(2.5s 缓存 + 请求合并) */
const http = require('http'), fs = require('fs'), path = require('path');
const { spawn } = require('child_process');
const root = '/Users/chenhong/github/personal-workbench/design';
const MOLE = '/Users/chenhong/github/Mole/bin/status-go';
const types = {'.html':'text/html','.css':'text/css','.js':'text/js','.png':'image/png','.svg':'image/svg+xml'};

let cache = null, cacheAt = 0, waiters = null;
function moleJSON(cb){
  const now = Date.now();
  if (cache && now - cacheAt < 2500) return cb(null, cache);
  if (waiters) return waiters.push(cb);
  waiters = [cb];
  const p = spawn(MOLE, ['--json']);
  let out = '', err = '';
  p.stdout.on('data', d => out += d);
  p.stderr.on('data', d => err += d);
  p.on('error', e => finish(e, null));
  p.on('close', code => {
    if (code !== 0) return finish(new Error(err || 'status-go exit ' + code), null);
    try { const d = JSON.parse(out); finish(null, d); }
    catch (e) { finish(e, null); }
  });
  function finish(e, d){
    if (!e) { cache = d; cacheAt = Date.now(); }
    const ws = waiters; waiters = null;
    ws.forEach(w => w(e, d));
  }
}

http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/api/mole'){
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    moleJSON((e, d) => {
      if (e){ res.writeHead(500); res.end(JSON.stringify({ error: String(e.message || e) })); return; }
      res.writeHead(200); res.end(JSON.stringify(d));
    });
    return;
  }
  const p = path.join(root, url === '/' ? '/index.html' : url);
  fs.readFile(p, (e, d) => {
    if (e){ res.writeHead(404); res.end('nf'); return; }
    res.writeHead(200, {'Content-Type': types[path.extname(p)] || 'application/octet-stream', 'Cache-Control': 'no-store'});
    res.end(d);
  });
}).listen(8791, '127.0.0.1', () => console.log('workbench serving :8791 (+/api/mole)'));
