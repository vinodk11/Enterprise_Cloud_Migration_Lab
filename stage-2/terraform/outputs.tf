output "vpc_id" {
  description = "Target AWS VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "Target AWS VPC CIDR Block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of Public Subnet IDs"
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "List of Private Application Subnet IDs"
  value       = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  description = "List of Isolated Database Subnet IDs"
  value       = aws_subnet.db[*].id
}

output "public_route_table_id" {
  description = "ID of Public Route Table"
  value       = aws_route_table.public.id
}

output "app_route_table_id" {
  description = "ID of Private Application Route Table"
  value       = aws_route_table.app.id
}

output "db_route_table_id" {
  description = "ID of Isolated Database Route Table"
  value       = aws_route_table.db.id
}

output "app_security_group_id" {
  description = "ID of Application Security Group"
  value       = aws_security_group.app_sg.id
}

output "db_security_group_id" {
  description = "ID of RDS PostgreSQL Database Security Group"
  value       = aws_security_group.db_sg.id
}

output "rds_subnet_group_name" {
  description = "Name of the RDS Subnet Group"
  value       = aws_db_subnet_group.rds.name
}
