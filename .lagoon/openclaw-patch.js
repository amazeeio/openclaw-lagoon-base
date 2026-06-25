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

// 1. Patch fs.chmodSync
const origChmodSync = fs.chmodSync;
fs.chmodSync = function(p, mode) {
  try {
    return origChmodSync.call(this, p, mode);
  } catch (err) {
    if (shouldBypassError(err, p)) {
      console.warn(`[openclaw-patch] Bypassed fs.chmodSync error on ${p}: ${err.message}`);
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
      console.warn(`[openclaw-patch] Bypassed fs.chmod error on ${p}: ${err.message}`);
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
        console.warn(`[openclaw-patch] Bypassed fs.promises.chmod error on ${p}: ${err.message}`);
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
        console.warn(`[openclaw-patch] Bypassed fs/promises.chmod error on ${p}: ${err.message}`);
        return;
      }
      throw err;
    }
  };
}

console.log('[openclaw-patch] Global fs.chmod monkeypatch loaded successfully.');
