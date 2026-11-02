variable "aws_region" {
  description = "Target AWS region for the migration landing zone"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project naming prefix for resources"
  type        = string
  default     = "streamflix-target"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "target-cloud"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for target AWS VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "List of AWS Availability Zones for Multi-AZ resilience"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (ALB / Ingress)"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets (ECS / Containers)"
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for isolated database subnets (RDS PostgreSQL)"
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24"]
}

variable "onprem_cidr" {
  description = "Simulated on-premises datacenter network CIDR on Azure"
  type        = string
  default     = "10.10.0.0/16"
}

variable "onprem_db_ip" {
  description = "Private IP of on-premises DB01 for replication"
  type        = string
  default     = "10.10.10.30/32"
}

variable "onprem_gateway_public_ip" {
  description = "Public static IP of on-premises HV01 host acting as IPsec edge router"
  type        = string
  default     = "135.119.24.110"
}

variable "tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default = {
    Project     = "Enterprise-Cloud-Migration-Lab"
    Environment = "Target-AWS"
    ManagedBy   = "Terraform"
    Stage       = "Stage-2"
  }
}
