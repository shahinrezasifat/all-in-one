/// JavaScript host prelude injected into every provider QuickJS context
/// BEFORE the provider's own scraper code is evaluated.
///
/// It supplies the exact set of host globals the Zangetsu JS providers rely
/// on — `fetch`, `htmlText`, `absUrl`, `base64ToBytes`, `unpackJs` — plus a
/// tiny `atob`/`btoa`. It is intentionally dependency-free and ES5-flavoured
/// so QuickJS can run it.
///
/// `fetch` returns a REAL `Promise` (providers chain `.then` / `.catch` and
/// use `Promise.all`), but the HTTP itself is driven by Dart over the
/// `provFetch` message channel and completed asynchronously by the engine
/// service. When Dart finishes a request it calls back into
/// `__provResolve(id, <doubleJsonEncodedResponse>)` / `__provReject(id, msg)`.
const String kJsPrelude = r'''
'use strict';

// ── fetch bridge ────────────────────────────────────────────────────────────
var __provPending = {};
var __provId = 0;

function __makeResp(r) {
  var headers = (r && r.headers) || {};
  var body = (r && r.body != null) ? String(r.body) : '';
  var status = (r && r.status) | 0;
  function getH(n) {
    n = String(n).toLowerCase();
    for (var k in headers) { if (String(k).toLowerCase() === n) return headers[k]; }
    return null;
  }
  return {
    ok: status >= 200 && status < 300,
    status: status,
    statusText: (r && r.statusText) || '',
    url: (r && r.url) || '',
    body: body,
    headers: {
      get: getH,
      has: function (n) { return getH(n) != null; },
      keys: function () { var a = []; for (var k in headers) a.push(String(k).toLowerCase()); return a; }
    },
    text: function () { return body; },
    json: function () { return JSON.parse(body); }
  };
}

function __provResolve(id, jsonStr) {
  var p = __provPending[id]; if (!p) return;
  delete __provPending[id];
  var obj; try { obj = JSON.parse(jsonStr); } catch (e) { obj = { status: 0, body: '', headers: {} }; }
  p.resolve(__makeResp(obj));
}

function __provReject(id, msg) {
  var p = __provPending[id]; if (!p) return;
  delete __provPending[id];
  p.reject(new Error(String(msg || 'fetch failed')));
}

function fetch(url, options) {
  options = options || {};
  var id = ++__provId;
  var method = options.method || 'GET';
  var headers = options.headers || {};
  var body = (options.body == null) ? null : options.body;
  var p = new Promise(function (resolve, reject) {
    __provPending[id] = { resolve: resolve, reject: reject };
    try {
      sendMessage('provFetch', JSON.stringify([id, method, String(url), headers, body]));
    } catch (e) { delete __provPending[id]; reject(e); }
  });
  // Mark the base promise as handled. Provider scrapers routinely fire
  // optional/warm-up requests without attaching a rejection handler; those
  // timeouts used to surface as global "unhandled promise rejection" noise
  // even though the provider's main flow carried on. Callers that DO attach
  // .then/.catch still receive the rejection exactly as before.
  p.catch(function () {});
  return p;
}

// ── host helpers used by the providers ──────────────────────────────────────
function htmlText(html) {
  if (html == null) return '';
  var s = String(html)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ');
  var map = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', laquo: '«', raquo: '»', hellip: '…', rsquo: '’', lsquo: '‘', ldquo: '“', rdquo: '”', ndash: '–', mdash: '—' };
  s = s.replace(/&(#?\w+);/g, function (m0, ent) { var v = map[ent]; return v == null ? m0 : v; });
  s = s.replace(/&#(\d+);/g, function (m0, d) { return String.fromCharCode(parseInt(d, 10)); });
  s = s.replace(/&#x([0-9a-fA-F]+);/g, function (m0, h) { return String.fromCharCode(parseInt(h, 16)); });
  return s.replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
}

function absUrl(href, base) {
  href = String(href == null ? '' : href); base = String(base == null ? '' : base);
  if (!href) return href;
  href = href.replace(/^\s+|\s+$/g, '');
  if (/^data:/i.test(href) || /^(https?|ftp):/i.test(href)) return href;
  if (href.indexOf('//') === 0) { var pm = base.match(/^[a-zA-Z]+:/); return (pm ? pm[0] : 'https:') + href; }
  var origin = ''; var om = base.match(/^(https?:\/\/[^\/]+)/i); if (om) origin = om[1];
  if (href.charAt(0) === '/') return origin + href;
  if (href.indexOf('#') === 0) return base.split('#')[0] + href;
  if (href.indexOf('?') === 0) return base.split('?')[0] + href;
  var dir = base.replace(/[?#].*$/, '');
  dir = dir.substring(0, dir.lastIndexOf('/') + 1);
  return dir + href;
}

function base64ToBytes(str) {
  str = String(str == null ? '' : str).replace(/[^A-Za-z0-9+\/=]/g, '');
  var alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = [];
  for (var i = 0; i < str.length; i += 4) {
    var ch0 = str.charAt(i), ch1 = str.charAt(i + 1), ch2 = str.charAt(i + 2), ch3 = str.charAt(i + 3);
    if (ch0 === '' || ch1 === '') break;
    var c0 = alpha.indexOf(ch0), c1 = alpha.indexOf(ch1);
    var c2 = (ch2 === '' || ch2 === '=') ? 0 : alpha.indexOf(ch2);
    var c3 = (ch3 === '' || ch3 === '=') ? 0 : alpha.indexOf(ch3);
    if (c0 < 0) c0 = 0; if (c1 < 0) c1 = 0;
    var v = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    out.push((v >> 16) & 255);
    if (ch2 !== '' && ch2 !== '=') out.push((v >> 8) & 255);
    if (ch3 !== '' && ch3 !== '=') out.push(v & 255);
  }
  return out;
}

function atob(str) {
  var b = base64ToBytes(str), s = '';
  for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return s;
}

function btoa(str) {
  var alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var bytes = [], i;
  for (i = 0; i < String(str).length; i++) bytes.push(String(str).charCodeAt(i) & 255);
  var out = '';
  for (i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    out += alpha.charAt(b0 >> 2);
    out += alpha.charAt(((b0 & 3) << 4) | ((b1 == null ? 0 : b1) >> 4));
    out += (b1 == null) ? '=' : alpha.charAt(((b1 & 15) << 2) | ((b2 == null ? 0 : b2) >> 6));
    out += (b2 == null) ? '=' : alpha.charAt(b2 & 63);
  }
  return out;
}

// Dean-Edwards P.A.C.K.E.R unpacker (best-effort; callers guard with try/catch).
function unpackJs(source) {
  try {
    var m = source.match(/\}\s*\)\s*\(\s*(['"])((?:(?!\1)[\s\S])*)\1\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(['"])((?:(?!\5)[\s\S])*)\5/);
    if (!m) return source;
    var payload = m[2];
    var a = parseInt(m[3], 10);
    var c = parseInt(m[4], 10);
    var keywords = m[5].split('|');
    function enc(cc) { return (cc < a ? '' : enc(parseInt(cc / a, 10))) + ((cc = (cc % a)) > 35 ? String.fromCharCode(cc + 29) : cc.toString(36)); }
    payload = payload.replace(/\\x/g, '\\u00');
    payload = payload.replace(/\\u00([0-9a-fA-F]{2})/g, function (mm, hh) { return String.fromCharCode(parseInt(hh, 16)); });
    while (c--) { if (keywords[c]) { payload = payload.replace(new RegExp('\\b' + enc(c) + '\\b', 'g'), keywords[c]); } }
    return payload;
  } catch (err) { return source; }
}
''';
