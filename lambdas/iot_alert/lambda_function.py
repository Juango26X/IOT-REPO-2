import os
import json
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs_client = boto3.client('sqs')


def lambda_handler(event, context):
    """
    Se activa mediante la Regla 3 de AWS IoT Core cuando temperature > umbral.
    Envía un mensaje de alerta a la cola SQS de urgencia.
    """
    logger.info(f"Alerta IoT recibida: {json.dumps(event)}")

    queue_url = os.environ.get('ALERT_QUEUE_URL')
    if not queue_url:
        raise ValueError("Variable de entorno ALERT_QUEUE_URL no configurada")

    device_id   = event.get('device_id', 'desconocido')
    sensor_type = event.get('sensor_type', 'desconocido')
    value       = event.get('value', 0)
    timestamp   = event.get('timestamp', '')

    alert_message = {
        "nivel":       "URGENTE",
        "device_id":   device_id,
        "sensor_type": sensor_type,
        "value":       value,
        "timestamp":   timestamp,
        "descripcion": f"ALERTA: {sensor_type} del dispositivo {device_id} superó el umbral con valor {value}"
    }

    response = sqs_client.send_message(
        QueueUrl    = queue_url,
        MessageBody = json.dumps(alert_message)
    )

    logger.info(f"Mensaje de alerta enviado a SQS. MessageId: {response['MessageId']}")

    return {'statusCode': 200, 'body': 'Alerta enviada a SQS'}
