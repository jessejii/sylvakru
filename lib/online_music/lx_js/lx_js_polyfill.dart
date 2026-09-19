// 注入到 QuickJS 的最小运行时：DOM 无关的 polyfill + lx-music 的 `window.lx` 契约。
//
// 对应 lx-music 的 preload.js
// (`src/main/modules/userApi/renderer/preload.js`)：用户脚本只认 `globalThis.lx`，
// 所以这里把那一份 API 面原样搬过来，脚本零改动。
//
// 两条单向通道（flutter_js 的限制决定的）：
//   * JS -> Dart：`sendMessage('lx_bridge', json)`。它在 QuickJS 里是同步的，
//     并且会把 Dart 回调的返回值传回 JS —— crypto/zlib/buffer 这类同步 API 靠它。
//   * Dart -> JS：`evaluate("__lx_xxx('<base64>')")`。请求分发、HTTP 回调用它。
//
// 过桥数据一律是 base64(utf8(json))：既绕开引号/转义，也绕开 flutter_js 把
// `Uint8Array` 当普通对象转成 Map 的坑（二进制统一用 base64）。

/// 注入脚本。先 evaluate 它，再 evaluate 用户脚本。
const String lxJsPolyfill = r'''
(function () {
  var g = typeof globalThis !== 'undefined' ? globalThis : this;
  if (!g.window) g.window = g;
  if (!g.self) g.self = g;
  if (typeof g.addEventListener !== 'function') g.addEventListener = function () {};

  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function bytesToB64(b) {
    var out = '', i, c1, c2, c3;
    for (i = 0; i < b.length; i += 3) {
      c1 = b[i]; c2 = b[i + 1]; c3 = b[i + 2];
      out += B64C.charAt(c1 >> 2);
      out += B64C.charAt(((c1 & 3) << 4) | (c2 === undefined ? 0 : c2 >> 4));
      out += c2 === undefined ? '=' : B64C.charAt(((c2 & 15) << 2) | (c3 === undefined ? 0 : c3 >> 6));
      out += c3 === undefined ? '=' : B64C.charAt(c3 & 63);
    }
    return out;
  }

  function b64ToBytes(s) {
    s = String(s).replace(/[^A-Za-z0-9+/]/g, '');
    var out = new Uint8Array((s.length * 3) >> 2), p = 0, i, n, c1, c2, c3, c4;
    for (i = 0; i < s.length; i += 4) {
      c1 = B64C.indexOf(s.charAt(i)); c2 = B64C.indexOf(s.charAt(i + 1));
      c3 = B64C.indexOf(s.charAt(i + 2)); c4 = B64C.indexOf(s.charAt(i + 3));
      n = (c1 << 18) | (c2 << 12) | ((c3 < 0 ? 0 : c3) << 6) | (c4 < 0 ? 0 : c4);
      if (p < out.length) out[p++] = (n >> 16) & 255;
      if (c3 >= 0 && p < out.length) out[p++] = (n >> 8) & 255;
      if (c4 >= 0 && p < out.length) out[p++] = n & 255;
    }
    return out;
  }

  function utf8ToBytes(s) {
    s = String(s);
    var out = [], i, c;
    for (i = 0; i < s.length; i++) {
      c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
        var c2 = s.charCodeAt(i + 1); i++;
        var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  function bytesToUtf8(b) {
    var out = '', i = 0, c;
    while (i < b.length) {
      c = b[i++];
      if (c < 0x80) out += String.fromCharCode(c);
      else if (c < 0xe0) out += String.fromCharCode(((c & 31) << 6) | (b[i++] & 63));
      else if (c < 0xf0) out += String.fromCharCode(((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63));
      else {
        var cp = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
      }
    }
    return out;
  }

  if (typeof g.atob !== 'function') {
    g.atob = function (s) {
      var b = b64ToBytes(s), o = '', i;
      for (i = 0; i < b.length; i++) o += String.fromCharCode(b[i]);
      return o;
    };
  }
  if (typeof g.btoa !== 'function') {
    g.btoa = function (s) {
      var b = new Uint8Array(s.length), i;
      for (i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 255;
      return bytesToB64(b);
    };
  }

  // ---- Buffer（够用即可：脚本只用到 from/alloc/concat/toString）----
  function toBytes(v, enc) {
    if (v == null) return new Uint8Array(0);
    if (v instanceof Uint8Array) return v;
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (v.__lx_b) return b64ToBytes(v.__lx_b);
    if (typeof v === 'string') {
      var e = String(enc || 'utf8').toLowerCase(), o, i, n;
      if (e === 'hex') {
        n = v.length >> 1; o = new Uint8Array(n);
        for (i = 0; i < n; i++) o[i] = parseInt(v.substr(i * 2, 2), 16) || 0;
        return o;
      }
      if (e === 'base64') return b64ToBytes(v);
      if (e === 'binary' || e === 'latin1' || e === 'ascii') {
        o = new Uint8Array(v.length);
        for (i = 0; i < v.length; i++) o[i] = v.charCodeAt(i) & 255;
        return o;
      }
      return utf8ToBytes(v);
    }
    if (typeof v.length === 'number') {
      o = new Uint8Array(v.length);
      for (i = 0; i < v.length; i++) o[i] = v[i] & 255;
      return o;
    }
    return new Uint8Array(0);
  }

  function bufToString(b, fmt) {
    var e = String(fmt || 'utf8').toLowerCase(), s = '', o = '', i, h;
    if (e === 'hex') {
      for (i = 0; i < b.length; i++) { h = b[i].toString(16); s += h.length < 2 ? '0' + h : h; }
      return s;
    }
    if (e === 'base64') return bytesToB64(b);
    if (e === 'binary' || e === 'latin1' || e === 'ascii') {
      for (i = 0; i < b.length; i++) o += String.fromCharCode(b[i]);
      return o;
    }
    return bytesToUtf8(b);
  }

  // ponytail: 用带 toString(enc) 的 Uint8Array 冒充 Buffer，不实现完整 Buffer API。
  function makeBuf(v, enc) {
    var b = new Uint8Array(toBytes(v, enc));
    Object.defineProperty(b, 'toString', { value: function (f) { return bufToString(b, f); } });
    Object.defineProperty(b, 'toJSON', { value: function () { return { type: 'Buffer', data: Array.prototype.slice.call(b) }; } });
    return b;
  }

  function LXBuffer(v, enc) { return makeBuf(v, enc); }
  LXBuffer.from = function (v, enc) { return makeBuf(v, enc); };
  LXBuffer.alloc = function (n, f) {
    var b = new Uint8Array(n | 0);
    if (f) b.fill(f & 255);
    return makeBuf(b);
  };
  LXBuffer.concat = function (list) {
    var n = 0, i, p = 0, t, b;
    for (i = 0; i < list.length; i++) n += toBytes(list[i]).length;
    b = new Uint8Array(n);
    for (i = 0; i < list.length; i++) { t = toBytes(list[i]); b.set(t, p); p += t.length; }
    return makeBuf(b);
  };
  LXBuffer.isBuffer = function (v) { return v instanceof Uint8Array; };
  g.Buffer = LXBuffer;

  function bytesArg(v) { return { __lx_b: bytesToB64(toBytes(v)) }; }
  function b64Json(v) { return bytesToB64(utf8ToBytes(JSON.stringify(v))); }

  // ---- 桥 ----
  function callDart(payload) { return g.sendMessage('lx_bridge', JSON.stringify(payload)); }

  function fromResult(r) {
    if (!r) throw new Error('lx bridge: empty result');
    if (r.ok === false) throw new Error(r.error || 'lx bridge error');
    return r;
  }

  var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };
  var handlers = {};
  var httpSeq = 0;
  var httpCb = {};

  var lx = {
    EVENT_NAMES: EVENT_NAMES,
    version: '2.0.0',
    env: 'desktop',
    currentScriptInfo: { name: '', description: '', version: '1.0', author: '', homepage: '', rawScript: '' },

    request: function (url, options, callback) {
      options = options || {};
      var id = ++httpSeq;
      if (typeof callback === 'function') httpCb[id] = callback;
      callDart({
        t: 'http',
        id: id,
        url: String(url),
        method: options.method || 'GET',
        timeout: options.timeout,
        headers: options.headers || null,
        body: encBody(options.body),
        form: encBody(options.form),
        formData: encBody(options.formData)
      });
      // 对应宿主返回的 abort 函数。
      return function () { callDart({ t: 'abort', id: id }); };
    },

    send: function (name, data) {
      return new Promise(function (resolve, reject) {
        var r = callDart({ t: 'send', name: name, data: data });
        if (r && r.ok === false) reject(new Error(r.error || 'send failed'));
        else resolve();
      });
    },

    on: function (name, handler) {
      return new Promise(function (resolve, reject) {
        var r = callDart({ t: 'on', name: name });
        if (r && r.ok === false) { reject(new Error(r.error || 'on failed')); return; }
        handlers[name] = handler;
        resolve();
      });
    },

    utils: {
      crypto: {
        aesEncrypt: function (buffer, mode, key, iv) {
          var r = fromResult(callDart({
            t: 'util', fn: 'aesEncrypt',
            args: [bytesArg(buffer), String(mode), bytesArg(key), iv == null ? null : bytesArg(iv)]
          }));
          return makeBuf(b64ToBytes(r.b64));
        },
        rsaEncrypt: function (buffer, key) {
          var k = (key instanceof Uint8Array || (key && key.buffer)) ? bufToString(toBytes(key)) : String(key);
          var r = fromResult(callDart({ t: 'util', fn: 'rsaEncrypt', args: [bytesArg(buffer), k] }));
          return makeBuf(b64ToBytes(r.b64));
        },
        randomBytes: function (size) {
          var r = fromResult(callDart({ t: 'util', fn: 'randomBytes', args: [size | 0] }));
          return makeBuf(b64ToBytes(r.b64));
        },
        md5: function (str) {
          var a = (str instanceof Uint8Array) ? bytesArg(str) : String(str);
          return fromResult(callDart({ t: 'util', fn: 'md5', args: [a] })).hex;
        }
      },
      buffer: {
        from: function (v, enc) { return makeBuf(v, enc); },
        bufToString: function (buf, fmt) { return bufToString(toBytes(buf), fmt); }
      },
      zlib: {
        inflate: function (buf) {
          var r = fromResult(callDart({ t: 'util', fn: 'inflate', args: [bytesArg(buf)] }));
          return Promise.resolve(makeBuf(b64ToBytes(r.b64)));
        },
        deflate: function (buf) {
          var r = fromResult(callDart({ t: 'util', fn: 'deflate', args: [bytesArg(buf)] }));
          return Promise.resolve(makeBuf(b64ToBytes(r.b64)));
        }
      }
    }
  };

  function encBody(v) {
    if (v instanceof Uint8Array || (v && v.buffer instanceof ArrayBuffer)) return bytesArg(v);
    if (typeof v === 'string') return v;
    return v == null ? null : v;
  }

  g.lx = lx;

  // Dart -> JS：一次取链请求。
  g.__lx_dispatch = function (b64) {
    var msg = JSON.parse(bytesToUtf8(b64ToBytes(b64)));
    var key = msg.requestKey;
    var handler = handlers.request;
    if (!handler) {
      callDart({ t: 'resp', requestKey: key, error: 'Request event is not defined' });
      return;
    }
    Promise.resolve().then(function () {
      return handler({ source: msg.data.source, action: msg.data.action, info: msg.data.info });
    }).then(function (result) {
      callDart({ t: 'resp', requestKey: key, result: result });
    }).catch(function (e) {
      callDart({ t: 'resp', requestKey: key, error: (e && e.message) || String(e) });
    });
  };

  // Dart -> JS：lx.request 的回调。
  g.__lx_httpDone = function (b64) {
    var m = JSON.parse(bytesToUtf8(b64ToBytes(b64)));
    var cb = httpCb[m.id];
    if (!cb) return;
    delete httpCb[m.id];
    if (m.err) { cb(new Error(m.err), null, null); return; }
    var r = m.resp;
    r.raw = makeBuf(b64ToBytes(r.rawB64));
    delete r.rawB64;
    cb(null, r, r.body);
  };

  g.__lx_setScriptInfo = function (b64) {
    lx.currentScriptInfo = JSON.parse(bytesToUtf8(b64ToBytes(b64)));
  };

  g.__lx_b64Json = b64Json;
  g.__lx_ready = true;
})();
''';
