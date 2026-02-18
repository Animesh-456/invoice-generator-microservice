terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }


  backend "s3" {
    bucket = "tfremotestate-invoice-generator"
    key = "state"
    region = var.region
    dynamodb_table = "tfremotestate-invoice-generator"
  }
}

provider "aws" {
  region = var.region
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
      ENVIRONMENT   = "production"
      LOG_LEVEL     = "warn"
      SQS_QUEUE_URL = aws_sqs_queue.example.url
    }
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


resource "aws_s3_bucket" "example" {
  bucket = var.invoice_bucket_name
  region = var.region

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}