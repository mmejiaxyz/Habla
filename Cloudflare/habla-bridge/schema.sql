-- Habla bridge ledger. The Worker never stores anything readable: ids are hashes,
-- names are HMACs made on the devices.
CREATE TABLE IF NOT EXISTS spaces (id TEXT PRIMARY KEY, created INTEGER NOT NULL);   -- id = sha256(token) hex
CREATE TABLE IF NOT EXISTS objects (
  space TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
  size INTEGER NOT NULL, etag TEXT NOT NULL, updated INTEGER NOT NULL,
  PRIMARY KEY (space, kind, name)
);
CREATE TABLE IF NOT EXISTS usage (period TEXT NOT NULL, metric TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (period, metric));
-- When each device last looked (name = its state object's name): "is it running?" without uploads.
CREATE TABLE IF NOT EXISTS seen (space TEXT NOT NULL, name TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (space, name));
-- One-time join codes (15 minutes): id = a PBKDF2/HKDF derivative of the code, wrapped = the
-- account key sealed with a key only the code makes.
CREATE TABLE IF NOT EXISTS codes (id TEXT PRIMARY KEY, space TEXT NOT NULL, wrapped TEXT NOT NULL, expires INTEGER NOT NULL);
DROP TABLE IF EXISTS invites;
-- The Xteink's login per account (KOReader sync sends md5(password); OPDS sends Basic auth).
CREATE TABLE IF NOT EXISTS ereaders (user TEXT PRIMARY KEY, space TEXT NOT NULL, key_md5 TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta (key, value) VALUES ('reserved_bytes', '0'), ('portfolio_bytes', '0'), ('last_cron', '');
