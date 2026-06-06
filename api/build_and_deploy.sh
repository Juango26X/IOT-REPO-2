#!/bin/bash
# Construye la imagen Docker de la API y la sube a ECR.
# El repositorio ECR debe existir previamente (lo crea Terraform).
# Uso: bash api/build_and_deploy.sh   (desde la raíz del proyecto)

set -e

REGION="us-east-1"
REPO_NAME="iot-sensor-api"

echo "=== 1. Obteniendo Account ID ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID"

REPO_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

echo "=== 2. Login a ECR ==="
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "=== 3. Build de la imagen Docker ==="
docker build -t $REPO_NAME ./api

echo "=== 4. Tag y Push al ECR ==="
docker tag $REPO_NAME:latest $REPO_URI:latest
docker push $REPO_URI:latest

echo ""
echo "=== Imagen subida: $REPO_URI:latest ==="
