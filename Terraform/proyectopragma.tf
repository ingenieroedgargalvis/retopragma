terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "PruebaPragma"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# --- S3: zona raw de los CSV ---

resource "aws_s3_bucket" "pruebapragma" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "pruebapragma" {
  bucket = aws_s3_bucket.pruebapragma.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pruebapragma" {
  bucket = aws_s3_bucket.pruebapragma.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pruebapragma" {
  bucket = aws_s3_bucket.pruebapragma.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM: rol de ejecucion de la Lambda ---

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline_role" {
  name               = "pruebapragma-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.pipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lectura de los CSV, acotada al bucket del proyecto.
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.pruebapragma.arn]
  }

  statement {
    sid       = "GetObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.pruebapragma.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_read" {
  name        = "pruebapragma-s3-read"
  description = "Permite leer los CSV del bucket del proyecto."
  policy      = data.aws_iam_policy_document.s3_read.json
}

resource "aws_iam_role_policy_attachment" "pipeline_s3_read" {
  role       = aws_iam_role.pipeline_role.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# Necesario para que la Lambda cree ENIs y corra dentro de la VPC.
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.pipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# --- Red: se reutiliza la VPC default ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Security Groups ---

resource "aws_security_group" "ec2" {
  name        = "pruebapragma-ec2-sg"
  description = "SG para la EC2: acceso SSH entrante."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    # En produccion conviene restringir a la IP del operador en lugar de 0.0.0.0/0.
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "lambda" {
  name        = "pruebapragma-lambda-sg"
  description = "SG para la Lambda del pipeline."
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS solo acepta Postgres desde la EC2 y la Lambda.
resource "aws_security_group" "rds" {
  name        = "pruebapragma-rds-sg"
  description = "SG para RDS: Postgres solo desde la EC2 y la Lambda."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres desde la EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  ingress {
    description     = "Postgres desde la Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- VPC Endpoints ---
# La VPC default no tiene NAT, asi que la Lambda alcanza Secrets Manager y S3
# por endpoints en lugar de salir a internet.

data "aws_region" "current" {}

data "aws_route_tables" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_security_group" "vpce" {
  name        = "pruebapragma-vpce-sg"
  description = "SG para los interface VPC endpoints: HTTPS desde la Lambda."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS desde la Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids
}

# --- EC2: bastion para el tunel SSH ---

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "ec2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # Solo asocia key pair si se proporciono su nombre.
  key_name = var.ec2_key_name != "" ? var.ec2_key_name : null

  tags = {
    Name = "pruebapragma-ec2"
  }
}

# --- RDS PostgreSQL (Free Tier) ---

resource "aws_db_subnet_group" "rds" {
  name       = "pruebapragma-rds-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier     = "pruebapragma-postgres"
  engine         = "postgres"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false

  backup_retention_period = 0
  skip_final_snapshot     = true
}

# --- Secrets Manager: credencial de la BD ---

resource "aws_secretsmanager_secret" "db" {
  name                    = "pruebapragma-db-credentials"
  description             = "Credenciales de la BD RDS para la Lambda del pipeline."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

data "aws_iam_policy_document" "secrets_read" {
  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_policy" "secrets_read" {
  name        = "pruebapragma-secrets-read"
  description = "Permite leer el secreto de la BD."
  policy      = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_role_policy_attachment" "pipeline_secrets_read" {
  role       = aws_iam_role.pipeline_role.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

# --- Lambda del pipeline ---

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/lambda_function.py"
  output_path = "${path.module}/build/lambda_function.zip"
}

# Layer con psycopg2 para Linux x86_64. Se construye antes con build_layer.ps1.
data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/layer_build"
  output_path = "${path.module}/build/psycopg2_layer.zip"
}

resource "aws_lambda_layer_version" "psycopg2" {
  layer_name          = "pruebapragma-psycopg2"
  filename            = data.archive_file.layer_zip.output_path
  source_code_hash    = data.archive_file.layer_zip.output_base64sha256
  compatible_runtimes = ["python3.9"]
  description         = "psycopg2-binary para Linux x86_64 (runtime python3.9)."
}

resource "aws_lambda_function" "pipeline" {
  function_name = "pruebapragma-pipeline"
  role          = aws_iam_role.pipeline_role.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.9"
  timeout       = 120
  memory_size   = 256

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # Usa la layer propia salvo que se indique un ARN externo.
  layers = var.psycopg2_layer_arn != "" ? [var.psycopg2_layer_arn] : [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET     = aws_s3_bucket.pruebapragma.id
      S3_PREFIX     = ""
      DB_HOST       = aws_db_instance.postgres.address
      DB_PORT       = "5432"
      DB_NAME       = var.db_name
      DB_SECRET_ARN = aws_secretsmanager_secret.db.arn
    }
  }
}

# --- Outputs ---

output "s3_bucket_name" {
  value = aws_s3_bucket.pruebapragma.id
}

output "s3_bucket_arn" {
  value = aws_s3_bucket.pruebapragma.arn
}

output "pipeline_role_arn" {
  value = aws_iam_role.pipeline_role.arn
}

output "ec2_public_ip" {
  description = "IP publica de la EC2 (para el tunel SSH)."
  value       = aws_instance.ec2.public_ip
}

output "rds_endpoint" {
  description = "Endpoint de la base de datos RDS."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_db_name" {
  value = aws_db_instance.postgres.db_name
}

output "lambda_function_name" {
  value = aws_lambda_function.pipeline.function_name
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}
