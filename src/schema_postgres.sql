-- Esquema de la base de datos (PostgreSQL / RDS).
-- Se ejecuta aparte del pipeline (p. ej. desde PgAdmin o psql):
--   psql -h <rds_endpoint> -U pragma_admin -d pruebapragma -f schema_postgres.sql

-- Datos crudos de los CSV.
-- event_date se guarda como TEXT: el timestamp llega en formato M/D/YYYY y se
-- conserva tal cual; la normalizacion a DATE se deja a una capa posterior.
CREATE TABLE IF NOT EXISTS transactions (
    id         BIGSERIAL   PRIMARY KEY,
    event_date TEXT,
    price      INTEGER     NOT NULL,
    user_id    INTEGER,
    loaded_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_transactions_user_id
    ON transactions (user_id);

-- Estado incremental de las estadisticas de price. Fila unica (id = 1).
-- El pipeline la actualiza por delta; el promedio se deriva de sum_price/row_count.
CREATE TABLE IF NOT EXISTS running_stats (
    id         INTEGER PRIMARY KEY,
    row_count  BIGINT  NOT NULL DEFAULT 0,
    sum_price  BIGINT  NOT NULL DEFAULT 0,
    min_price  INTEGER,
    max_price  INTEGER,
    updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO running_stats (id, row_count, sum_price, min_price, max_price)
VALUES (1, 0, 0, NULL, NULL)
ON CONFLICT (id) DO NOTHING;

-- Consultas de comprobacion (deben coincidir entre si):
--
--   SELECT row_count,
--          CASE WHEN row_count > 0 THEN sum_price::numeric / row_count END AS avg_price,
--          min_price, max_price
--   FROM running_stats WHERE id = 1;
--
--   SELECT COUNT(*), AVG(price), MIN(price), MAX(price) FROM transactions;
