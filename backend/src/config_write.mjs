// Shared by the Worker (bound parameters) and the administrative SQL importer.
export function configUpsertSql(values) {
  return `INSERT INTO proxy_config (scope,scope_key,content,updated_at) VALUES (${values.join(',')}) ON CONFLICT(scope,scope_key) DO UPDATE SET content=excluded.content,updated_at=excluded.updated_at WHERE proxy_config.content != excluded.content;`;
}
