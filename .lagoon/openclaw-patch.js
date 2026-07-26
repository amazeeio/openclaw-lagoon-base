const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

const targetStateDir = '/home/.openclaw';

function shouldBypassError(err, p) {
  if (!err) return false;
  // Catch permission limitations on container NFS/EFS/networked filesystems
  const bypassCodes = ['EPERM', 'ENOTSUP', 'ENOSYS', 'EACCES'];
  if (!bypassCodes.includes(err.code)) {
    return false;
  }
  if (!p) return true;
  const absPath = path.resolve(String(p));
  return absPath.startsWith(targetStateDir);
}

// The bypasses are expected in this containerized setup (the state dir mount cannot
// be chmodded by uid 10000); warn once per operation+path instead of flooding the
// gateway logs on every boot and doctor run.
const warnedBypasses = new Set();
function warnBypassOnce(op, p, err) {
  const key = op + ':' + String(p);
  if (warnedBypasses.has(key)) return;
  warnedBypasses.add(key);
  console.warn(`[openclaw-patch] Bypassed ${op} error on ${p}: ${err.message} (suppressing repeats)`);
}

// 1. Patch fs.chmodSync
const origChmodSync = fs.chmodSync;
fs.chmodSync = function(p, mode) {
  try {
    return origChmodSync.call(this, p, mode);
  } catch (err) {
    if (shouldBypassError(err, p)) {
      warnBypassOnce("fs.chmodSync", p, err);
      return;
    }
    throw err;
  }
};

// 2. Patch fs.chmod
const origChmod = fs.chmod;
fs.chmod = function(p, mode, callback) {
  if (typeof callback !== 'function') {
    return origChmod.call(this, p, mode, callback);
  }
  return origChmod.call(this, p, mode, function(err, ...args) {
    if (err && shouldBypassError(err, p)) {
      warnBypassOnce("fs.chmod", p, err);
      return callback(null, ...args);
    }
    return callback(err, ...args);
  });
};

// 3. Patch fs.promises.chmod
const origPromisesChmod = fs.promises ? fs.promises.chmod : null;
if (origPromisesChmod) {
  fs.promises.chmod = async function(p, mode) {
    try {
      return await origPromisesChmod.call(this, p, mode);
    } catch (err) {
      if (shouldBypassError(err, p)) {
        warnBypassOnce("fs.promises.chmod", p, err);
        return;
      }
      throw err;
    }
  };
}

// 4. Patch fs/promises directly
const origFspChmod = fsp.chmod;
if (origFspChmod) {
  fsp.chmod = async function(p, mode) {
    try {
      return await origFspChmod.call(this, p, mode);
    } catch (err) {
      if (shouldBypassError(err, p)) {
        warnBypassOnce("fs/promises.chmod", p, err);
        return;
      }
      throw err;
    }
  };
}

// Never write to stdout: NODE_OPTIONS=--require runs this on every node
// invocation, so a stdout line leaks into command output (e.g. the gateway
// token read in 50-shell-config.sh, which only redirects stderr). Log to
// stderr, and only when explicitly debugging.
if (process.env.OPENCLAW_PATCH_DEBUG) {
  console.error('[openclaw-patch] Global fs.chmod monkeypatch loaded successfully.');
}
