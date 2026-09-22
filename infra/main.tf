terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }


  backend "s3" {
    bucket = "tfremotestate-invoice-generator"
    key    = "state"
    region = "ap-south-1"
    //dynamodb_table = "tfremotestate-invoice-generator"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "tfremotestate-invoice-generator"
}

resource "aws_s3_bucket_versioning" "example" {
  bucket = "tfremotestate-invoice-generator"
  versioning_configuration {
    status = "Enabled"
  }
}


# ###########################################
# # Lambda Function for sending reuest to SQS
# ###########################################

# SQS Queue
resource "aws_sqs_queue" "example" {
  name                        = "example-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}


# IAM role for Lambda execution (Trust Policy)
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}


# IAM role for SQS access
data "aws_iam_policy_document" "lambda_sqs_policy" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
      "sqs:GetMessage"
    ]

    resources = [
      aws_sqs_queue.example.arn
    ]
  }
}

# Creating IAM role for Lambda
resource "aws_iam_role" "example" {
  name               = "lambda_execution_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Creating IAM policy for Lambda to access SQS
resource "aws_iam_policy" "lambda_sqs_policy" {
  name   = "lambda-send-message-to-sqs"
  policy = data.aws_iam_policy_document.lambda_sqs_policy.json
}


# Ataching the policy to the Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_sqs_attach" {
  role       = aws_iam_role.example.name
  policy_arn = aws_iam_policy.lambda_sqs_policy.arn
}


# Attaching AWSLambdaBasicExecutionRole policy to the Lambda role
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.example.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.example.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}


# Package the Lambda function code
data "archive_file" "example" {
  type        = "zip"
  source_dir  = "../lambda"
  output_path = "../lambda/function.zip"
}


# Lambda function
resource "aws_lambda_function" "example" {
  filename      = data.archive_file.example.output_path
  function_name = "example_lambda_function"
  role          = aws_iam_role.example.arn
  handler       = "index.handler"
  code_sha256   = data.archive_file.example.output_base64sha256

  runtime = "nodejs20.x"

  environment {
    variables = {
      ENVIRONMENT        = "production"
      LOG_LEVEL          = "warn"
      SQS_QUEUE_URL      = aws_sqs_queue.example.url
      RDS_PROXY_ENDPOINT = aws_db_proxy.invoice_proxy.endpoint
      DB_NAME            = var.db_name
      DB_USER            = var.db_user
      DB_PASSWORD        = var.db_password
    }
  }

  vpc_config {
    subnet_ids         = [data.aws_subnet.privatesubnet.id]
    security_group_ids = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Environment = "production"
    Application = "example"
  }
}


# ###############################
# HTTP API Gateway --> Lambda
# ###############################
resource "aws_apigatewayv2_api" "http_api" {
  name          = "lambda-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.example.invoke_arn
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.example.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ##############################################
# ECS Service for invoice generator application
################################################

data "aws_vpc" "vpc" {
  default = true
}

# Fetch public and private subnets
data "aws_subnets" "public_subnets" {
  filter {
    name   = "tag:Name"
    values = ["public-subnet-1", "public-subnet-2"]
  }
}

data "aws_subnet" "privatesubnet" {
  filter {
    name   = "tag:Name"
    values = ["private-subnet-1"]
  }
}


data "aws_internet_gateway" "igw" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
}

# Create Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "nat-eip"
  }
  depends_on = [data.aws_internet_gateway.igw]
}


# Creating NAT gateway

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = data.aws_subnets.public_subnets.ids[0]

  tags = {
    Name = "gw NAT"
  }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  # on the Internet Gateway for the VPC.
  depends_on = [data.aws_internet_gateway.igw]
}

#  Fetch private route table associated with private subnets

data "aws_route_table" "selected" {
  filter {
    name   = "tag:Name"
    values = ["private-rtb"]
  }
}

resource "aws_route" "route" {
  route_table_id         = data.aws_route_table.selected.id
  nat_gateway_id         = aws_nat_gateway.nat.id
  destination_cidr_block = "0.0.0.0/0"
}




# creating IAM asusme role for ECS task execution

data "aws_iam_policy_document" "iam_policy_assumerole_ecs" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }

}

resource "aws_iam_role" "ecsTaskExecutionCustomRole" {
  name               = "ecsTaskExecutionCustomRole"
  assume_role_policy = data.aws_iam_policy_document.iam_policy_assumerole_ecs.json
}

# Attach AWS Managed Policy for ECS Task Execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed_policy" {
  role       = aws_iam_role.ecsTaskExecutionCustomRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# creating a custom policy for s3 access and sqs access 
data "aws_iam_policy_document" "ecsCustomRole" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "ses:SendEmail",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "custompolicy" {
  name   = "ecsTaskexeutionCustomPolicy"
  policy = data.aws_iam_policy_document.ecsCustomRole.json
}

