# Security Group for Target Application Workload (ECS / App instances)
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Security group for private StreamFlix application tier"
  vpc_id      = aws_vpc.main.id

  # Allow HTTP / App traffic from within VPC (e.g., from future ALB)
  ingress {
    description = "Application port from within VPC"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Standard HTTP from within VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow ICMP (Ping) from On-Premises Datacenter across VPN tunnel
  ingress {
    description = "ICMP Ping from On-Premises Datacenter"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.onprem_cidr]
  }

  # Allow SSH from On-Premises Datacenter across VPN tunnel
  ingress {
    description = "SSH from On-Premises Datacenter"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
    Tier = "App-Security"
  }
}

# Security Group for Target Database (RDS PostgreSQL)
resource "aws_security_group" "db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "Security group for target RDS PostgreSQL instance"
  vpc_id      = aws_vpc.main.id

  # Allow PostgreSQL access from the Application Tier security group
  ingress {
    description     = "PostgreSQL from App Tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  # Allow PostgreSQL replication directly from On-Premises DB01
  ingress {
    description = "PostgreSQL replication from On-Premises DB01"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.onprem_db_ip]
  }

  egress {
    description = "Allow local VPC outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-db-sg"
    Tier = "DB-Security"
  }
}
