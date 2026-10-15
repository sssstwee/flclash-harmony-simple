CREATE TABLE subscription_push_rate_limit (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  minute INTEGER NOT NULL,
  count INTEGER NOT NULL
);
