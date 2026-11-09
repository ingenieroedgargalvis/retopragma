# retopragma
Reto de acercamiento al rol

# Prueba Ingeniería de Datos — Pipeline de ingesta por micro-batches

Pipeline que carga un conjunto de archivos CSV a una base de datos procesándolos
por micro-batches, y mantiene estadísticas en ejecución (conteo, promedio, mínimo
y máximo del campo `price`) que se actualizan de forma incremental.

## El reto

Se dispone de seis archivos CSV (`2012-1.csv` … `2012-5.csv` y `validation.csv`)
con los campos `timestamp`, `price`, `user_id`. El objetivo es construir un
pipeline que:

- Cargue los `2012-*.csv` (excepto `validation.csv`) a una sola base de datos, sin
  tener todos los archivos en memoria al mismo tiempo.
- Lleve estadísticas de `price` (count, avg, min, max) actualizadas de forma
  incremental, sin recalcular con `AVG()` sobre toda la tabla en cada paso.
- Permita comprobar los resultados antes y después de procesar `validation.csv`.

## Enfoque

- **Procesamiento por micro-batches:** se procesa un archivo a la vez y, dentro de
  cada archivo, se lee fila a fila. La huella de memoria es constante, así que la
  solución escala a volúmenes grandes sin cambios.
- **Estadísticas incrementales:** se mantienen los acumuladores `count`, `sum`,
  `min` y `max`; el promedio se deriva de `sum / count`. El estado se guarda en una
  tabla y puede reanudarse, de modo que las estadísticas en memoria y en la base de
  datos siempre coinciden.

## Estructura

```
.
├── src/
│   ├── pipeline.py            # pipeline (SQLite o PostgreSQL)
│   ├── lambda_function.py     # versión para AWS Lambda (lee de S3, escribe en RDS)
│   ├── schema_postgres.sql    # DDL para PostgreSQL / RDS
│   └── schema_sqlite.sql      # DDL para pruebas locales
├── Terraform/                 # infraestructura en AWS (S3, Lambda, RDS, etc.)
├── diagrama/                  # diagrama de arquitectura
└── dataPruebaDataEngineer/    # archivos CSV de entrada
```

## Ejecución local

Opción más rápida para probar el pipeline sin infraestructura (usa SQLite):

```bash
cd src
python pipeline.py --backend sqlite --init-schema --sleep 1
```

La salida muestra las estadísticas tras cada micro-batch, procesa `validation.csv`
al final y compara el estado incremental contra una consulta a la base de datos.

### Contra PostgreSQL

```bash
# Conexión por variables de entorno
export PG_HOST=<host> PG_DB=pruebapragma PG_USER=pragma_admin PG_PASSWORD=<password>

cd src
python pipeline.py --backend postgres --sleep 1
```

## Despliegue en AWS

La infraestructura se gestiona con Terraform. El pipeline corre como una función
Lambda que lee los CSV desde S3 y escribe en una base de datos RDS PostgreSQL.

```bash
cd Terraform
./build_layer.ps1                      # construye la layer de psycopg2
terraform init
export TF_VAR_db_password=<password>
export TF_VAR_ec2_key_name=<key-pair>
terraform apply
```

Una vez desplegado:

1. Crear las tablas ejecutando `src/schema_postgres.sql` en la base de datos
   (vía PgAdmin o `psql`).
2. Invocar la Lambda con payload `{}` para los `2012-*.csv` y luego con
   `{"key": "validation.csv"}` para la validación.

## Arquitectura

![Arquitectura](diagrama/arquitectura_pruebapragma.png)

| Componente | Función |
|---|---|
| S3 | Almacena los CSV de entrada. |
| Lambda (python3.9) | Ejecuta el pipeline; lee de S3 y escribe en RDS. |
| RDS PostgreSQL | Base de datos destino (privada). |
| EC2 (bastion) | Acceso a la base de datos privada vía túnel SSH. |
| Secrets Manager | Credencial de la base de datos. |
| VPC Endpoints | Acceso de la Lambda a S3 y Secrets Manager sin salir a internet. |

Toda la infraestructura usa tipos de instancia dentro de la capa gratuita.

## Comprobación de resultados

Las estadísticas se validan comparando el estado incremental (`running_stats`)
contra un recálculo con funciones de agregación sobre la tabla:

| Momento | Conteo | Promedio | Mínimo | Máximo |
|---|---|---|---|---|
| Tras los `2012-*.csv` | 139 | 57.8849 | 10 | 100 |
| Tras `validation.csv` | 147 | 57.0068 | 10 | 100 |

En ambos casos los valores coinciden, confirmando que las estadísticas se
mantienen correctamente sin recalcular sobre todo el conjunto de datos.
