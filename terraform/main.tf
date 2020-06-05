provider "aws" {
    region = "us-east-1"
    access_key = ""
    secret_key = ""
}

variable "environment_name" {
  type = "string"
  default = "Production"
}


# VPC
resource "aws_acm_certificate" "certificate" {
  private_key      = "${file("certificates/domain.key")}"
  certificate_body = "${file("certificates/domain.pem")}"

  tags = {
      Environment = var.environment_name
  }
}

module "vpc" {
    source = "terraform-aws-modules/vpc/aws"
    version = "~> v2.0"
    
    name = "scandiweb-vpc"
    cidr = "10.0.0.0/16"

    azs = [
        "us-east-1a",
        "us-east-1b",
    ]

    private_subnets = [
        "10.0.1.0/24", 
        "10.0.2.0/24", 
    ]
    
    public_subnets = [
        "10.0.101.0/24", 
        "10.0.102.0/24",
    ]

    enable_nat_gateway = true
    single_nat_gateway = true
    one_nat_gateway_per_az = false

    tags = {
        Environment = var.environment_name
    }
}

# Security Groups
resource "aws_security_group" "allow_egress_traffic" {
    name = "allow_egress_traffic"
    description = "Default security group to allow egress traffic"
    vpc_id = module.vpc.vpc_id

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_http_traffic" {
    name = "allow_http_traffic"
    description = "Allow ingress traffic on 80 port"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 80
        to_port  = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_https_traffic" {
    name = "allow_https_traffic"
    description = "Allow ingress traffic on 443 port"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 443
        to_port  = 443
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_ssh_traffic" {
    name = "allow_ssh_traffic"
    description = "Allow ingress traffic on 22 port for bastion host"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 22
        to_port  = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_from_load_balancer_traffic" {
    name = "allow_from_load_balancer_traffic"
    description = "Allow ingress traffic on port 80 from load balancer security group"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 80
        to_port  = 80
        protocol = "tcp"
        
        security_groups = [
            aws_security_group.allow_https_traffic.id,
        ]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_from_bastion_traffic" {
    name = "allow_from_bastion_traffic"
    description = "Allow ingress traffic on port 22 from bastion host"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 22
        to_port  = 22
        protocol = "tcp"
        
        security_groups = [
            aws_security_group.allow_ssh_traffic.id
        ]
    }

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_security_group" "allow_from_varnish_traffic" {
    name = "allow_from_varnish_traffic"
    description = "Allow ingress traffic on port 80 from varnish host"
    vpc_id = module.vpc.vpc_id

    ingress {
        from_port = 80
        to_port  = 80
        protocol = "tcp"
        
        security_groups = [
            aws_security_group.allow_from_load_balancer_traffic.id
        ]
    }

    tags = {
        Environment = var.environment_name
    }
}

# Load Balancer
module "load_balancer" {
    source  = "terraform-aws-modules/alb/aws"
    version = "~> 5.0"

    name = "main-application-load-balancer"

    load_balancer_type = "application"

    vpc_id = module.vpc.vpc_id
    
    subnets = module.vpc.public_subnets
    
    security_groups = [
        aws_security_group.allow_egress_traffic.id,
        aws_security_group.allow_http_traffic.id,
        aws_security_group.allow_https_traffic.id,
    ]

    target_groups = [
        {
            name_prefix = "vn-"
            backend_protocol = "HTTP"
            backend_port = 80
            target_type = "instance"
        },

        {
            name_prefix = "mg-"
            backend_protocol = "HTTP"
            backend_port = 80
            target_type = "instance"
        }
    ]

    https_listeners = [
        {
        port               = 443
        protocol           = "HTTPS"
        certificate_arn    = aws_acm_certificate.certificate.arn
        target_group_index = 0
        }
    ]

    http_tcp_listeners = [
        {
            port        = 80
            protocol    = "HTTP"
            action_type = "redirect"
            
            redirect = {
                port        = "443"
                protocol    = "HTTPS"
                status_code = "HTTP_301"
            }
        }
    ]

    tags = {
        Environment = var.environment_name
    }
}

resource "aws_alb_listener_rule" "static_media" {
    listener_arn = module.load_balancer.https_listener_arns[0]
    priority = 100

    action {
        type = "forward"
        target_group_arn = module.load_balancer.target_group_arns[1]
    }

    condition {
        path_pattern {
            values = [
                "/static/*",
                "/media/*",
            ]
        }
    }
}

# Auto Scaling Groups
module "magento_autoscaling" {
    source  = "terraform-aws-modules/autoscaling/aws"
    version = "~> 3.0"

    name = "Magento"
    
    lc_name = "magento-lc"
    
    key_name = "scandiweb"
    
    image_id = "ami-085925f297f89fce1"
    instance_type = "t3.small"
    
    target_group_arns = [
        module.load_balancer.target_group_arns[1],
    ]

    security_groups = [
        aws_security_group.allow_egress_traffic.id,
        aws_security_group.allow_from_load_balancer_traffic.id,
        aws_security_group.allow_from_bastion_traffic.id,
        aws_security_group.allow_from_varnish_traffic.id,
    ]

    asg_name = "magento"
    
    vpc_zone_identifier = [
        module.vpc.private_subnets[0]
    ]
    
    min_size = 0
    max_size = 1
    desired_capacity = 1
    
    health_check_type = "EC2"

    tags_as_map = {
        Environment = var.environment_name
    }
}

module "varnish_autoscaling" {
    source  = "terraform-aws-modules/autoscaling/aws"
    version = "~> 3.0"

    name = "Varnish"
    
    lc_name = "varnish-lc"

    key_name = "scandiweb"

    image_id = "ami-085925f297f89fce1"
    instance_type = "t3.small"
    
    target_group_arns = [
        module.load_balancer.target_group_arns[0],
    ]

    security_groups = [
        aws_security_group.allow_egress_traffic.id,
        aws_security_group.allow_from_load_balancer_traffic.id,
        aws_security_group.allow_from_bastion_traffic.id,
    ]

    asg_name = "varnish"
    
    vpc_zone_identifier = [
        module.vpc.private_subnets[0]
    ]
    
    min_size = 0
    max_size = 1
    desired_capacity = 1
    
    health_check_type = "EC2"
    
    tags_as_map = {
        Environment = var.environment_name
    }
}

# Bastion Host
resource "aws_instance" "bastion" {
  ami = "ami-085925f297f89fce1"
  instance_type = "t3.micro"
  key_name = "scandiweb"
  subnet_id = module.vpc.public_subnets[0]
  
  vpc_security_group_ids = [
        aws_security_group.allow_egress_traffic.id,
        aws_security_group.allow_ssh_traffic.id,
  ]

  associate_public_ip_address = true
  
  tags = {
      Name = "Bastion"
      Environment = var.environment_name
  }
}
