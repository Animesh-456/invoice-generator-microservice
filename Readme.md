# Invoice Generator

A cloud-native invoice generation system built on AWS, using a serverless API frontend, SQS-based message queuing, and a containerized ECS Fargate worker to process and store invoices in S3.

---

## Architecture Overview

```
Client
  │
  ▼
API Gateway (HTTP API)
  │
  ▼
Lambda Function  ──────► SQS FIFO Queue
                               │
                               ▼
                        ECS Fargate Task (invoice-generator container)
                               │
                               ▼
                          S3 Bucket (invoice storage)
```

### Components

| Component | Description |
|-----------|-------------|
| **API Gateway (HTTP)** | Public HTTP endpoint that routes all requests to the Lambda function |
| **Lambda Function** | Node.js 20.x handler that receives requests and dispatches jobs to SQS |
| **SQS FIFO Queue** | Ordered, deduplicated message queue that buffers invoice generation jobs |
| **ECS Fargate Service** | Long-running containerized worker that consumes SQS messages and generates invoices |
| **S3 Bucket** | Stores the generated invoice files |
| **NAT Gateway** | Provides internet access for the ECS task running in a private subnet |

---

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- AWS CLI configured with appropriate credentials
- An existing AWS VPC with:
  - Two public subnets tagged `public-subnet-1` and `public-subnet-2`
  - One private subnet tagged `private-subnet-1`
  - A private route table tagged `private-rtb`
  - An Internet Gateway attached to the VPC
- An S3 bucket and DynamoDB table for Terraform remote state:
  - S3 bucket: `tfremotestate-invoice-generator`
  - DynamoDB table: `tfremotestate-invoice-generator`

---

## Configuration

### Variables

Before deploying, set the following Terraform variables (e.g. in a `terraform.tfvars` file):

```hcl
region               = "ap-south-1"
aws_ecs_cluster_name = "invoice-cluster"
aws_ecs_service_name = "invoice-service"
invoice_bucket_name  = "my-invoices-bucket"
```

| Variable | Description |
|----------|-------------|
| `region` | AWS region to deploy into |
| `aws_ecs_cluster_name` | Name for the ECS cluster |
| `aws_ecs_service_name` | Name for the ECS service |
| `invoice_bucket_name` | S3 bucket name for storing generated invoices |

---

## Deployment

```bash
# 1. Clone the repository
git clone <repo-url>
cd <repo-directory>/terraform

# 2. Initialise Terraform (connects to remote state backend)
terraform init

# 3. Preview the infrastructure plan
terraform plan

# 4. Apply the changes
terraform apply
```

After a successful apply, Terraform will output your API Gateway endpoint URL. Use this to send invoice generation requests.

---

## Project Structure

```
.
├── terraform/
│   └── main.tf          # All infrastructure definitions
└── lambda/
    └── index.js          # Lambda handler (entry point: index.handler)
```

The Lambda source directory (`../lambda`) is automatically zipped and deployed by Terraform on each `apply`.

---

## How It Works

1. A client sends an HTTP request to the **API Gateway** endpoint.
2. API Gateway proxies the request to the **Lambda function**.
3. The Lambda function validates the request and places a message onto the **SQS FIFO queue** (with content-based deduplication enabled).
4. The **ECS Fargate task** (running `docker.io/anim45/invoice-generator:latest`) polls the SQS queue, picks up the job, generates the invoice, and uploads the result to the **S3 bucket**.

---

## IAM Permissions

### Lambda Execution Role
- `AWSLambdaBasicExecutionRole` — CloudWatch logging
- `sqs:SendMessage`, `sqs:GetMessage` — SQS queue access

### ECS Task Role
- `AmazonECSTaskExecutionRolePolicy` — ECS task execution
- `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` — Invoice storage
- `sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` — Queue access

---

## Networking

The ECS Fargate task runs in a **private subnet** with no direct internet access. A **NAT Gateway** (with an Elastic IP) in the public subnet provides outbound internet connectivity for the container (e.g. to pull images or reach external APIs).

The ECS security group allows inbound TCP traffic on port **4000** and all outbound traffic.

---

## Environment Variables

### Lambda
| Variable | Value |
|----------|-------|
| `ENVIRONMENT` | `production` |
| `LOG_LEVEL` | `warn` |
| `SQS_QUEUE_URL` | Injected automatically from Terraform |

### ECS Container
| Variable | Value |
|----------|-------|
| `INVOICE_BUCKET` | Set via `invoice_bucket_name` variable |
| `SQS_QUEUE_URL` | Injected automatically from Terraform |

---

## Teardown

To destroy all provisioned resources:

```bash
terraform destroy
```


## Deliverables for advancing this project

1. It will check if RDS contains the order_id

if yes then check the status - mail_sent, queued, or procesing then accordingly send to SQS do not create any record in RDS 
if no then create a record in RDS and send to SQS

2. When worker pull job from SQS it will 
check if the file exists in S3  - if yes then send mail and update RDS with mail_sent
update RDS with processing
generate pdf and upload to S3 then update RDS with generated then send mail via SES then update the status to mail_sent

Three status - queued, processing, generated, mail_sent

> ⚠️ This will permanently delete the S3 bucket and all invoices stored within it. Back up any important files before destroying.

---