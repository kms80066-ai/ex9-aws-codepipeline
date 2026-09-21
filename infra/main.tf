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
  tag_header = "std09-"
  region     = "ca-central-1"

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
}

data "aws_availability_zones" "available" {
  state = "available"
}


# ============================================================
# 1. VPC
# ============================================================

resource "aws_vpc" "asg_vpc" {
  cidr_block = local.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.tag_header}asg-vpc"
  }
}


# ============================================================
# 2. Internet Gateway
# ============================================================

resource "aws_internet_gateway" "asg_igw" {
  vpc_id = aws_vpc.asg_vpc.id

  tags = {
    Name = "${local.tag_header}asg-igw"
  }
}


# ============================================================
# 3. Public Subnets
# ============================================================

# Public A
resource "aws_subnet" "asg_public_a" {
  vpc_id = aws_vpc.asg_vpc.id

  cidr_block        = local.public_a_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_a]

  map_public_ip_on_launch = true

  tags = {
    Name = "${local.tag_header}asg-public-a"
    Type = "public"
  }
}

# Public B
resource "aws_subnet" "asg_public_b" {
  vpc_id = aws_vpc.asg_vpc.id

  cidr_block        = local.public_b_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_b]

  map_public_ip_on_launch = true

  tags = {
    Name = "${local.tag_header}asg-public-b"
    Type = "public"
  }
}


# ============================================================
# 4. Public Route Table
# ============================================================

resource "aws_route_table" "asg_public_rt" {
  vpc_id = aws_vpc.asg_vpc.id

  route {
    cidr_block = local.default_route
    gateway_id = aws_internet_gateway.asg_igw.id
  }

  tags = {
    Name = "${local.tag_header}asg-public-rt"
  }
}


# ============================================================
# 5. Public Route Table Associations
# ============================================================

resource "aws_route_table_association" "asg_public_a" {
  subnet_id      = aws_subnet.asg_public_a.id
  route_table_id = aws_route_table.asg_public_rt.id
}

resource "aws_route_table_association" "asg_public_b" {
  subnet_id      = aws_subnet.asg_public_b.id
  route_table_id = aws_route_table.asg_public_rt.id
}


# ============================================================
# 6. Private Subnets [추가]
# ============================================================

# Private A
resource "aws_subnet" "asg_private_a" {
  vpc_id = aws_vpc.asg_vpc.id

  cidr_block        = local.private_a_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_a]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.tag_header}asg-private-a"
    Type = "private"
  }
}

# Private B
resource "aws_subnet" "asg_private_b" {
  vpc_id = aws_vpc.asg_vpc.id

  cidr_block        = local.private_b_cidr
  availability_zone = data.aws_availability_zones.available.names[local.az_b]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.tag_header}asg-private-b"
    Type = "private"
  }
}


# ============================================================
# 7. NAT Gateway EIP [추가]
# ============================================================

resource "aws_eip" "asg_nat_eip" {
  domain = "vpc"

  tags = {
    Name = "${local.tag_header}asg-nat-eip"
  }
}


# ============================================================
# 8. NAT Gateway [추가]
# ============================================================

resource "aws_nat_gateway" "asg_nat" {
  allocation_id = aws_eip.asg_nat_eip.id

  # NAT는 Public A에 생성
  subnet_id = aws_subnet.asg_public_a.id

  tags = {
    Name = "${local.tag_header}asg-nat"
  }

  # IGW가 VPC에 연결된 이후 NAT 생성
  depends_on = [
    aws_internet_gateway.asg_igw
  ]
}


# ============================================================
# 9. Private Route Table [추가]
# ============================================================

resource "aws_route_table" "asg_private_rt" {
  vpc_id = aws_vpc.asg_vpc.id

  # Private -> NAT Gateway -> IGW -> Internet
  route {
    cidr_block     = local.default_route
    nat_gateway_id = aws_nat_gateway.asg_nat.id
  }

  tags = {
    Name = "${local.tag_header}asg-private-rt"
  }
}


# ============================================================
# 10. Private Route Table Associations [추가]
# ============================================================

resource "aws_route_table_association" "asg_private_a" {
  subnet_id      = aws_subnet.asg_private_a.id
  route_table_id = aws_route_table.asg_private_rt.id
}

resource "aws_route_table_association" "asg_private_b" {
  subnet_id      = aws_subnet.asg_private_b.id
  route_table_id = aws_route_table.asg_private_rt.id
}


# ============================================================
# 11. Outputs
# ============================================================

output "vpc_id" {
  value = aws_vpc.asg_vpc.id
}

output "public_subnet_ids" {
  value = [
    aws_subnet.asg_public_a.id,
    aws_subnet.asg_public_b.id
  ]
}

output "private_subnet_ids" {
  value = [
    aws_subnet.asg_private_a.id,
    aws_subnet.asg_private_b.id
  ]
}

output "nat_gateway_id" {
  value = aws_nat_gateway.asg_nat.id
}

output "nat_public_ip" {
  value = aws_eip.asg_nat_eip.public_ip
}