// v2worker.js -- background build engine.
//
// The page prepends the engine bundle plus `var window = self;`, so the UMD
// header finds a global object and the Lua state lives off the main thread.
// The engine is wasmoon (Lua 5.4 compiled to wasm); the wasm image is embedded
// by the page and mounted from a blob URL, so no network is needed. Module
// sources and the driver arrive once; the Lua state is then reused for every
// action, so a large build never blocks the UI and never re-parses the module
// map.
'use strict';

var ENGINE = {
  lua: null,
  modules: null,
  driver: '',
  ready: false,
  booting: false
};

function b64Bytes(text) {
  var bin = atob(text);
  var bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function decodeB64(text) {
  return new TextDecoder('utf-8').decode(b64Bytes(text));
}

function luaLongString(text) {
  var level = 0;
  for (;;) {
    var eq = new Array(level + 1).join('=');
    var close = ']' + eq + ']';
    var tail = ']' + eq;
    // A trailing "]"/"]=.." in the text fuses with the closing bracket and
    // ends the long string early (stray "]" -> parse error). Bump the level.
    if (text.indexOf(close) < 0 && text.slice(-tail.length) !== tail) {
      return '[' + eq + '[' + text + close;
    }
    level++;
  }
}

// Same require shim as the native runner, but with global tables so the cache
// survives between messages.
function prefixChunk() {
  var chunk = [
    '__M = {}',
    '__C = {}',
    'local __real = require',
    'function require(n)',
    '  local v = __C[n]',
    '  if v ~= nil then return v end',
    '  local s = __M[n]',
    '  if not s then return __real(n) end',
    '  local fn, err = load(s, "@" .. n)',
    '  if not fn then error(err, 0) end',
    '  v = fn()',
    '  if v == nil then v = true end',
    '  __C[n] = v',
    '  return v',
    'end'
  ];
  Object.keys(ENGINE.modules).forEach(function (name) {
    chunk.push('__M[' + JSON.stringify(name) + '] = ' +
      luaLongString(ENGINE.modules[name]));
  });
  return chunk.join('\n');
}

function actionChunk(action, opts) {
  var chunk = [
    '__ACTION = ' + JSON.stringify(action),
    '__SRC = ' + luaLongString(opts.source || ''),
    '__CODE = ' + luaLongString(opts.code || ''),
    '__PRESET = ' + JSON.stringify(opts.preset || 'strong'),
    '__SEED = ' + (opts.seed === null || opts.seed === undefined ? -1 : opts.seed),
    '__MAXSTEPS = ' + (opts.maxSteps || 400000000),
    '__SECONDS = ' + (opts.seconds || 12),
    '__STEPCHUNK = ' + (opts.stepChunk || 250000)
  ];
  if (opts.engine) chunk.push('__ENGINE = ' + JSON.stringify(opts.engine));
  if (opts.rules) {
    chunk.push('__FLATTEN = ' + (opts.rules.flatten ? 1 : 0));
    chunk.push('__OPAQUE = ' + (opts.rules.opaque ? 1 : 0));
    chunk.push('__SELFMOD = ' + (opts.rules.selfmod ? 1 : 0));
    chunk.push('__ANTIDEBUG = ' + (opts.rules.antidebug ? 1 : 0));
    chunk.push('__INTEGRITY = ' + (opts.rules.integrity ? 1 : 0));
    chunk.push('__EXECUTOR = ' + (opts.rules.executor ? 1 : 0));
    chunk.push('__GETHUI = ' + (opts.rules.gethui ? 1 : 0));
    chunk.push('__ANTIWEBHOOK = ' + (opts.rules.antiwebhook ? 1 : 0));
  }
  chunk.push(ENGINE.driver);
  return chunk.join('\n');
}

function runChunk(chunk) {
  var out = ENGINE.lua.doStringSync(chunk);
  return out === undefined || out === null ? '' : String(out);
}

// Build pieces arrive here one at a time, so the worker never accumulates the
// finished artifact; the page turns them into a blob.
function bindHost() {
  ENGINE.lua.global.set('__PUSH', function (part) {
    self.postMessage({ type: 'part', data: String(part) });
    return 0;
  });
  ENGINE.lua.global.set('__STEP', function (index, total) {
    self.postMessage({
      type: 'step', index: Number(index) || 0, total: Number(total) || 0
    });
    return 0;
  });
}

async function boot() {
  if (ENGINE.booting || ENGINE.ready) return;
  ENGINE.booting = true;
  var wasm = b64Bytes(ENGINE_WASM_B64);
  var url = URL.createObjectURL(new Blob([wasm], { type: 'application/wasm' }));
  var factory = new wasmoon.LuaFactory(url);
  ENGINE.lua = await factory.createEngine();
  bindHost();
  runChunk(prefixChunk());
  ENGINE.ready = true;
  self.postMessage({ type: 'ready' });
}

self.onmessage = function (event) {
  var msg = event.data || {};
  if (msg.type === 'init') {
    try {
      ENGINE.modules = {};
      Object.keys(msg.modules || {}).forEach(function (name) {
        ENGINE.modules[name] = decodeB64(msg.modules[name]);
      });
      ENGINE.driver = decodeB64(msg.driver || '');
      if (!self.wasmoon || typeof self.wasmoon.LuaFactory !== 'function') {
        throw new Error('Lua motoru yuklenemedi');
      }
      boot().catch(function (err) {
        self.postMessage({
          type: 'fatal',
          error: String(err && err.message || err)
        });
      });
    } catch (err) {
      self.postMessage({
        type: 'fatal',
        error: String(err && err.message || err)
      });
    }
    return;
  }

  if (msg.type === 'call') {
    if (!ENGINE.ready) {
      self.postMessage({ id: msg.id, ok: false, error: 'motor hazır değil' });
      return;
    }
    try {
      var raw = runChunk(actionChunk(msg.action, msg.opts || {}));
      try { ENGINE.lua.doStringSync('collectgarbage("collect")'); }
      catch (collectErr) { /* best effort */ }
      self.postMessage({ id: msg.id, ok: true, raw: raw });
    } catch (err) {
      // A Lua error can leave the VM usable; report it and let the caller
      // decide. Only a worker-level failure is fatal.
      try { ENGINE.lua.doStringSync('collectgarbage("collect")'); }
      catch (collectErr) { /* ignore */ }
      self.postMessage({
        id: msg.id,
        ok: false,
        error: String(err && err.message || err)
      });
    }
  }
};
