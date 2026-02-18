variable "region" {
  type = string
  description = "Region"
}

variable "invoice_bucket_name" {
  type = string
  description = "bucket name for invoices"
}
variable "aws_ecs_cluster_name" {
  type = string
  description = "ECS cluster name"
}

variable "aws_ecs_service_name" {
  type = string
  description = "ECS service name"
}