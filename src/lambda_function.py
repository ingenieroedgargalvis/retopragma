"""
Handler de la Lambda del pipeline.

Lee los CSV desde S3 fila a fila (sin descargar el archivo completo), mantiene
las estadisticas de price con acumuladores incrementales y escribe en RDS
PostgreSQL. La credencial de la BD se obtiene de Secrets Manager.

Variables de entorno (las inyecta Terraform):
  S3_BUCKET, S3_PREFIX, DB_HOST, DB_PORT, DB_NAME, DB_SECRET_ARN
"""

import os
import csv
import json
import codecs

import boto3
import psycopg2


class RunningStats:
    def __init__(self, count=0, total=0, minv=None, maxv=None):
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
        return None if self.count == 0 else self.total / self.count

    def as_dict(self):
        return {"count": self.count, "avg": self.avg,
                "min": self.minv, "max": self.maxv}


def get_db_credentials(secret_arn):
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=secret_arn)
    secret = json.loads(resp["SecretString"])
    return secret["username"], secret["password"]


def connect_db():
    username, password = get_db_credentials(os.environ["DB_SECRET_ARN"])
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=username,
        password=password,
        connect_timeout=10,
    )


def load_stats(conn):
    """Reconstruye el acumulador desde running_stats para reanudar."""
    cur = conn.cursor()
    cur.execute("SELECT row_count, sum_price, min_price, max_price "
                "FROM running_stats WHERE id=1")
    fila = cur.fetchone()
    if fila is None:
        return RunningStats()
    row_count, sum_price, min_price, max_price = fila
    return RunningStats(count=row_count or 0, total=sum_price or 0,
                        minv=min_price, maxv=max_price)


def save_stats(conn, stats):
    cur = conn.cursor()
    cur.execute(
        "UPDATE running_stats SET row_count=%s, sum_price=%s, "
        "min_price=%s, max_price=%s WHERE id=1",
        (stats.count, stats.total, stats.minv, stats.maxv),
    )
    conn.commit()


def list_batch_objects(s3, bucket, prefix):
    """Lista los 2012-*.csv del bucket, ordenados por nombre."""
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            nombre = key.split("/")[-1]
            if nombre.startswith("2012-") and nombre.endswith(".csv"):
                keys.append(key)
    keys.sort()
    return keys


def process_object(s3, bucket, key, conn, stats, batch_size=500):
    """Recorre el objeto S3 como stream, actualiza stats e inserta por lotes."""
    obj = s3.get_object(Bucket=bucket, Key=key)
    stream = codecs.getreader("utf-8")(obj["Body"])
    reader = csv.DictReader(stream)

    buffer = []
    filas = 0
    cur = conn.cursor()

    for row in reader:
        try:
            price = int(row["price"])
        except (ValueError, KeyError, TypeError):
            continue
        event_date = row.get("timestamp", "")
        try:
            user_id = int(row["user_id"])
        except (ValueError, KeyError, TypeError):
            user_id = None

        stats.update(price)
        buffer.append((event_date, price, user_id))
        filas += 1

        if len(buffer) >= batch_size:
            cur.executemany(
                "INSERT INTO transactions (event_date, price, user_id) "
                "VALUES (%s, %s, %s)", buffer)
            buffer.clear()

    if buffer:
        cur.executemany(
            "INSERT INTO transactions (event_date, price, user_id) "
            "VALUES (%s, %s, %s)", buffer)
    conn.commit()
    return filas


def handler(event, context):
    """Procesa los 2012-*.csv, o solo validation.csv si el event trae 'key'."""
    bucket = os.environ["S3_BUCKET"]
    prefix = os.environ.get("S3_PREFIX", "")

    s3 = boto3.client("s3")
    conn = connect_db()

    try:
        stats = load_stats(conn)

        single_key = event.get("key") if isinstance(event, dict) else None
        keys = [single_key] if single_key else list_batch_objects(s3, bucket, prefix)

        resultados = []
        for key in keys:
            filas = process_object(s3, bucket, key, conn, stats)
            save_stats(conn, stats)
            resultados.append({"key": key, "filas": filas,
                               "stats": stats.as_dict()})

        return {
            "statusCode": 200,
            "body": json.dumps({
                "procesados": resultados,
                "stats_finales": stats.as_dict(),
            }),
        }
    finally:
        conn.close()
