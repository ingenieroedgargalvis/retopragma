variable "aws_region" {
  description = "Region de AWS donde se despliegan los recursos."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno (dev, test, prod) usado para tags."
  type        = string
  default     = "dev"
}

variable "bucket_name" {
  description = "Nombre global y unico del bucket S3 de almacenamiento de proposito general."
  type        = string
  default     = "pruebapragma01"
}

variable "ec2_instance_type" {
  description = "Tipo de instancia EC2 (Free Tier: t2.micro / t3.micro)."
  type        = string
  default     = "t3.micro"
}

variable "ec2_key_name" {
  description = "Nombre de un Key Pair EXISTENTE en la cuenta para acceso SSH a la EC2. Dejar vacio para no asociar ninguno."
  type        = string
  default     = ""
}

variable "db_instance_class" {
  description = "Clase de instancia RDS (Free Tier: db.t3.micro)."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos inicial en PostgreSQL."
  type        = string
  default     = "pruebapragma"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos."
  type        = string
  default     = "pragma_admin"
}

variable "db_password" {
  description = "Password del usuario administrador de la BD. Pasar por variable de entorno TF_VAR_db_password (no hardcodear)."
  type        = string
  sensitive   = true
}

variable "psycopg2_layer_arn" {
  description = "OPCIONAL. ARN de una Lambda Layer externa de psycopg2. Si se deja vacio, se usa la layer propia construida con build_layer.ps1 (recomendado)."
  type        = string
  default     = ""
}
