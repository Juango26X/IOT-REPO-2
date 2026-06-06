import os
import logging
from typing import Optional

import boto3
import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logger = logging.getLogger("uvicorn.error")

# ──────────────────────────────────────────────
# Configuración AWS
# ──────────────────────────────────────────────
AWS_REGION      = os.environ.get("AWS_REGION", "us-east-1")
DYNAMO_TABLE    = os.environ.get("DYNAMO_TABLE", "SensorData-lab")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMO_TABLE)

# ──────────────────────────────────────────────
# Configuración PostgreSQL
# ──────────────────────────────────────────────
DB_HOST     = os.environ.get("DB_HOST", "localhost")
DB_PORT     = int(os.environ.get("DB_PORT", 5432))
DB_NAME     = os.environ.get("DB_NAME", "sensordb")
DB_USER     = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres")


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT,
        dbname=DB_NAME, user=DB_USER,
        password=DB_PASSWORD, connect_timeout=5
    )


# ──────────────────────────────────────────────
# FastAPI app
# ──────────────────────────────────────────────
app = FastAPI(
    title="IoT Sensor API",
    description="API REST unificada para la plataforma IoT. Consulta DynamoDB (hot data) y PostgreSQL (histórico).",
    version="1.0.0"
)


# ──────────────────────────────────────────────
# Modelos Pydantic
# ──────────────────────────────────────────────
class SensorCreate(BaseModel):
    device_id:   str
    sensor_type: str
    value:       float
    timestamp:   Optional[str] = None


# ──────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────

@app.get("/", tags=["Root"])
def root():
    return {"mensaje": "IoT Sensor API corriendo en ECS"}


@app.get("/health", tags=["Health"])
def health():
    return {"status": "ok"}


# GET /sensors – Lista todos los sensores (device_id únicos en DynamoDB)
@app.get("/sensors", tags=["Sensors"])
def get_sensors():
    try:
        response = table.scan(ProjectionExpression="device_id, sensor_type")
        items    = response.get("Items", [])
        # Paginar si hay más resultados
        while "LastEvaluatedKey" in response:
            response = table.scan(
                ProjectionExpression="device_id, sensor_type",
                ExclusiveStartKey=response["LastEvaluatedKey"]
            )
            items.extend(response.get("Items", []))
        return {"sensors": items, "total": len(items)}
    except Exception as e:
        logger.error(f"Error consultando DynamoDB: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# POST /sensors – Registra / actualiza un sensor en DynamoDB
@app.post("/sensors", tags=["Sensors"], status_code=201)
def create_sensor(sensor: SensorCreate):
    try:
        from datetime import datetime, timezone
        item = {
            "device_id":   sensor.device_id,
            "sensor_type": sensor.sensor_type,
            "value":       str(sensor.value),   # DynamoDB requiere Decimal o String para floats
            "timestamp":   sensor.timestamp or datetime.now(timezone.utc).isoformat()
        }
        table.put_item(Item=item)
        return {"mensaje": "Sensor registrado", "sensor": item}
    except Exception as e:
        logger.error(f"Error escribiendo en DynamoDB: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# GET /sensor/{id}/current – Dato en tiempo real desde DynamoDB
@app.get("/sensor/{device_id}/current", tags=["Sensors"])
def get_current(device_id: str):
    try:
        response = table.get_item(Key={"device_id": device_id})
        item     = response.get("Item")
        if not item:
            raise HTTPException(status_code=404, detail=f"Sensor '{device_id}' no encontrado")
        return item
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error consultando DynamoDB: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# GET /sensor/{id}/recent – Últimos 10 eventos desde PostgreSQL
@app.get("/sensor/{device_id}/recent", tags=["Sensors"])
def get_recent(device_id: str):
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, device_id, sensor_type, value, ts, s3_key, created_at
                FROM sensor_history
                WHERE device_id = %s
                ORDER BY ts DESC
                LIMIT 10
                """,
                (device_id,)
            )
            rows = cur.fetchall()
        conn.close()
        return {"device_id": device_id, "recent": [dict(r) for r in rows]}
    except Exception as e:
        logger.error(f"Error consultando PostgreSQL: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# GET /sensor/{id}/history – Histórico completo desde PostgreSQL
@app.get("/sensor/{device_id}/history", tags=["Sensors"])
def get_history(device_id: str):
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, device_id, sensor_type, value, ts, s3_key, created_at
                FROM sensor_history
                WHERE device_id = %s
                ORDER BY ts DESC
                """,
                (device_id,)
            )
            rows = cur.fetchall()
        conn.close()
        return {"device_id": device_id, "history": [dict(r) for r in rows], "total": len(rows)}
    except Exception as e:
        logger.error(f"Error consultando PostgreSQL: {e}")
        raise HTTPException(status_code=500, detail=str(e))
