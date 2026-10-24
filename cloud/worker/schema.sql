CREATE TABLE IF NOT EXISTS auralis_records (key TEXT PRIMARY KEY, value TEXT NOT NULL, revision INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS auralis_revisions ON auralis_records(revision);
CREATE TABLE IF NOT EXISTS auralis_meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL CHECK(revision>=0));
INSERT OR IGNORE INTO auralis_meta VALUES(1,0);
