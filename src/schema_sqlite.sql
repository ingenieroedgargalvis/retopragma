-- Esquema para pruebas locales con SQLite. Equivalente al de PostgreSQL.
--   sqlite3 pipeline.db < schema_sqlite.sql

CREATE TABLE IF NOT EXISTS transactions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    event_date TEXT,
    price      INTEGER NOT NULL,
    user_id    INTEGER,
    loaded_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_transactions_user_id
    ON transactions (user_id);

-- Estado incremental de las estadisticas de price (fila unica id=1).
CREATE TABLE IF NOT EXISTS running_stats (
    id         INTEGER PRIMARY KEY,
    row_count  BIGINT  NOT NULL DEFAULT 0,
    sum_price  BIGINT  NOT NULL DEFAULT 0,
    min_price  INTEGER,
    max_price  INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO running_stats (id, row_count, sum_price, min_price, max_price)
VALUES (1, 0, 0, NULL, NULL);