# Attach the custom policy to the IAM role resource 
resource "aws_iam_role_policy_attachment" "attach_custom_policy" {
  role       = aws_iam_role.ecsTaskExecutionCustomRole.name
  policy_arn = aws_iam_policy.custompolicy.arn
}



# Simply specify the family to find the latest ACTIVE revision in that family.
resource "aws_ecs_cluster" "testCluster" {
  name = var.aws_ecs_cluster_name
}

resource "aws_ecs_task_definition" "ts" {
  family = "invoice-generator"

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  task_role_arn = aws_iam_role.ecsTaskExecutionCustomRole.arn

  container_definitions = jsonencode([
    {
      name  = "invoice-generator"
      image = "docker.io/anim45/invoice-generator:latest"
      environment = [
        {
          name  = "INVOICE_BUCKET"
          value = var.invoice_bucket_name
        },
        {
          name  = "SQS_QUEUE_URL"
          value = aws_sqs_queue.example.url
        },
        {
          name  = "RDS_PROXY_ENDPOINT"
          value = aws_db_proxy.invoice_proxy.endpoint
        },
        {
          name  = "DB_NAME"
          value = var.db_name
        },
        {
          name  = "DB_USER"
          value = var.db_user
        },
        {
          name  = "DB_PASSWORD"
          value = var.db_password
        },
        {
          name  = "SES_FROM_EMAIL"
          value = var.ses_from_email
        },
        {
          name  = "INVOICE_URL_TTL_SECONDS"
          value = tostring(var.invoice_url_ttl_seconds)
        }
      ]
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 80 # Adjust to your app's port
          protocol      = "tcp"
        }
      ]
    }
  ])
}

resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-tasks-sg"
  description = "Allow inbound traffic to ECS tasks"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    from_port   = 4000 # Adjust to your app's port
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Adjust as needed for security
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "ts" {
  name          = var.aws_ecs_service_name
  cluster       = aws_ecs_cluster.testCluster.id
  desired_count = 1

  # Track the latest ACTIVE revision
  task_definition = aws_ecs_task_definition.ts.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [data.aws_subnet.privatesubnet.id] # Replace with your subnet IDs
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}


resource "aws_s3_bucket" "invoice_bucket" {
  bucket = var.invoice_bucket_name

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_public_access_block" "invoice_bucket_access_block" {
  bucket = aws_s3_bucket.invoice_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "invoice_bucket_versioning" {
  bucket = aws_s3_bucket.invoice_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}


resource "aws_s3_bucket_server_side_encryption_configuration" "invoice_bucket_encryption" {
  bucket = aws_s3_bucket.invoice_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "invoice_bucket_enforce_encryption" {
  bucket = aws_s3_bucket.invoice_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedObjectUploads"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.invoice_bucket.arn}/*"
      Condition = {
        StringNotEquals = {
          "s3:x-amz-server-side-encryption" = "AES256"
        }
      }
    }]
  })
}



###################################################################
###################################################################
###Upgrade to RDS with Proxy and SES for sending emails##############
####################################################################
####################################################################



############################################
# RDS with proxy endpoint and SES###########
############################################
resource "aws_security_group" "db_sg" {
  name        = "invoice-db-sg"
  description = "Security group for PostgreSQL RDS and Proxy"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # ingress {
  #   from_port   = 5432
  #   to_port     = 5432
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"] # Minimal config for testing/access
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "postgres" {
  identifier             = "invoice-db"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_user
  password               = var.db_password
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "rds-proxy-credentials-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_secretsmanager_secret_version" "rds_credentials_version" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.db_user
    password = var.db_password
  })
}

data "aws_iam_policy_document" "rds_proxy_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "rds_proxy_secrets_access" {
  statement {
    effect = "Allow"

    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.rds_credentials.arn]
  }
}

resource "aws_iam_role" "rds_proxy_role" {
  name               = "rds_proxy_role"
  assume_role_policy = data.aws_iam_policy_document.rds_proxy_assume_role.json
}

resource "aws_iam_role_policy" "rds_proxy_policy" {
  name   = "rds_proxy_policy"
  role   = aws_iam_role.rds_proxy_role.name
  policy = data.aws_iam_policy_document.rds_proxy_secrets_access.json
}

resource "aws_db_proxy" "invoice_proxy" {
  name                   = "invoice-db-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy_role.arn
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  vpc_subnet_ids         = data.aws_subnets.public_subnets.ids

  auth {
    auth_scheme = "SECRETS"
    description = "RDS Proxy Auth"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.rds_credentials.arn
  }
}

resource "aws_db_proxy_default_target_group" "invoice_proxy_tg" {
  db_proxy_name = aws_db_proxy.invoice_proxy.name
}

resource "aws_db_proxy_target" "invoice_proxy_target" {
  db_instance_identifier = aws_db_instance.postgres.identifier
  db_proxy_name          = aws_db_proxy.invoice_proxy.name
  target_group_name      = aws_db_proxy_default_target_group.invoice_proxy_tg.name
}

resource "aws_ses_email_identity" "invoice_email" {
  email = var.ses_from_email
}