.PHONY: aws-up aws-down api-build lambda-build local-up local-down logs clean

# --- Comandos AWS (Terraform) ---

aws-up: lambda-build
	mkdir -p edge_gateway/certs
	cd terraform && terraform init && terraform apply -target=module.compute.aws_ecr_repository.api_repo -auto-approve
	bash api/build_and_deploy.sh
	cd terraform && terraform apply -auto-approve

aws-down:
	cd terraform && terraform destroy -auto-approve

# --- Preparar Lambda con dependencias ---

lambda-build:
	pip install -r lambdas/s3_to_postgres/requirements.txt -t lambdas/s3_to_postgres/package/ --upgrade --quiet
	cp lambdas/s3_to_postgres/lambda_function.py lambdas/s3_to_postgres/package/lambda_function.py

# --- Build y Push de la imagen de la API ---

api-build:
	bash api/build_and_deploy.sh

# --- Comandos Locales (Docker Compose) ---

local-up:
	docker compose up -d --build

local-down:
	docker compose down

logs:
	docker compose logs -f

# --- Limpieza Total ---

clean: local-down aws-down
	rm -rf edge_gateway/certs/*
	rm -f edge_gateway/mosquitto.conf
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl terraform/terraform.tfstate terraform/terraform.tfstate.backup
