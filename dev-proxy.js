// Single-origin dev proxy on :8000.
//   /api/* and /health -> Dart API (:8080)
//   everything else    -> static release build in $STATIC_DIR (default), or the
//                         Flutter debug dev server (:5080, incl. websockets) when WEB_MODE=debug.
const http = require('http'), net = require('net'), fs = require('fs'), path = require('path');
const PORT = +process.env.PROXY_PORT || 8000, API = +process.env.API_PORT || 8080, WEB = +process.env.WEB_PORT || 5080;
const STATIC = process.env.WEB_MODE === 'debug' ? null : (process.env.STATIC_DIR || path.join(__dirname, 'client/build/web-live'));
const isApi = u => u.startsWith('/api/') || u === '/api' || u.startsWith('/health');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.otf': 'font/otf', '.ttf': 'font/ttf', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.symbols': 'text/plain' };
function serveStatic(req, res) {
  const root = fs.realpathSync(STATIC); // resolve the symlink per request so rebuild swaps are atomic
  let rel = decodeURIComponent(req.url.split('?')[0]); if (rel.endsWith('/')) rel += 'index.html';
  let file = path.join(root, path.normalize(rel));
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html'); // SPA fallback
  const ext = path.extname(file);
  // index/bootstrap must never be cached so a rebuild shows up on reload; big assets are content-stable per build.
  const noCache = ['.html', '.json'].includes(ext) || /flutter(_bootstrap|_service_worker)?\.js$/.test(file) || file.endsWith('main.dart.js');
  res.writeHead(200, { 'content-type': TYPES[ext] || 'application/octet-stream', 'cache-control': noCache ? 'no-cache' : 'public, max-age=300', 'content-length': fs.statSync(file).size });
  fs.createReadStream(file).pipe(res);
}
const srv = http.createServer((req, res) => {
  if (STATIC && !isApi(req.url)) {
    try { return serveStatic(req, res); } catch (e) { res.writeHead(503, { 'content-type': 'text/plain' }); return res.end('web build not ready yet (' + e.code + ') — see tmux window "web"'); }
  }
  const up = http.request({ host: '127.0.0.1', port: isApi(req.url) ? API : WEB, method: req.method, path: req.url, headers: req.headers },
    r => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
  up.on('error', e => { res.writeHead(502); res.end('proxy: ' + e.message); });
  req.pipe(up);
});
srv.on('upgrade', (req, sock, head) => {
  const up = net.connect(isApi(req.url) ? API : WEB, '127.0.0.1', () => {
    up.write(`${req.method} ${req.url} HTTP/1.1\r\n` + Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') + '\r\n\r\n');
    up.write(head); up.pipe(sock); sock.pipe(up);
  });
  up.on('error', () => sock.destroy()); sock.on('error', () => up.destroy());
});
srv.listen(PORT, '0.0.0.0', () => console.log('dev proxy on :' + PORT + (STATIC ? ' (static ' + STATIC + ')' : ' (debug -> :' + WEB + ')')));
