'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const INDEX_VERSION = 1;
const DEFAULT_MAX_BYTES = 512 * 1024 * 1024;
const DEFAULT_MAX_BLOCK_BYTES = 12 * 1024 * 1024;
const DEFAULT_INDEX_PERSIST_DELAY_MS = 15 * 1000;
const DEFAULT_STATFS_CACHE_TTL_MS = 30 * 1000;
const MAX_ENTRY_AGE_MS = 30 * 24 * 60 * 60 * 1000;

function normalizeByteRange(value) {
  const match = String(value || '').match(/^bytes=(\d+)-(\d+)$/i);
  if (!match) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end < start) return null;
  return { header: `bytes=${start}-${end}`, start, end, length: end - start + 1 };
}

function hash(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

class MediaRangeCache {
  constructor({
    directory,
    maxBytes = DEFAULT_MAX_BYTES,
    maxBlockBytes = DEFAULT_MAX_BLOCK_BYTES,
    indexPersistDelayMs = DEFAULT_INDEX_PERSIST_DELAY_MS,
    statfsCacheTtlMs = DEFAULT_STATFS_CACHE_TTL_MS
  } = {}) {
    if (!directory) throw new Error('Media cache directory is required');
    this.directory = directory;
    this.indexFile = path.join(directory, 'index.json');
    this.maxBytes = maxBytes;
    this.lowWaterBytes = Math.floor(maxBytes * 0.8);
    this.maxBlockBytes = maxBlockBytes;
    this.indexPersistDelayMs = indexPersistDelayMs;
    this.statfsCacheTtlMs = statfsCacheTtlMs;
    this.entries = new Map();
    this.totalBytes = 0;
    this.hits = 0;
    this.misses = 0;
    this.initialized = false;
    this.writeQueue = Promise.resolve();
    this.indexDirty = false;
    this.indexPersistTimer = null;
    this.statfsCache = null;
    this.mutationGeneration = 0;
  }

  async init() {
    if (this.initialized) return;
    await fs.promises.mkdir(this.directory, { recursive: true, mode: 0o700 });
    let stored = null;
    try {
      stored = JSON.parse(await fs.promises.readFile(this.indexFile, 'utf8'));
    } catch (error) {}
    const sourceEntries = stored?.version === INDEX_VERSION && Array.isArray(stored.entries) ? stored.entries : [];
    const now = Date.now();
    const referenced = new Set();
    for (const value of sourceEntries) {
      if (!value || typeof value !== 'object' || !/^[a-f0-9]{64}\.bin$/.test(String(value.file || ''))) continue;
      if (now - Math.max(0, Number(value.lastAccessedAt) || 0) > MAX_ENTRY_AGE_MS) continue;
      const file = path.join(this.directory, value.file);
      try {
        const stat = await fs.promises.stat(file);
        if (!stat.isFile() || stat.size !== Number(value.size)) continue;
        const entry = {
          key: String(value.key || ''),
          assetKey: String(value.assetKey || ''),
          scope: String(value.scope || 'guest'),
          range: String(value.range || ''),
          file: value.file,
          size: stat.size,
          contentType: String(value.contentType || 'application/octet-stream'),
          contentRange: String(value.contentRange || ''),
          etag: String(value.etag || ''),
          lastAccessedAt: Math.max(0, Number(value.lastAccessedAt) || now),
          createdAt: Math.max(0, Number(value.createdAt) || now)
        };
        if (!entry.key || !normalizeByteRange(entry.range)) continue;
        this.entries.set(entry.key, entry);
        this.totalBytes += entry.size;
        referenced.add(entry.file);
      } catch (error) {}
    }
    for (const file of await fs.promises.readdir(this.directory)) {
      if (file === 'index.json' || referenced.has(file)) continue;
      if (/\.(?:bin|tmp)$/i.test(file)) await fs.promises.rm(path.join(this.directory, file), { force: true });
    }
    this.initialized = true;
    await this.prune();
    await this.persistIndex();
  }

  keyFor(assetKey, scope, range) {
    return hash(`${scope}\n${assetKey}\n${range}`);
  }

  currentGeneration() {
    return this.mutationGeneration;
  }

  async get(assetKey, scope, rangeHeader) {
    await this.init();
    const range = normalizeByteRange(rangeHeader);
    if (!range) return null;
    const key = this.keyFor(assetKey, scope, range.header);
    const entry = this.entries.get(key);
    if (!entry) {
      this.misses += 1;
      return null;
    }
    try {
      const stat = await fs.promises.stat(path.join(this.directory, entry.file));
      if (!stat.isFile() || stat.size !== entry.size) throw new Error('cache block mismatch');
      entry.lastAccessedAt = Date.now();
      this.hits += 1;
      this.scheduleIndexPersist();
      return { ...entry, path: path.join(this.directory, entry.file) };
    } catch (error) {
      this.entries.delete(key);
      this.totalBytes = Math.max(0, this.totalBytes - entry.size);
      this.misses += 1;
      await this.persistIndex();
      return null;
    }
  }

  async canStore(rangeHeader, contentLength) {
    const range = normalizeByteRange(rangeHeader);
    const length = Number(contentLength);
    if (!range || !Number.isFinite(length) || length <= 0 || length > this.maxBlockBytes || length !== range.length) return false;
    const now = Date.now();
    if (!this.statfsCache || this.statfsCache.expiresAt <= now) {
      this.statfsCache = {
        expiresAt: now + this.statfsCacheTtlMs,
        promise: this.readAvailableDiskSpace()
      };
    }
    return this.statfsCache.promise;
  }

  async readAvailableDiskSpace() {
    try {
      const stat = await fs.promises.statfs(this.directory);
      const freeBytes = Number(stat.bavail) * Number(stat.bsize);
      return !Number.isFinite(freeBytes) || freeBytes >= 1024 * 1024 * 1024;
    } catch (error) {
      return true;
    }
  }

  async put({ assetKey, scope, range: rangeHeader, buffer, contentType, contentRange, etag, expectedGeneration = null }) {
    await this.init();
    const generation = this.mutationGeneration;
    if (expectedGeneration !== null && expectedGeneration !== generation) return false;
    const range = normalizeByteRange(rangeHeader);
    if (!range || !Buffer.isBuffer(buffer) || buffer.length !== range.length || buffer.length > this.maxBlockBytes) return false;
    const key = this.keyFor(assetKey, scope, range.header);
    const file = `${key}.bin`;
    const target = path.join(this.directory, file);
    const temporary = `${target}.${process.pid}.${crypto.randomUUID()}.tmp`;
    await fs.promises.writeFile(temporary, buffer, { mode: 0o600 });
    if (this.mutationGeneration !== generation) {
      await fs.promises.rm(temporary, { force: true });
      return false;
    }
    await fs.promises.rename(temporary, target);
    if (this.mutationGeneration !== generation) {
      await fs.promises.rm(target, { force: true });
      return false;
    }
    const previous = this.entries.get(key);
    if (previous) this.totalBytes -= previous.size;
    const now = Date.now();
    this.entries.set(key, {
      key,
      assetKey: String(assetKey),
      scope: String(scope || 'guest'),
      range: range.header,
      file,
      size: buffer.length,
      contentType: String(contentType || 'application/octet-stream'),
      contentRange: String(contentRange || ''),
      etag: String(etag || ''),
      createdAt: previous?.createdAt || now,
      lastAccessedAt: now
    });
    this.totalBytes += buffer.length;
    await this.prune();
    await this.persistIndex();
    return true;
  }

  async prune() {
    if (this.totalBytes <= this.maxBytes) return;
    const candidates = [...this.entries.values()].sort((left, right) => left.lastAccessedAt - right.lastAccessedAt);
    for (const entry of candidates) {
      if (this.totalBytes <= this.lowWaterBytes) break;
      this.entries.delete(entry.key);
      this.totalBytes = Math.max(0, this.totalBytes - entry.size);
      await fs.promises.rm(path.join(this.directory, entry.file), { force: true });
    }
  }

  async clearScope(scopePrefix) {
    await this.init();
    this.mutationGeneration += 1;
    for (const entry of [...this.entries.values()]) {
      if (!entry.scope.startsWith(scopePrefix)) continue;
      this.entries.delete(entry.key);
      this.totalBytes = Math.max(0, this.totalBytes - entry.size);
      await fs.promises.rm(path.join(this.directory, entry.file), { force: true });
    }
    await this.persistIndex();
  }

  async clear() {
    await this.init();
    this.mutationGeneration += 1;
    for (const entry of this.entries.values()) {
      await fs.promises.rm(path.join(this.directory, entry.file), { force: true });
    }
    this.entries.clear();
    this.totalBytes = 0;
    await this.persistIndex();
  }

  stats() {
    const requests = this.hits + this.misses;
    return {
      version: INDEX_VERSION,
      entries: this.entries.size,
      storedBytes: this.totalBytes,
      maxBytes: this.maxBytes,
      hits: this.hits,
      misses: this.misses,
      hitRate: requests ? this.hits / requests : 0
    };
  }

  scheduleIndexPersist() {
    if (!this.initialized) return;
    this.indexDirty = true;
    if (this.indexPersistTimer) return;
    this.indexPersistTimer = setTimeout(() => {
      this.indexPersistTimer = null;
      if (!this.indexDirty) return;
      this.persistIndex().catch(() => {});
    }, this.indexPersistDelayMs);
    this.indexPersistTimer.unref?.();
  }

  cancelScheduledIndexPersist() {
    if (this.indexPersistTimer) clearTimeout(this.indexPersistTimer);
    this.indexPersistTimer = null;
    this.indexDirty = false;
  }

  persistIndex() {
    if (!this.initialized) return Promise.resolve();
    this.cancelScheduledIndexPersist();
    const snapshot = JSON.stringify({ version: INDEX_VERSION, entries: [...this.entries.values()] }, null, 2);
    this.writeQueue = this.writeQueue.catch(() => {}).then(() => this.writeIndexSnapshot(snapshot));
    return this.writeQueue;
  }

  async writeIndexSnapshot(snapshot) {
    const temporary = `${this.indexFile}.${process.pid}.tmp`;
    await fs.promises.writeFile(temporary, snapshot, { mode: 0o600 });
    await fs.promises.rename(temporary, this.indexFile);
  }
}

module.exports = {
  MediaRangeCache,
  normalizeByteRange
};
