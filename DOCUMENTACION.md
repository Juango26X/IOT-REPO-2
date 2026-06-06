# Documentación Técnica — Plataforma IoT en AWS

## Índice

1. [Arquitectura General](#1-arquitectura-general)
2. [Flujo de Datos](#2-flujo-de-datos)
3. [Cómo Ejecutar](#3-cómo-ejecutar)
4. [Docker Compose — Sensores Locales](#4-docker-compose--sensores-locales)
5. [Sensor Simulator](#5-sensor-simulator)
6. [Terraform — Estructura de Módulos](#6-terraform--estructura-de-módulos)
7. [Módulo Networking](#7-módulo-networking)
8. [Módulo Storage](#8-módulo-storage)
9. [Módulo Database](#9-módulo-database)
10. [Módulo IoT](#10-módulo-iot)
11. [Módulo Compute](#11-módulo-compute)
12. [API FastAPI](#12-api-fastapi)
13. [Lambdas](#13-lambdas)
14. [Permisos y Seguridad](#14-permisos-y-seguridad)

---

## 1. Arquitectura General

El proyecto implementa una plataforma IoT completa con dos entornos:

- **Local (Docker Compose):** sensores simulados que envían datos por MQTT a un broker Mosquitto.
- **Nube (AWS):** Mosquitto actúa como bridge y reenvía los datos a AWS IoT Core, que los distribuye a múltiples destinos.

```
Local (Docker Compose)           AWS (Terraform)
──────────────────────           ───────────────────────────────────────
sensor-temp-01    ─┐
                   ├─► Mosquitto ──TLS──► IoT Core ─► DynamoDB (hot data)
sensor-humidity-01 ┘   (bridge)                    ─► S3 (cold data)
                                                   ─► Lambda alerta ─► SQS ─► Lambda CW ─► CloudWatch

                                  S3 ─► Lambda s3_to_postgres ─► PostgreSQL

                                  ECS (FastAPI) ─► DynamoDB / PostgreSQL
```

---

## 2. Flujo de Datos

### Paso 1 — Sensor genera dato

Cada sensor Python genera un JSON cada N segundos:

```json
{
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "value": 37.5,
  "timestamp": "2024-01-01T00:00:00Z"
}
```

### Paso 2 — Mosquitto reenvía a AWS IoT Core

Mosquitto está configurado como bridge. Recibe el mensaje en el tópico `lab/sensors/data` y lo reenvía a AWS IoT Core usando TLS con certificados X.509.

### Paso 3 — IoT Core aplica las 3 reglas

| Regla | Condición | Acción |
|---|---|---|
| Regla 1 | Todo mensaje | Guarda en DynamoDB (sobrescribe el último valor) |
| Regla 2 | Todo mensaje | Guarda como JSON en S3 (particionado por fecha) |
| Regla 3 | `sensor_type = 'temperature' AND value > 35` | Invoca Lambda de alerta |

### Paso 4 — Cadena de alertas

```
IoT Core (Regla 3) → Lambda iot_alert → SQS → Lambda sqs_to_cloudwatch → CloudWatch Logs
```

### Paso 5 — Histórico en PostgreSQL

```
S3 (nuevo archivo) → Lambda s3_to_postgres → PostgreSQL (tabla sensor_history)
```

### Paso 6 — API REST

La API FastAPI corre en ECS y expone los datos:

| Endpoint | Fuente | Descripción |
|---|---|---|
| `GET /sensors` | DynamoDB | Lista todos los sensores |
| `POST /sensors` | DynamoDB | Registra un nuevo sensor |
| `GET /sensor/{id}/current` | DynamoDB | Último valor en tiempo real |
| `GET /sensor/{id}/recent` | PostgreSQL | Últimos 10 eventos |
| `GET /sensor/{id}/history` | PostgreSQL | Histórico completo |

---

## 3. Cómo Ejecutar

### Desplegar todo en AWS

```bash
make aws-up
```

Este comando hace en orden:
1. Crea el repositorio ECR con Terraform
2. Hace `docker build` y `docker push` de la API al ECR
3. Despliega toda la infraestructura con `terraform apply`

Al finalizar imprime la URL de la API.

### Levantar sensores locales

```bash
make local-up
```

### Ver datos en tiempo real

```bash
make logs
```

### Destruir todo

```bash
make clean
```

---

## 4. Docker Compose — Sensores Locales

**Archivo:** `docker-compose.yml`

Define tres servicios que corren en tu PC:

### Mosquitto

```yaml
mosquitto:
  build: ./edge_gateway
  ports:
    - "1883:1883"
```

Broker MQTT local. Recibe mensajes de los sensores y los reenvía a AWS IoT Core. El `Dockerfile` empaqueta los certificados TLS y el `mosquitto.conf` generado por Terraform.

### sensor-temp-01

```yaml
sensor_temp_01:
  build: ./python_device
  environment:
    - CLIENT_ID=sensor-temp-01
    - SENSOR_TYPE=temperature
    - INTERVAL=5
```

Publica datos de temperatura cada 5 segundos. El `CLIENT_ID` es el `device_id` que aparece en DynamoDB y PostgreSQL.

### sensor-humidity-01

```yaml
sensor_humidity_01:
  environment:
    - CLIENT_ID=sensor-humidity-01
    - SENSOR_TYPE=humidity
    - INTERVAL=7
```

Publica datos de humedad cada 7 segundos.

### sensor-oxygen-01 (comentado — para sustentación)

```yaml
# sensor_oxygen_01:
#   environment:
#     - CLIENT_ID=sensor-oxygen-01
#     - SENSOR_TYPE=oxygen
#     - INTERVAL=10
```

Para agregar el sensor de oxígeno durante la sustentación: descomentar este bloque y correr `make local-up`.

---

## 5. Sensor Simulator

**Archivo:** `python_device/sensor_simulator.py`

Script Python que simula un sensor IoT. Se configura completamente por variables de entorno.

### Variables de entorno

| Variable | Descripción | Default |
|---|---|---|
| `MQTT_HOST` | Host del broker MQTT | `localhost` |
| `MQTT_PORT` | Puerto del broker | `1883` |
| `CLIENT_ID` | ID del dispositivo | Aleatorio |
| `SENSOR_TYPE` | Tipo de sensor | `temperature` |
| `INTERVAL` | Segundos entre publicaciones | `5` |

### Tipos de sensor soportados

| Tipo | Rango de valores |
|---|---|
| `temperature` | 20.0 – 40.0 °C |
| `humidity` | 40.0 – 60.0 % |
| `oxygen` | 19.5 – 23.5 % |
| cualquier otro | 0.0 – 100.0 |

### Flujo del script

```python
# 1. Se conecta al broker Mosquitto local
client.connect(MQTT_HOST, MQTT_PORT)

# 2. Genera datos simulados
payload = generate_sensor_data()
# → {"device_id": "sensor-temp-01", "sensor_type": "temperature", "value": 32.5, "timestamp": "..."}

# 3. Publica al tópico
client.publish("lab/sensors/data", json.dumps(payload), qos=1)

# 4. Espera N segundos y repite
time.sleep(INTERVAL)
```

---

## 6. Terraform — Estructura de Módulos

**Archivo raíz:** `terraform/main.tf`

El proyecto usa 5 módulos Terraform. El orden de creación está determinado por las dependencias:

```
networking ─┐
            ├──► database ─┐
storage ────┘              ├──► compute ──► iot
                           │
networking ────────────────┘
```

### Variables globales (`terraform/variables.tf`)

| Variable | Descripción | Default |
|---|---|---|
| `project_name` | Nombre del proyecto | `iot-edge` |
| `environment` | Entorno | `lab` |
| `db_name` | Nombre de la BD PostgreSQL | `sensordb` |
| `db_user` | Usuario PostgreSQL | `sensoradmin` |
| `db_password` | Contraseña PostgreSQL | *(requerida)* |
| `alert_threshold` | Umbral de temperatura para alertas | `35` |

---

## 7. Módulo Networking

**Archivo:** `terraform/modules/networking/main.tf`

Gestiona todos los recursos de red. Otros módulos reciben los IDs como variables.

### VPC y Subnets

```hcl
data "aws_vpc" "default" {
  default = true
}
```

No crea una VPC nueva. Lee la VPC por defecto que AWS crea automáticamente en cada cuenta.

```hcl
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
```

Obtiene todas las subnets de la VPC. La VPC default tiene subnets en múltiples zonas de disponibilidad (us-east-1a, 1b, 1c...).

### Security Groups

**ALB Security Group** — permite tráfico HTTP desde internet:
```
Internet → puerto 80 → ALB ✅
```

**ECS Security Group** — solo acepta tráfico del ALB:
```
ALB → puerto 8000 → Contenedor FastAPI ✅
Internet → puerto 8000 → Contenedor FastAPI ❌
```

**RDS Security Group** — acepta conexiones PostgreSQL desde la VPC:
```
ECS / Lambda (dentro de la VPC) → puerto 5432 → RDS ✅
```

### Application Load Balancer

El ALB tiene tres recursos que trabajan juntos:

```
Internet
    │ puerto 80
    ▼
aws_lb (el ALB)           ← URL pública fija
    │
aws_lb_listener           ← escucha en puerto 80, reenvía al target group
    │
aws_lb_target_group       ← lista de IPs de contenedores ECS (puerto 8000)
    │
Contenedor FastAPI
```

**Health check:** cada 30 segundos llama a `/health`. Si el contenedor no responde 200, ECS lo reemplaza.

### DB Subnet Group

```hcl
resource "aws_db_subnet_group" "rds_subnet_group" {
  subnet_ids = data.aws_subnets.default.ids
}
```

RDS requiere mínimo 2 subnets en distintas zonas de disponibilidad. Se usa el grupo de subnets para cumplir este requisito.

---

## 8. Módulo Storage

**Archivo:** `terraform/modules/storage/main.tf`

Crea dos buckets S3:

### Bucket de sensores

```hcl
resource "aws_s3_bucket" "sensor_data" {
  bucket        = "${var.environment}-${var.project_name}-sensor-data-${random_id.id.hex}"
  force_destroy = true
}
```

Recibe los archivos JSON de los sensores via IoT Core. Los archivos se organizan automáticamente con esta estructura:

```
data/
  year=2024/
    month=01/
      day=15/
        data_<uuid>.json
```

Esta partición permite consultas eficientes con Amazon Athena.

### Bucket de Athena

Bucket reservado para guardar los resultados de queries de Athena.

El sufijo `random_id` garantiza nombres únicos globalmente (los nombres de S3 son únicos en todo AWS).

---

## 9. Módulo Database

**Archivo:** `terraform/modules/database/main.tf`

### DynamoDB — Hot Data

```hcl
resource "aws_dynamodb_table" "sensor_data" {
  name         = "SensorData-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"
}
```

**Diseño clave:** solo tiene `device_id` como partition key, sin sort key. Esto significa que por cada sensor solo existe **un registro** — el más reciente. Cada nuevo dato **sobrescribe** el anterior.

Este patrón se llama **Device Twin** o **Device Shadow**: la tabla siempre refleja el estado actual de cada sensor, no el histórico.

### RDS PostgreSQL — Histórico

```hcl
resource "aws_db_instance" "sensor_history" {
  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.micro"
  db_name        = var.db_name
  username       = var.db_user
  password       = var.db_password
  publicly_accessible    = true
  vpc_security_group_ids = [var.rds_sg_id]
  db_subnet_group_name   = var.rds_subnet_group_name
}
```

Instancia PostgreSQL 15 en `db.t3.micro`. Guarda el histórico completo de todos los eventos de todos los sensores en la tabla `sensor_history`.

La tabla la crea automáticamente la Lambda `s3_to_postgres` la primera vez que se ejecuta.

---

## 10. Módulo IoT

**Archivo:** `terraform/modules/iot/main.tf`

### IoT Thing y Certificados

```
aws_iot_thing          → el dispositivo virtual en AWS
aws_iot_certificate    → los certificados X.509 para autenticación TLS
aws_iot_policy         → qué puede hacer el dispositivo
```

La cadena de identidad:
```
Mosquitto (físico) ↔ Certificado X.509 ↔ Política de permisos ↔ IoT Thing
```

### Política de IoT

Restringe al dispositivo a solo poder:

| Acción | Recurso |
|---|---|
| Connect | Solo con client ID = `edge-gateway-01-lab` |
| Publish/Receive | Solo al tópico `lab/sensors/*` |
| Subscribe | Solo al tópico `lab/sensors/*` |

### Certificados locales

Terraform descarga automáticamente los certificados a `edge_gateway/certs/`:

```
certificate.pem.crt   ← certificado del dispositivo (pasaporte digital)
private.pem.key       ← clave privada (secreto, nunca compartir)
public.pem.key        ← clave pública
AmazonRootCA1.pem     ← certificado raíz de Amazon
```

También genera `edge_gateway/mosquitto.conf` con el endpoint de IoT Core inyectado.

### Las 3 Reglas IoT

**Regla 1 — DynamoDB:**
```sql
SELECT * FROM 'lab/sensors/data'
```
Todo mensaje se guarda en DynamoDB (sobrescribiendo el valor anterior del sensor).

**Regla 2 — S3:**
```sql
SELECT * FROM 'lab/sensors/data'
```
Todo mensaje se guarda como archivo JSON en S3, particionado por fecha.

**Regla 3 — Alerta:**
```sql
SELECT * FROM 'lab/sensors/data'
WHERE sensor_type = 'temperature' AND value > 35
```
Si la temperatura supera 35°C, invoca la Lambda de alerta.

---

## 11. Módulo Compute

**Archivo:** `terraform/modules/compute/main.tf`

### Lambda s3_to_postgres

**Trigger:** `s3:ObjectCreated:*` en el bucket de sensores.

**Dependencias:** incluye `psycopg2` empaquetado en el zip. Terraform instala las dependencias automáticamente con `pip install` antes de crear el zip:

```hcl
resource "null_resource" "install_s3_to_postgres_deps" {
  provisioner "local-exec" {
    command = "pip install -r requirements.txt -t package/ --quiet"
  }
}
```

**Flujo:**
1. S3 crea un nuevo archivo JSON
2. Lambda lee el archivo con `s3_client.get_object()`
3. La función `ensure_table()` crea la tabla si no existe
4. Inserta el registro en PostgreSQL

### Lambda iot_alert

**Trigger:** Regla 3 de IoT Core (temperatura > 35°C).

**Flujo:**
1. IoT Core invoca la Lambda con el payload del sensor
2. Construye un mensaje de alerta con nivel "URGENTE"
3. Envía el mensaje a la cola SQS

### SQS Queue

```hcl
resource "aws_sqs_queue" "alert_queue" {
  name                      = "iot-edge-alert-queue-lab"
  message_retention_seconds = 86400  # 1 día
}
```

Cola que recibe los mensajes de alerta. El trigger SQS → Lambda se configura con `aws_lambda_event_source_mapping`.

### Lambda sqs_to_cloudwatch

**Trigger:** mensajes en la cola SQS (batch de hasta 10).

**Flujo:**
1. SQS entrega los mensajes en lote
2. Lambda procesa cada mensaje
3. Escribe un log crítico en CloudWatch:

```
[LOG DE URGENCIA] nivel=URGENTE | device_id=sensor-temp-01 | value=38.5 | ...
```

### ECR + ECS

**ECR (Elastic Container Registry):** repositorio privado donde se guarda la imagen Docker de la API. Equivalente a Docker Hub pero dentro de AWS.

**ECS Cluster:** el entorno donde corren los contenedores.

**Task Definition:** la receta del contenedor. Define la imagen a usar, CPU, memoria y variables de entorno:

```hcl
environment = [
  { name = "DYNAMO_TABLE", value = var.dynamo_table_name },
  { name = "DB_HOST",      value = var.db_host },
  { name = "DB_PASSWORD",  value = var.db_password }
]
```

**ECS Service:** supervisor que mantiene siempre 1 contenedor corriendo. Si el contenedor falla, lo reinicia. Conecta el contenedor al ALB registrando su IP en el target group.

---

## 12. API FastAPI

**Archivo:** `api/main.py`

API REST que expone los datos de los sensores. Corre en ECS (Fargate) y es accesible via el ALB.

### Conexiones a bases de datos

**DynamoDB** — usa `boto3`, el SDK de AWS. Se autentica con el IAM role de la tarea ECS (no necesita usuario/contraseña):

```python
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMO_TABLE)
```

**PostgreSQL** — usa `psycopg2`, el driver estándar. Necesita credenciales explícitas que llegan por variables de entorno:

```python
psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD)
```

### Endpoints

| Método | Ruta | Base de datos | Descripción |
|---|---|---|---|
| GET | `/` | — | Mensaje de bienvenida |
| GET | `/health` | — | Health check para el ALB |
| GET | `/sensors` | DynamoDB | Lista todos los sensores |
| POST | `/sensors` | DynamoDB | Registra un nuevo sensor |
| GET | `/sensor/{id}/current` | DynamoDB | Último valor del sensor |
| GET | `/sensor/{id}/recent` | PostgreSQL | Últimos 10 eventos |
| GET | `/sensor/{id}/history` | PostgreSQL | Histórico completo |

### Swagger UI

FastAPI genera automáticamente documentación interactiva en:
```
http://<api_url>/docs
```

---

## 13. Lambdas

### Lambda s3_to_postgres (`lambdas/s3_to_postgres/lambda_function.py`)

```python
def lambda_handler(event, context):
    for record in event.get('Records', []):
        # 1. Obtiene el bucket y key del archivo recién creado
        bucket = record['s3']['bucket']['name']
        key    = record['s3']['object']['key']

        # 2. Lee el JSON desde S3
        response = s3_client.get_object(Bucket=bucket, Key=key)
        payload  = json.loads(response['Body'].read())

        # 3. Crea la tabla si no existe (primera ejecución)
        ensure_table(conn)

        # 4. Inserta en PostgreSQL
        cur.execute("INSERT INTO sensor_history ...")
```

### Lambda iot_alert (`lambdas/iot_alert/lambda_function.py`)

```python
def lambda_handler(event, context):
    # event contiene el payload del sensor directamente
    # (IoT Core lo pasa como el cuerpo del mensaje)

    alert_message = {
        "nivel":     "URGENTE",
        "device_id": event.get('device_id'),
        "value":     event.get('value'),
        ...
    }

    sqs_client.send_message(
        QueueUrl    = os.environ['ALERT_QUEUE_URL'],
        MessageBody = json.dumps(alert_message)
    )
```

### Lambda sqs_to_cloudwatch (`lambdas/sqs_to_cloudwatch/lambda_function.py`)

```python
def lambda_handler(event, context):
    for record in event.get('Records', []):
        # SQS entrega los mensajes en lotes (batch_size = 10)
        payload = json.loads(record['body'])

        logger.critical(
            f"[LOG DE URGENCIA] nivel={payload['nivel']} | "
            f"device_id={payload['device_id']} | value={payload['value']}"
        )
        # Todo lo que escribe logger va automáticamente a CloudWatch Logs
```

---

## 14. Permisos y Seguridad

### IAM — LabRole

Todos los componentes usan el mismo rol `LabRole`, que es el rol preexistente del AWS Learner Lab con permisos amplios.

| Componente | Permisos que usa |
|---|---|
| Lambda s3_to_postgres | `s3:GetObject` |
| Lambda iot_alert | `sqs:SendMessage` |
| Lambda sqs_to_cloudwatch | `logs:CreateLogGroup`, `logs:PutLogEvents` |
| ECS Task | `dynamodb:Scan`, `dynamodb:GetItem`, `dynamodb:PutItem`, `ecr:GetDownloadUrlForLayer` |
| IoT Rules | `dynamodb:PutItem`, `s3:PutObject` |

### IAM — Permisos de invocación

Para que un servicio AWS pueda invocar una Lambda, se necesita un permiso explícito (`aws_lambda_permission`):

```
S3       → puede invocar Lambda s3_to_postgres
IoT Core → puede invocar Lambda iot_alert
SQS      → puede invocar Lambda sqs_to_cloudwatch (vía event_source_mapping)
```

### Security Groups — Red

```
Internet ──80──► ALB SG ──8000──► ECS SG
                                      │
         VPC ──5432──► RDS SG ◄───────┘
```

- **ALB SG:** acepta HTTP (80) desde cualquier IP
- **ECS SG:** acepta puerto 8000 solo desde el ALB
- **RDS SG:** acepta PostgreSQL (5432) desde toda la VPC

### IoT Core — Política del dispositivo

El certificado X.509 solo puede:
- Conectarse con client ID = `edge-gateway-01-lab`
- Publicar/suscribirse al tópico `lab/sensors/*`

Cualquier otro intento de acceso es rechazado por AWS IoT Core.

---

## Estructura de Archivos

```
7_iot_s3_dynamo_athena/
├── Makefile                          ← comandos de ejecución
├── docker-compose.yml                ← sensores locales
├── python_device/
│   └── sensor_simulator.py           ← código del sensor
├── edge_gateway/
│   ├── Dockerfile
│   ├── certs/                        ← certificados (generados por Terraform)
│   └── mosquitto.conf                ← config del bridge (generada por Terraform)
├── api/
│   ├── main.py                       ← API FastAPI
│   ├── Dockerfile
│   ├── requirements.txt
│   └── build_and_deploy.sh           ← build y push de imagen a ECR
├── lambdas/
│   ├── s3_to_postgres/
│   │   └── lambda_function.py        ← S3 → PostgreSQL
│   ├── iot_alert/
│   │   └── lambda_function.py        ← IoT → SQS
│   └── sqs_to_cloudwatch/
│       └── lambda_function.py        ← SQS → CloudWatch
└── terraform/
    ├── main.tf                       ← módulo raíz
    ├── variables.tf
    ├── outputs.tf
    ├── data.tf
    └── modules/
        ├── networking/               ← VPC, SGs, ALB
        ├── storage/                  ← S3
        ├── database/                 ← DynamoDB + RDS
        ├── compute/                  ← Lambdas + SQS + ECS
        └── iot/                      ← IoT Core
```

---

## 15. Flujo de Variables en Terraform

En Terraform cada módulo es independiente — no puede leer variables de otro módulo directamente. El `main.tf` raíz actúa como intermediario que recibe valores y los distribuye.

El patrón siempre es:

```
variables.tf (define) → main.tf raíz (distribuye) → módulo/variables.tf (declara) → módulo/main.tf (usa)
```

---

### Variable: `db_password`

Recorre todo el proyecto desde que el usuario la escribe hasta que llega al código Python.

```
terraform/variables.tf
  default = "Sensor2024!"
        │
        ▼
terraform/main.tf
  module "database" { db_password = var.db_password }
  module "compute"  { db_password = var.db_password }
        │                               │
        ▼                               ▼
modules/database/main.tf        modules/compute/main.tf
  aws_db_instance {               aws_ecs_task_definition {
    password = var.db_password      environment = [
  }                                   { name="DB_PASSWORD", value=var.db_password }
                                    ]
                                  }
                                  aws_lambda_function {
                                    environment = {
                                      DB_PASSWORD = var.db_password
                                    }
                                  }
        │                               │
        ▼                               ▼
  RDS PostgreSQL              api/main.py y lambdas/s3_to_postgres/lambda_function.py
  (contraseña del usuario)      DB_PASSWORD = os.environ.get("DB_PASSWORD")
```

---

### Variable: `sensor_bucket_name` y `sensor_bucket_arn`

El nombre y ARN del bucket de S3 nacen en el módulo storage y llegan al módulo compute (para el trigger Lambda) y al módulo iot (para la regla S3).

```
modules/storage/main.tf
  resource "aws_s3_bucket" "sensor_data" { ... }
        │
        ▼
modules/storage/outputs.tf
  output "sensor_bucket_name" { value = aws_s3_bucket.sensor_data.bucket }
  output "sensor_bucket_arn"  { value = aws_s3_bucket.sensor_data.arn }
        │
        ▼
terraform/main.tf
  module "compute" { sensor_bucket_name = module.storage.sensor_bucket_name
                     sensor_bucket_arn  = module.storage.sensor_bucket_arn }
  module "iot"     { sensor_bucket_name = module.storage.sensor_bucket_name }
        │                               │
        ▼                               ▼
modules/compute/main.tf         modules/iot/main.tf
  aws_s3_bucket_notification {    aws_iot_topic_rule "s3_rule" {
    bucket = var.sensor_bucket_name   s3 { bucket_name = var.sensor_bucket_name }
  }                               }
  aws_lambda_permission {
    source_arn = var.sensor_bucket_arn
  }
```

---

### Variable: `iot_alert_lambda_arn`

El ARN de la Lambda de alerta nace en compute y viaja a iot para que la Regla 3 sepa a qué Lambda invocar.

```
modules/compute/main.tf
  resource "aws_lambda_function" "iot_alert" { ... }
        │
        ▼
modules/compute/outputs.tf
  output "iot_alert_lambda_arn" { value = aws_lambda_function.iot_alert.arn }
        │
        ▼
terraform/main.tf
  module "iot" { iot_alert_lambda_arn = module.compute.iot_alert_lambda_arn }
        │
        ▼
modules/iot/main.tf
  aws_iot_topic_rule "alert_rule" {
    lambda { function_arn = var.iot_alert_lambda_arn }
  }
```

Nota: por esto en el `main.tf` raíz el módulo `iot` tiene `depends_on = [module.compute]` — la Lambda debe existir antes de que IoT Core pueda apuntar a ella.

---

### Variable: `db_host`

El host de RDS no se conoce hasta que Terraform crea la instancia. Por eso nace como output del módulo database y viaja a compute para inyectarlo en ECS y las Lambdas.

```
modules/database/main.tf
  resource "aws_db_instance" "sensor_history" { ... }
        │
        ▼
modules/database/outputs.tf
  output "db_host" { value = aws_db_instance.sensor_history.address }
        │
        ▼
terraform/main.tf
  module "compute" { db_host = module.database.db_host }
        │
        ▼
modules/compute/main.tf
  aws_ecs_task_definition {
    environment = [{ name = "DB_HOST", value = var.db_host }]
  }
  aws_lambda_function "s3_to_postgres" {
    environment = { DB_HOST = var.db_host }
  }
        │
        ▼
  ECS (api/main.py)                    Lambda (s3_to_postgres)
  DB_HOST = os.environ.get("DB_HOST")  host=os.environ['DB_HOST']
```

---

### Variable: `rds_sg_id` y `rds_subnet_group_name`

Nacen en networking y viajan a database para que RDS quede dentro de la red correcta.

```
modules/networking/main.tf
  resource "aws_security_group" "rds_sg" { ... }
  resource "aws_db_subnet_group" "rds_subnet_group" { ... }
        │
        ▼
modules/networking/outputs.tf
  output "rds_sg_id"             { value = aws_security_group.rds_sg.id }
  output "rds_subnet_group_name" { value = aws_db_subnet_group.rds_subnet_group.name }
        │
        ▼
terraform/main.tf
  module "database" { rds_sg_id             = module.networking.rds_sg_id
                      rds_subnet_group_name = module.networking.rds_subnet_group_name }
        │
        ▼
modules/database/main.tf
  aws_db_instance {
    vpc_security_group_ids = [var.rds_sg_id]
    db_subnet_group_name   = var.rds_subnet_group_name
  }
```

---

### Variable: `subnet_ids`, `ecs_sg_id`, `target_group_arn`, `alb_listener_arn`

Nacen en networking y viajan a compute para que ECS corra en la red correcta y se conecte al ALB.

```
modules/networking/main.tf
  data "aws_subnets" "default"
  resource "aws_security_group" "ecs_sg"
  resource "aws_lb_target_group" "api_tg"
  resource "aws_lb_listener" "api_listener"
        │
        ▼
modules/networking/outputs.tf
  output "subnet_ids"       { value = data.aws_subnets.default.ids }
  output "ecs_sg_id"        { value = aws_security_group.ecs_sg.id }
  output "target_group_arn" { value = aws_lb_target_group.api_tg.arn }
  output "alb_listener_arn" { value = aws_lb_listener.api_listener.arn }
        │
        ▼
terraform/main.tf
  module "compute" { subnet_ids       = module.networking.subnet_ids
                     ecs_sg_id        = module.networking.ecs_sg_id
                     target_group_arn = module.networking.target_group_arn
                     alb_listener_arn = module.networking.alb_listener_arn }
        │
        ▼
modules/compute/main.tf
  aws_ecs_service {
    network_configuration {
      subnets         = var.subnet_ids
      security_groups = [var.ecs_sg_id]
    }
    load_balancer {
      target_group_arn = var.target_group_arn
    }
  }
```

---

### Resumen visual de todos los flujos

```
variables.tf ──────────────────────────────────────────────────────────────────
  db_password, db_name, db_user, alert_threshold, project_name, environment
        │
        ▼
main.tf raíz ──────────────────────────────────────────────────────────────────
  distribuye a los 5 módulos según necesidad
        │
        ├──► networking → outputs: vpc_id, subnet_ids, sg_ids, alb_dns, tg_arn
        │         │
        │         ├──► database (rds_sg_id, rds_subnet_group_name)
        │         └──► compute  (subnet_ids, ecs_sg_id, target_group_arn)
        │
        ├──► storage → outputs: sensor_bucket_name, sensor_bucket_arn
        │         │
        │         ├──► compute (sensor_bucket_name, sensor_bucket_arn)
        │         └──► iot     (sensor_bucket_name)
        │
        ├──► database → outputs: sensor_table_name, db_host, db_name, db_user
        │         │
        │         ├──► compute (db_host, db_name, db_user)
        │         └──► iot     (sensor_table_name)
        │
        ├──► compute → outputs: iot_alert_lambda_arn, ecr_repo_url, alert_queue_url
        │         │
        │         └──► iot (iot_alert_lambda_arn)
        │
        └──► iot → genera certificados y mosquitto.conf en disco local
```
