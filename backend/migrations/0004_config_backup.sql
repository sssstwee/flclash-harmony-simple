CREATE TABLE proxy_config_backup (
  scope TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  content TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (scope, scope_key)
);

-- The backup and replacement commit together, including administrative writes.
CREATE TRIGGER proxy_config_save_previous
BEFORE UPDATE OF content ON proxy_config
WHEN OLD.content != NEW.content
BEGIN
  INSERT INTO proxy_config_backup (scope, scope_key, content, updated_at)
  VALUES (OLD.scope, OLD.scope_key, OLD.content, OLD.updated_at)
  ON CONFLICT(scope, scope_key) DO UPDATE SET
    content = excluded.content, updated_at = excluded.updated_at;
END;
