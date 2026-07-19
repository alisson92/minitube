# Avoids hardcoding AZ names, which differ by region/account.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-lab"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project}-lab"
  }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${local.azs[count.index]}"
    # Lets the AWS Load Balancer Controller (EKS phase) auto-discover this subnet for internet-facing ALBs.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.lab.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project}-private-${local.azs[count.index]}"
    # Lets the AWS Load Balancer Controller (EKS phase) auto-discover this subnet for internal ALBs.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Single NAT Gateway for the whole environment (cost control principle) — placed
# in the first public subnet. Private subnets in other AZs still egress through
# it, trading cross-AZ resilience for a single NAT Gateway bill.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-nat"
  }
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project}-lab"
  }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project}-public"
  }
}

resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project}-private"
  }
}

resource "aws_route" "private_nat_gateway" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.lab.id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
