variable "region" {
  type        = string
  description = "Region"
}

variable "invoice_bucket_name" {
  type        = string
  description = "bucket name for invoices"
}
variable "aws_ecs_cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "aws_ecs_service_name" {
  type        = string
  description = "ECS service name"
}

variable "db_name" {
  type        = string
  description = "PostgreSQL database name"
}

variable "db_user" {
  type        = string
  description = "PostgreSQL username"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL password"
}

variable "ses_from_email" {
  type        = string
  description = "Verified SES sender email address"
}

variable "invoice_url_ttl_seconds" {
  type        = number
  default     = 3600
  description = "Lifetime of the presigned invoice download URL"
}