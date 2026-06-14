# Plataforma IoT en AWS — Documentación Completa

## Índice
1. [Arquitectura](#1-arquitectura)
2. [Requisitos](#2-requisitos)
3. [Cómo Ejecutar](#3-cómo-ejecutar)
4. [Flujo de Datos](#4-flujo-de-datos)
5. [Estructura del Proyecto](#5-estructura-del-proyecto)
6. [Módulos Terraform](#6-módulos-terraform)
7. [Lambdas](#7-lambdas)
8. [API FastAPI](#8-api-fastapi)
9. [Sensores Locales](#9-sensores-locales)
10. [Permisos y Seguridad](#10-permisos-y-seguridad)
11. [Flujo de Variables Terraform](#11-flujo-de-variables-terraform)

---

## 1. Arquitectura

El sistema tiene dos entornos que trabajan juntos:

- **Local (Docker Compose):** sensores simulados que publican datos por MQTT a un broker Mosquitto. Mosquitto actúa como bridge y reenvía los datos a AWS IoT Core usando certificados TLS.
- **Nube (AWS):** IoT Core recibe los datos y los distribuye a múltiples destinos usando reglas SQL.

```
Local (Docker Compose)                    AWS (Terraform)
──────────────────────                    ─────────────────────────────────────────
sensor-temp-01    ─┐
                   ├─► Mosquitto ──TLS──► IoT Core ──► Regla 1 ──► DynamoDB (hot data)
sensor-humidity-01 ┘   (bridge)                     ──► Regla 2 ──► S3 (cold data)
                                                     ──► Regla 3 ──► Lambda alerta
                                                                          │
                                                                         SQS
                                                                          │
                                                                    Lambda CW ──► CloudWatch

                                          S3 ──► Lambda s3_to_postgres ──► PostgreSQL

                                          ECS (FastAPI) ──► DynamoDB / PostgreSQL
```

---

## 2. Requisitos

- **Terraform** instalado
- **Docker y Docker Compose** instalados
- **AWS CLI** configurado con credenciales del Learner Lab en `~/.aws/credentials`
- **Python + pip** (para empaquetar la Lambda con psycopg2)
- **bash** (para el script de build de la API)

### Configurar credenciales AWS

En el Learner Lab, hacer clic en **AWS Details** → copiar las credenciales y pegarlas en `~/.aws/credentials`:

```
[default]
aws_access_key_id     = ASIA...
aws_secret_access_key = abc123...
aws_session_token     = FwoGZXIv...
```

---

## 3. Cómo Ejecutar

### Despliegue completo (primera vez o después de `make clean`)

```bash
make aws-up    # prepara Lambda + crea ECR + sube imagen API + terraform apply
make local-up  # levanta Mosquitto y sensores locales
```

### Ver datos en tiempo real

```bash
make logs
```

### Destruir todo

```bash
make clean
```

### Comandos disponibles

| Comando | Qué hace |
|---|---|
| `make aws-up` | Despliega toda la infraestructura en AWS |
| `make aws-down` | Destruye la infraestructura en AWS |
| `make lambda-build` | Instala psycopg2 y prepara el zip de la Lambda |
| `make api-build` | Hace build y push de la imagen de la API a ECR |
| `make local-up` | Levanta Mosquitto y sensores con Docker Compose |
| `make local-down` | Para los contenedores locales |
| `make logs` | Ver logs en tiempo real |
| `make clean` | Destruye todo (AWS + local) y limpia archivos generados |

### Acceder a la API

Al final de `make aws-up`, Terraform imprime la URL:

```
api_url = "http://<alb-dns>.us-east-1.elb.amazonaws.com"
```

- **Swagger UI:** `http://<url>/docs`
- También se puede consultar con: `cd terraform && terraform output api_url`

---

## 4. Flujo de Datos

### Paso 1 — Sensor genera dato

Cada sensor Python genera un JSON cada N segundos y lo publica al tópico `lab/sensors/data`:

```json
{
  "device_id": "sensor-temp-01",
  "sensor_type": "temperature",
  "value": 37.5,
  "timestamp": "2026-06-06T04:00:00Z"
}
```

### Paso 2 — Mosquitto reenvía a IoT Core

Mosquitto está configurado como bridge. Recibe el mensaje localmente en el puerto 1883 y lo reenvía a AWS IoT Core en el puerto 8883 usando autenticación mTLS con certificados X.509.

### Paso 3 — IoT Core aplica las 3 reglas

| Regla | SQL | Acción |
|---|---|---|
| Regla 1 | `SELECT * FROM 'lab/sensors/data'` | `PUT_ITEM` en DynamoDB |
| Regla 2 | `SELECT * FROM 'lab/sensors/data'` | `PutObject` en S3 |
| Regla 3 | `SELECT * FROM 'lab/sensors/data' WHERE sensor_type = 'temperature' AND value > 35` | Invoca Lambda alerta |

### Paso 4 — Cadena de alertas (Regla 3)

```
IoT Core → Lambda iot_alert → SQS → Lambda sqs_to_cloudwatch → CloudWatch Logs
```

### Paso 5 — Histórico en PostgreSQL

```
S3 (nuevo archivo JSON) → Lambda s3_to_postgres → PostgreSQL (tabla sensor_history)
```

### Paso 6 — API REST

La API FastAPI corre en ECS y expone los datos:

| Método | Endpoint | Fuente | Descripción |
|---|---|---|---|
| GET | `/sensors` | DynamoDB | Lista todos los sensores |
| POST | `/sensors` | DynamoDB | Registra un nuevo sensor |
| GET | `/sensor/{id}/current` | DynamoDB | Último valor en tiempo real |
| GET | `/sensor/{id}/recent` | PostgreSQL | Últimos 10 eventos |
| GET | `/sensor/{id}/history` | PostgreSQL | Histórico completo |

---

## 5. Estructura del Proyecto

```
7_iot_s3_dynamo_athena/
├── .gitignore
├── .gitattributes
├── Makefile                          ← comandos de ejecución
├── docker-compose.yml                ← sensores locales
├── python_device/
│   ├── Dockerfile
│   └── sensor_simulator.py           ← código del sensor (temp, humedad, oxígeno)
├── edge_gateway/
│   ├── Dockerfile
│   ├── certs/                        ← certificados IoT (generados por Terraform, ignorados por git)
│   └── mosquitto.conf                ← config del bridge (generada por Terraform, ignorada por git)
├── api/
│   ├── main.py                       ← API FastAPI
│   ├── Dockerfile
│   ├── requirements.txt
│   └── build_and_deploy.sh           ← build y push de imagen a ECR
├── lambdas/
│   ├── s3_to_postgres/
│   │   ├── lambda_function.py        ← S3 → PostgreSQL
│   │   ├── requirements.txt          ← psycopg2-binary
│   │   └── package/                  ← dependencias instaladas (ignorado por git)
│   ├── iot_alert/
│   │   └── lambda_function.py        ← IoT Rule 3 → SQS
│   └── sqs_to_cloudwatch/
│       └── lambda_function.py        ← SQS → CloudWatch
└── terraform/
    ├── main.tf                       ← módulo raíz, conecta todos los módulos
    ├── variables.tf                  ← variables globales (project_name, db_password, etc.)
    ├── outputs.tf                    ← outputs (api_url, postgres_host, etc.)
    ├── data.tf                       ← data sources (LabRole, IoT endpoint, Root CA)
    └── modules/
        ├── networking/               ← VPC, Security Groups, ALB, DB Subnet Group
        ├── storage/                  ← S3 buckets
        ├── database/                 ← DynamoDB + RDS PostgreSQL
        ├── compute/                  ← Lambdas + SQS + ECR + ECS
        └── iot/                      ← IoT Thing, certificados, 3 reglas
```

---

## 6. Módulos Terraform

### networking

Gestiona todos los recursos de red. Los demás módulos reciben sus IDs como variables.

| Recurso | Descripción |
|---|---|
| `data.aws_vpc.default` | Lee la VPC por defecto de la cuenta |
| `data.aws_subnets.default` | Obtiene las subnets de la VPC |
| `aws_security_group.alb_sg` | Firewall del ALB: acepta HTTP (80) desde internet |
| `aws_security_group.ecs_sg` | Firewall de ECS: acepta puerto 8000 solo desde el ALB |
| `aws_security_group.rds_sg` | Firewall de RDS: acepta PostgreSQL (5432) desde la VPC |
| `aws_db_subnet_group.rds_subnet_group` | Grupo de subnets para RDS (requiere mínimo 2 AZs) |
| `aws_lb.api_alb` | Application Load Balancer público |
| `aws_lb_target_group.api_tg` | Lista de destinos del ALB (IPs de tareas ECS) |
| `aws_lb_listener.api_listener` | Escucha en puerto 80, reenvía al target group |

### storage

| Recurso | Descripción |
|---|---|
| `aws_s3_bucket.sensor_data` | Bucket de datos de sensores (particionado por fecha) |
| `aws_s3_bucket.athena_results` | Bucket para resultados de Amazon Athena |

### database

| Recurso | Descripción |
|---|---|
| `aws_dynamodb_table.sensor_data` | Tabla DynamoDB — solo `device_id` como PK, sobrescribe el último valor |
| `aws_db_instance.sensor_history` | RDS PostgreSQL 15 — guarda el histórico completo |

### compute

| Recurso | Descripción |
|---|---|
| `null_resource.install_s3_to_postgres_deps` | Instala psycopg2 en `package/` antes de zipear |
| `data.archive_file.s3_to_postgres_zip` | Crea el zip de la Lambda desde `package/` |
| `aws_lambda_function.s3_to_postgres` | Lambda que lee S3 e inserta en PostgreSQL |
| `aws_s3_bucket_notification.sensor_trigger` | Trigger: nuevo objeto en S3 → Lambda |
| `aws_sqs_queue.alert_queue` | Cola SQS para mensajes de alerta (Standard Queue) |
| `aws_lambda_function.iot_alert` | Lambda que recibe alerta de IoT y manda a SQS |
| `aws_lambda_function.sqs_to_cloudwatch` | Lambda que consume SQS y escribe log de urgencia |
| `aws_lambda_event_source_mapping.alert_sqs_trigger` | Trigger: mensaje en SQS → Lambda |
| `aws_ecr_repository.api_repo` | Repositorio ECR para la imagen de la API |
| `aws_ecs_cluster.api_cluster` | Cluster ECS (Fargate) |
| `aws_ecs_task_definition.api_task` | Receta del contenedor: imagen, CPU, memoria, variables de entorno |
| `aws_ecs_service.api_service` | Supervisor: mantiene 1 tarea corriendo, conectada al ALB |

### iot

| Recurso | Descripción |
|---|---|
| `aws_iot_thing.edge_gateway` | Representación virtual del Edge Gateway en AWS |
| `aws_iot_certificate.cert` | Certificados X.509 para autenticación mTLS |
| `aws_iot_policy.sensor_policy` | Política: solo puede conectarse y publicar en `lab/sensors/*` |
| `local_file.certificate_pem` | Descarga el certificado a `edge_gateway/certs/` |
| `local_file.private_key` | Descarga la clave privada a `edge_gateway/certs/` |
| `local_file.mosquitto_conf` | Genera `mosquitto.conf` con el endpoint de IoT inyectado |
| `aws_iot_topic_rule.dynamodb_rule` | Regla 1: todo mensaje → DynamoDB |
| `aws_iot_topic_rule.s3_rule` | Regla 2: todo mensaje → S3 |
| `aws_iot_topic_rule.alert_rule` | Regla 3: temperatura > 35°C → Lambda alerta |

---

## 7. Lambdas

### s3_to_postgres

**Trigger:** `s3:ObjectCreated:*` en el bucket de sensores.

**Flujo:**
1. S3 notifica que llegó un nuevo archivo JSON
2. La Lambda decodifica la key (URL-encoded → texto normal con `unquote_plus`)
3. Lee el JSON con `s3_client.get_object()`
4. Crea la tabla `sensor_history` en PostgreSQL si no existe (`ensure_table`)
5. Inserta el registro con `INSERT INTO sensor_history`

**Dependencias:** `psycopg2-binary` — empaquetada en `package/` con `make lambda-build`.

### iot_alert

**Trigger:** Regla 3 de IoT Core (temperatura > 35°C).

**Flujo:**
1. IoT Core invoca la Lambda con el payload del sensor como `event`
2. Construye un mensaje con nivel "URGENTE"
3. Envía el mensaje a la cola SQS con `sqs_client.send_message()`

### sqs_to_cloudwatch

**Trigger:** mensajes en la cola SQS (lotes de hasta 10).

**Flujo:**
1. Lambda procesa cada mensaje del lote
2. Extrae los campos del payload
3. Escribe un log crítico con `logger.critical()` → aparece en CloudWatch Logs

**Nota:** No necesita configuración extra de CloudWatch — Lambda escribe ahí automáticamente.

---

## 8. API FastAPI

### Conexiones

**DynamoDB** — usa `boto3`. Se autentica con el IAM role de la tarea ECS (no necesita usuario/contraseña):
```python
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMO_TABLE)
```

**PostgreSQL** — usa `psycopg2`. Necesita credenciales que llegan por variables de entorno inyectadas por ECS:
```python
psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD)
```

### Endpoints

| Método | Ruta | Fuente | Descripción |
|---|---|---|---|
| GET | `/` | — | Mensaje de bienvenida |
| GET | `/health` | — | Health check del ALB |
| GET | `/sensors` | DynamoDB | Lista todos los sensores registrados |
| POST | `/sensors` | DynamoDB | Registra un sensor manualmente |
| GET | `/sensor/{id}/current` | DynamoDB | Último valor (Device Twin) |
| GET | `/sensor/{id}/recent` | PostgreSQL | Últimos 10 eventos históricos |
| GET | `/sensor/{id}/history` | PostgreSQL | Histórico completo |

### Despliegue

La imagen se construye y sube a ECR con `make api-build` (o automáticamente dentro de `make aws-up`). ECS descarga la imagen de ECR y la corre en Fargate.

---

## 9. Sensores Locales

### sensor_simulator.py

Script Python configurable por variables de entorno:

| Variable | Descripción | Default |
|---|---|---|
| `MQTT_HOST` | Host del broker MQTT | `localhost` |
| `MQTT_PORT` | Puerto del broker | `1883` |
| `CLIENT_ID` | ID del dispositivo (`device_id` en DynamoDB) | Aleatorio |
| `SENSOR_TYPE` | Tipo de sensor | `temperature` |
| `INTERVAL` | Segundos entre publicaciones | `5` |

### Tipos de sensor soportados

| Tipo | Rango |
|---|---|
| `temperature` | 20.0 – 40.0 °C |
| `humidity` | 40.0 – 60.0 % |
| `oxygen` | 19.5 – 23.5 % |

### Agregar nuevo sensor (sustentación)

1. Descomentar el bloque `sensor_oxygen_01` en `docker-compose.yml`
2. Correr `make local-up`
3. El sensor empieza a publicar → IoT Core lo registra en DynamoDB automáticamente
4. Verificar con `GET /sensors` y `GET /sensor/sensor-oxygen-01/current`

---

## 10. Permisos y Seguridad

### IAM — LabRole

Todos los componentes usan el `LabRole` preexistente del Learner Lab.

### Permisos de invocación (aws_lambda_permission)

Para que un servicio AWS pueda invocar una Lambda, se necesita un permiso explícito:

| Quién invoca | Lambda | Tipo de trigger |
|---|---|---|
| `s3.amazonaws.com` | s3_to_postgres | Push — S3 notifica a Lambda |
| `iot.amazonaws.com` | iot_alert | Push — IoT Core llama a Lambda |
| SQS | sqs_to_cloudwatch | Pull — Lambda hace polling a SQS (usa `event_source_mapping`) |

### Security Groups

```
Internet ──80──► ALB SG ──8000──► ECS SG
                                      │
         VPC ──5432──► RDS SG ◄───────┘
                          ▲
                     Lambdas (también en la VPC)
```

### Política de IoT Core

El certificado X.509 del Edge Gateway solo puede:
- Conectarse con `client_id = edge-gateway-01-lab`
- Publicar y suscribirse al tópico `lab/sensors/*`

---

## 11. Flujo de Variables Terraform

Cada módulo es independiente. El `main.tf` raíz actúa como intermediario que recibe valores y los distribuye.

### db_password

```
terraform/variables.tf (default = "Sensor2024!")
    │
    ▼
terraform/main.tf
    ├──► module "database" { db_password = var.db_password }
    └──► module "compute"  { db_password = var.db_password }
              │                               │
              ▼                               ▼
    RDS PostgreSQL                   ECS task_definition
    (contraseña del usuario)         { name="DB_PASSWORD", value=var.db_password }
                                              │
                                              ▼
                                     api/main.py y lambdas/
                                     os.environ.get("DB_PASSWORD")
```

### iot_alert_lambda_arn

```
modules/compute/main.tf
  resource "aws_lambda_function" "iot_alert" → ARN asignado por AWS
      │
modules/compute/outputs.tf
  output "iot_alert_lambda_arn" { value = aws_lambda_function.iot_alert.arn }
      │
terraform/main.tf
  module "iot" { iot_alert_lambda_arn = module.compute.iot_alert_lambda_arn }
      │
modules/iot/main.tf
  aws_iot_topic_rule "alert_rule" { lambda { function_arn = var.iot_alert_lambda_arn } }
```

### Resumen de dependencias entre módulos

```
networking → outputs: vpc_id, subnet_ids, sg_ids, alb_dns, tg_arn, rds_sg_id
    │
    ├──► database (rds_sg_id, rds_subnet_group_name)
    │       └──► outputs: sensor_table_name, db_host, db_name, db_user
    │                │
    │                └──► compute + iot
    │
    ├──► compute (subnet_ids, ecs_sg_id, target_group_arn)
    │       └──► outputs: iot_alert_lambda_arn, ecr_repo_url, alert_queue_url
    │                │
    │                └──► iot (iot_alert_lambda_arn)
    │
storage → outputs: sensor_bucket_name, sensor_bucket_arn
    │
    ├──► compute (sensor_bucket_name, sensor_bucket_arn)
    └──► iot (sensor_bucket_name)
```
