import os
import json
import logging
import boto3
import psycopg2

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')


def get_db_connection():
    """Crea y retorna una conexión a PostgreSQL usando variables de entorno."""
    return psycopg2.connect(
        host=os.environ['DB_HOST'],
        port=int(os.environ.get('DB_PORT', 5432)),
        dbname=os.environ['DB_NAME'],
        user=os.environ['DB_USER'],
        password=os.environ['DB_PASSWORD'],
        connect_timeout=5
    )


def ensure_table(conn):
    """Crea la tabla de histórico si no existe."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sensor_history (
                id          SERIAL PRIMARY KEY,
                device_id   VARCHAR(100) NOT NULL,
                sensor_type VARCHAR(50),
                value       DOUBLE PRECISION,
                ts          TIMESTAMPTZ,
                s3_key      TEXT,
                created_at  TIMESTAMPTZ DEFAULT NOW()
            );
        """)
    conn.commit()


def lambda_handler(event, context):

    logger.info(f"Evento recibido: {json.dumps(event)}")

    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key    = record['s3']['object']['key']

        # S3 entrega la key URL-encoded en el evento (ej. year%3D2026 en vez de year=2026)
        from urllib.parse import unquote_plus
        key = unquote_plus(key)

        logger.info(f"Procesando objeto s3://{bucket}/{key}")

        # 1. Leer el JSON desde S3
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
            body     = response['Body'].read().decode('utf-8')
            payload  = json.loads(body)
        except Exception as e:
            logger.error(f"Error leyendo s3://{bucket}/{key}: {e}")
            raise

        # 2. Insertar en PostgreSQL
        try:
            conn = get_db_connection()
            ensure_table(conn)

            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO sensor_history (device_id, sensor_type, value, ts, s3_key)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (
                        payload.get('device_id'),
                        payload.get('sensor_type'),
                        payload.get('value'),
                        payload.get('timestamp'),
                        key
                    )
                )
            conn.commit()
            conn.close()
            logger.info(f"Registro insertado en PostgreSQL para device_id={payload.get('device_id')}")

        except Exception as e:
            logger.error(f"Error insertando en PostgreSQL: {e}")
            raise

    return {'statusCode': 200, 'body': 'OK'}
