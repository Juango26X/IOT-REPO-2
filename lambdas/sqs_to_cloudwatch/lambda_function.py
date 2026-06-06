import json
import logging

# Logger raíz – todo lo que se escriba aquí va a CloudWatch Logs automáticamente
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Se activa con el trigger SQS (cola de alertas de urgencia).
    Procesa cada mensaje y escribe un log de urgencia en CloudWatch Logs.
    Igual al patrón de 10_sqs/withLambda.
    """
    logger.info(f"Evento SQS recibido: {json.dumps(event)}")

    for record in event.get('Records', []):
        message_id   = record.get('messageId')
        message_body = record.get('body', '{}')

        try:
            payload = json.loads(message_body)
        except json.JSONDecodeError:
            payload = {"raw": message_body}

        nivel       = payload.get('nivel', 'DESCONOCIDO')
        device_id   = payload.get('device_id', 'N/A')
        sensor_type = payload.get('sensor_type', 'N/A')
        value       = payload.get('value', 'N/A')
        timestamp   = payload.get('timestamp', 'N/A')
        descripcion = payload.get('descripcion', '')

        # Este log de urgencia queda registrado en CloudWatch Logs
        logger.critical(
            f"[LOG DE URGENCIA] nivel={nivel} | device_id={device_id} | "
            f"sensor_type={sensor_type} | value={value} | ts={timestamp} | "
            f"msg_id={message_id} | detalle={descripcion}"
        )

    return {
        'statusCode': 200,
        'body': json.dumps('Alertas de urgencia registradas en CloudWatch')
    }
