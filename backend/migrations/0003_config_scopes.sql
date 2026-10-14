CREATE TABLE proxy_config_scoped (
  scope TEXT NOT NULL CHECK (scope IN ('default', 'user', 'group')),
  scope_key TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (scope, scope_key)
);

INSERT INTO proxy_config_scoped (scope, scope_key, content, updated_at)
SELECT 'default', '', content, updated_at FROM proxy_config WHERE id = 1;

DROP TABLE proxy_config;

ALTER TABLE proxy_config_scoped RENAME TO proxy_config;

ALTER TABLE user ADD COLUMN config_group TEXT;

CREATE TABLE config_fetch_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  scope TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  client_ip TEXT
);

CREATE INDEX config_fetch_audit_user_idx ON config_fetch_audit (user_id, fetched_at);

CREATE TABLE config_api_rate_limit (
  user_id TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  request_count INTEGER NOT NULL
);
