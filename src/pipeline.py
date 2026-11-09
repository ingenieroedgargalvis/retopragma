"""
Pipeline de ingesta por micro-batches.

Carga los CSV 2012-*.csv (y luego validation.csv) a una base de datos,
procesando un archivo a la vez y leyendo cada archivo fila a fila para no
cargarlo completo en memoria. Las estadisticas de price (count, avg, min, max)
se mantienen con acumuladores incrementales en lugar de recalcularse desde la
tabla.

Soporta SQLite (pruebas locales) y PostgreSQL (--backend).
"""

import os
import csv
import time
import argparse


class RunningStats:
    """Acumulador incremental de las estadisticas de price.

    Guarda count, total (suma), min y max. El promedio se deriva como
    total/count, asi no hay que recorrer de nuevo los datos ya cargados.
    """

    def __init__(self, count=0, total=0, minv=None, maxv=None):
        # Los valores iniciales permiten reanudar desde un estado previo
        # guardado en la BD, no solo arrancar desde cero.
        self.count = count
        self.total = total
        self.minv = minv
        self.maxv = maxv

    def update(self, price):
        self.count += 1
        self.total += price
        if self.minv is None or price < self.minv:
            self.minv = price
        if self.maxv is None or price > self.maxv:
            self.maxv = price

    @property
    def avg(self):
        if self.count == 0:
            return None
        return self.total / self.count

    def as_dict(self):
        return {
            "count": self.count,
            "avg": self.avg,
            "min": self.minv,
            "max": self.maxv,
        }

    def __str__(self):
        avg = f"{self.avg:.4f}" if self.avg is not None else "N/A"
        return (f"count={self.count} | avg={avg} | "
                f"min={self.minv} | max={self.maxv}")


class Database:
    """Capa de acceso a datos. Aisla el pipeline del motor concreto."""

    def __init__(self, backend="sqlite", **kwargs):
        self.backend = backend
        self.kwargs = kwargs
        self.conn = None
        # Placeholder de parametros segun el driver: sqlite usa ?, psycopg2 %s.
        self.ph = "?" if backend == "sqlite" else "%s"

    def connect(self):
        if self.backend == "sqlite":
            import sqlite3
            db_path = self.kwargs.get("db_path", "pipeline.db")
            self.conn = sqlite3.connect(db_path)
        elif self.backend == "postgres":
            import psycopg2
            self.conn = psycopg2.connect(
                host=self.kwargs["host"],
                port=self.kwargs.get("port", 5432),
                dbname=self.kwargs["dbname"],
                user=self.kwargs["user"],
                password=self.kwargs["password"],
            )
        else:
            raise ValueError(f"Backend no soportado: {self.backend}")
        return self

    def init_schema(self):
        """Ejecuta el DDL externo (schema_*.sql). Solo con --init-schema."""
        archivo_ddl = ("schema_sqlite.sql"
                       if self.backend == "sqlite" else "schema_postgres.sql")
        ruta_ddl = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                archivo_ddl)

        with open(ruta_ddl, "r", encoding="utf-8") as fh:
            ddl = fh.read()

        cur = self.conn.cursor()
        if self.backend == "sqlite":
            cur.executescript(ddl)
        else:
            cur.execute(ddl)
        self.conn.commit()
        print(f"Esquema inicializado desde {archivo_ddl}.")

    def insert_batch(self, rows):
        if not rows:
            return
        sql = (f"INSERT INTO transactions (event_date, price, user_id) "
               f"VALUES ({self.ph}, {self.ph}, {self.ph})")
        cur = self.conn.cursor()
        cur.executemany(sql, rows)

    def save_stats(self, stats):
        sql = (f"UPDATE running_stats SET row_count={self.ph}, sum_price={self.ph}, "
               f"min_price={self.ph}, max_price={self.ph} WHERE id=1")
        cur = self.conn.cursor()
        cur.execute(sql, (stats.count, stats.total, stats.minv, stats.maxv))
        self.conn.commit()

    def load_stats(self):
        """Reconstruye el acumulador desde running_stats para reanudar."""
        cur = self.conn.cursor()
        cur.execute("SELECT row_count, sum_price, min_price, max_price "
                    "FROM running_stats WHERE id=1")
        fila = cur.fetchone()
        if fila is None:
            return RunningStats()
        row_count, sum_price, min_price, max_price = fila
        return RunningStats(
            count=row_count or 0,
            total=sum_price or 0,
            minv=min_price,
            maxv=max_price,
        )

    def query_db_stats(self):
        """Recalcula las stats desde la tabla, para contrastar contra el acumulador."""
        cur = self.conn.cursor()
        cur.execute("SELECT COUNT(*), AVG(price), MIN(price), MAX(price) "
                    "FROM transactions")
        count, avg, minv, maxv = cur.fetchone()
        return {
            "count": count,
            "avg": float(avg) if avg is not None else None,
            "min": minv,
            "max": maxv,
        }

    def close(self):
        if self.conn:
            self.conn.close()


