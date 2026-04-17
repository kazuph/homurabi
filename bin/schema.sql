-- homurabi D1 schema (LOCAL DEVELOPMENT ONLY)
--
-- Mirrors the structure used by app/hello.rb routes. Idempotent —
-- safe to re-run; existing rows are preserved.
--
-- Usage (local Wrangler SQLite only):
--   npm run d1:init          (or:  bin/init-local-d1)
--
-- This file is NOT intended to be applied to the remote production
-- D1 database. Production schema/seed is managed manually by the
-- repository owner. Do not run with `--remote` unless you know what
-- you are doing.

CREATE TABLE IF NOT EXISTS users (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT    NOT NULL
);

INSERT OR IGNORE INTO users (id, name) VALUES
  (1, 'Kazu'),
  (2, 'Homurabi-chan'),
  (3, 'Sinatra'),
  (4, 'Opal');

-- Phase 9 — Cron Trigger heartbeat demo. Each firing of the
-- `*/5 * * * *` cron writes one row here. Verify the cron is
-- actually wired by tailing this table in dev:
--
--   wrangler d1 execute homurabi-db --local \
--     --command "SELECT * FROM heartbeats ORDER BY id DESC LIMIT 5;"
--
CREATE TABLE IF NOT EXISTS heartbeats (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  cron         TEXT    NOT NULL,
  scheduled_at INTEGER NOT NULL,
  fired_at     INTEGER NOT NULL,
  note         TEXT
);
