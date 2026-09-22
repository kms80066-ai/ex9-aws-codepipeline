# ============================================================
# 0. Terraform / Provider / Locals
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region = local.region
}

locals {
  tag_header = (var.owner != "" && var.enviroment != "") ? "${var.owner}-${var.enviroment}-" : (
    (var.owner != "") ? "${var.owner}-" : ""
  )
  region = "ca-central-1"

  # VPC
  vpc_cidr = "10.90.0.0/16"

  # Public Subnets
  public_a_cidr = "10.90.1.0/24"
  public_b_cidr = "10.90.2.0/24"

  # Private Subnets
  private_a_cidr = "10.90.11.0/24"
  private_b_cidr = "10.90.12.0/24"

  # AZ Index
  az_a = 0
  az_b = 1

  # Route
  default_route = "0.0.0.0/0"

  # 키페어
  key_name = var.key_name

  vpc_id = data.aws_vpc.vpc.id

  ami_id = data.aws_ami.al2023.id

  security_groups_ids = data.aws_security_groups.security_groups.ids

  ec2_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]

  private_subnet_ids = data.aws_subnets.private.ids

  github_repository_id = var.github_repository_id
}

variable "key_name" {
  type    = string
  default = "std09-keypair"
}

variable "owner" {
  type    = string
  default = "std09"
}

variable "enviroment" {
  description = "프로젝트 역할 구분"
  type        = string
  default     = "ex"
}

variable "default_version" {
  description = "시작템플릿 버전"
  type        = string
  default     = "latest"
}

variable "github_repository_id" {
  type    = string
  default = "kms80066-ai/ex9-aws-codepipeline"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["${local.tag_header}vpc"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }

  filter {
    name = "tag:Name"
    values = [
      "${local.tag_header}private-a",
      "${local.tag_header}private-b"
    ]
  }
}

# ============================================================
# External ALB Security Group
# ============================================================

resource "aws_security_group" "security_group_alb" {
  name        = "${local.tag_header}external-alb-sg"
  description = "External ALB Security Group"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.tag_header}external-alb-sg"
  }
}

# ============================================================
# SSH Security Group
# ============================================================

resource "aws_security_group" "security_group_ssh" {
  name        = "${local.tag_header}ssh-sg"
  description = "SSH Security Group"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.tag_header}ssh-sg"
  }
}

# ============================================================
# 1. VPC
# ============================================================

resource "aws_vpc" "vpc" {
  cidr_block = local.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.tag_header}vpc"
  }
}


# ============================================================
# 2. Internet Gateway
# ============================================================

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.tag_header}igw"
  }
}


# ============================================================
# 3. Public Subnets
# ============================================================

# Public A
resource "aws_subnet" "public_a" {
  vpc_id = aws_vpc.vpc.id

  cidr_block        = local.public_a_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_a]

  map_public_ip_on_launch = true

  tags = {
    Name = "${local.tag_header}public-a"
    Type = "public"
  }
}

# Public B
resource "aws_subnet" "public_b" {
  vpc_id = aws_vpc.vpc.id

  cidr_block        = local.public_b_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_b]

  map_public_ip_on_launch = true

  tags = {
    Name = "${local.tag_header}public-b"
    Type = "public"
  }
}


# ============================================================
# 4. Public Route Table
# ============================================================

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = local.default_route
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.tag_header}public-rt"
  }
}


# ============================================================
# 5. Public Route Table Associations
# ============================================================

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}


# ============================================================
# 6. Private Subnets [추가]
# ============================================================

# Private A
resource "aws_subnet" "private_a" {
  vpc_id = aws_vpc.vpc.id

  cidr_block        = local.private_a_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_a]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.tag_header}private-a"
    Type = "private"
  }
}

# Private B
resource "aws_subnet" "private_b" {
  vpc_id = aws_vpc.vpc.id

  cidr_block        = local.private_b_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_b]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.tag_header}private-b"
    Type = "private"
  }
}


# ============================================================
# 7. NAT Gateway EIP [추가]
# ============================================================

resource "aws_eip" "nat_eip" {
  domain = "vpc"

  tags = {
    Name = "${local.tag_header}nat-eip"
  }
}


# ============================================================
# 8. NAT Gateway [추가]
# ============================================================

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id

  # NAT는 Public A에 생성
  subnet_id = aws_subnet.public_a.id

  tags = {
    Name = "${local.tag_header}nat"
  }

  # IGW가 VPC에 연결된 이후 NAT 생성
  depends_on = [
    aws_internet_gateway.igw
  ]
}


# ============================================================
# 9. Private Route Table [추가]
# ============================================================

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.vpc.id

  # Private -> NAT Gateway -> IGW -> Internet
  route {
    cidr_block     = local.default_route
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${local.tag_header}private-rt"
  }
}


# ============================================================
# 10. Private Route Table Associations [추가]
# ============================================================

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_rt.id
}


# ============================================================
# 11. Pipeline 저장용 S3 Bucket
# ============================================================
resource "aws_s3_bucket" "name" {

}








# ============================================================
# 11. Outputs
# ============================================================


output "public_subnet_ids" {
  value = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
}

output "private_subnet_ids" {
  value = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]
}

output "nat_gateway_id" {
  value = aws_nat_gateway.nat.id
}

output "nat_public_ip" {
  value = aws_eip.nat_eip.public_ip
}
