# Target VPC Definition
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
    Tier = "Foundation"
  }
}

# 1. Public Subnets (For Load Balancer & Ingress)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${element(split("-", var.availability_zones[count.index]), 2)}"
    Tier = "Public-Ingress"
    AZ   = var.availability_zones[count.index]
  }
}

# 2. Private Application Subnets (For Target ECS / Container App)
resource "aws_subnet" "app" {
  count                   = length(var.app_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.app_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-app-private-${element(split("-", var.availability_zones[count.index]), 2)}"
    Tier = "Private-App"
    AZ   = var.availability_zones[count.index]
  }
}

# 3. Isolated Database Subnets (For Target RDS PostgreSQL)
resource "aws_subnet" "db" {
  count                   = length(var.db_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.db_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-db-isolated-${element(split("-", var.availability_zones[count.index]), 2)}"
    Tier = "Isolated-DB"
    AZ   = var.availability_zones[count.index]
  }
}

# DB Subnet Group (Required by RDS for Multi-AZ deployments)
resource "aws_db_subnet_group" "rds" {
  name        = "${var.project_name}-db-subnet-group"
  description = "Subnet group for target RDS PostgreSQL instance"
  subnet_ids  = aws_subnet.db[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}