def discover_batch_files(data_dir):
    """Devuelve los 2012-*.csv ordenados por nombre (orden cronologico)."""
    archivos = [
        f for f in os.listdir(data_dir)
        if f.startswith("2012-") and f.endswith(".csv")
    ]
    archivos.sort()
    return [os.path.join(data_dir, f) for f in archivos]


def process_file(path, db, stats, batch_size=500):
    """Procesa un CSV fila a fila: actualiza stats e inserta por lotes."""
    filas_archivo = 0
    buffer = []

    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            try:
                price = int(row["price"])
            except (ValueError, KeyError, TypeError):
                # Fila sin price valido: se ignora.
                continue

            event_date = row.get("timestamp", "")
            try:
                user_id = int(row["user_id"])
            except (ValueError, KeyError, TypeError):
                user_id = None

            stats.update(price)
            buffer.append((event_date, price, user_id))
            filas_archivo += 1

            if len(buffer) >= batch_size:
                db.insert_batch(buffer)
                buffer.clear()

    db.insert_batch(buffer)
    db.conn.commit()
    return filas_archivo


def run_pipeline(data_dir, db, stats, sleep_seconds=1.0):
    """Procesa los 2012-* uno a uno, persistiendo stats tras cada archivo."""
    archivos = discover_batch_files(data_dir)

    print(f"Archivos a procesar (excepto validation.csv): "
          f"{[os.path.basename(a) for a in archivos]}\n")

    for path in archivos:
        nombre = os.path.basename(path)
        print(f">>> Procesando micro-batch: {nombre}")
        filas = process_file(path, db, stats)
        db.save_stats(stats)

        print(f"    Filas en este archivo: {filas}")
        print(f"    Stats en ejecucion -> {stats}\n")

        # Espera entre lotes para simular la llegada escalonada de datos.
        time.sleep(sleep_seconds)

    return stats


def print_comparacion(titulo, stats_memoria, stats_db):
    print(f"===== {titulo} =====")
    print(f"  En ejecucion (memoria): {stats_memoria}")
    avg_db = (f"{stats_db['avg']:.4f}"
              if stats_db["avg"] is not None else "N/A")
    print(f"  Consulta a la BD      : count={stats_db['count']} | "
          f"avg={avg_db} | min={stats_db['min']} | max={stats_db['max']}")
    print()


def main():
    parser = argparse.ArgumentParser(description="Pipeline micro-batches Pragma")
    parser.add_argument("--data-dir", default="../dataPruebaDataEngineer",
                        help="Carpeta con los CSV.")
    parser.add_argument("--backend", default="sqlite",
                        choices=["sqlite", "postgres"],
                        help="Motor de BD destino.")
    parser.add_argument("--sleep", type=float, default=1.0,
                        help="Segundos de espera entre micro-batches.")
    parser.add_argument("--init-schema", action="store_true",
                        help="Ejecuta el DDL externo antes de procesar.")
    parser.add_argument("--db-path", default="pipeline.db",
                        help="Ruta del archivo SQLite.")
    args = parser.parse_args()

    if args.backend == "postgres":
        # Credenciales de PostgreSQL via variables de entorno.
        db = Database(
            backend="postgres",
            host=os.environ.get("PG_HOST", "localhost"),
            port=int(os.environ.get("PG_PORT", "5432")),
            dbname=os.environ.get("PG_DB", "pruebapragma"),
            user=os.environ.get("PG_USER", "pragma_admin"),
            password=os.environ.get("PG_PASSWORD", ""),
        )
    else:
        db = Database(backend="sqlite", db_path=args.db_path)

    db.connect()

    if args.init_schema:
        db.init_schema()

    stats = db.load_stats()
    print(f"Estado inicial reanudado desde la BD -> {stats}\n")

    # Fase 1: los cinco archivos 2012-*.
    stats = run_pipeline(args.data_dir, db, stats, sleep_seconds=args.sleep)
    print_comparacion("RESULTADO TRAS LOS ARCHIVOS 2012-*",
                       stats, db.query_db_stats())

    # Fase 2: validation.csv por el mismo pipeline.
    validation = os.path.join(args.data_dir, "validation.csv")
    if os.path.exists(validation):
        print(">>> Procesando validation.csv por el mismo pipeline")
        filas = process_file(validation, db, stats)
        db.save_stats(stats)
        print(f"    Filas en validation.csv: {filas}")
        print(f"    Stats en ejecucion -> {stats}\n")

        print_comparacion("RESULTADO TRAS validation.csv",
                           stats, db.query_db_stats())

    db.close()
    print("Pipeline finalizado.")


if __name__ == "__main__":
    main()
