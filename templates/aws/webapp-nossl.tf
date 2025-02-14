######### User defined variables. These will be provided directly by the user in the setup process.

variable "startup_script" {
  description = "The startup shell script that will run on each app server host when it starts."
  type        = string
  default     = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup python3 -m http.server 8080 --bind 0.0.0.0 &
              EOF
}

variable "autoscaling_minsize" {
  description = "The minimum number of servers in the group."
  type        = number
  default     = 1
}

variable "autoscaling_maxsize" {
  description = "The maximum number of servers in the group."
  type        = number
  default     = 2
}

variable "health_check_interval" {
  description = "The number of seconds between health check invocations on each app server instance."
  type        = number
  default     = 15
}

variable "health_check_timeout" {
  description = "The client-side timeout for the health check invocation."
  type        = number
  default     = 3
}

######## Resolved variables based on user input. The user's vendor agnostic specifications must be translated to vendor-specific terms.

variable "aws_instance_type" {
  description = "The type of the machine instance to start, from the AWS catalog."
  type        = string
  default     = "t2.micro"
}

######## Vendor-specific configuration that may vary from one client to another.

variable "aws_region" {
  description = "The AWS region to run instances in."
  type        = string
  default     = "us-east-2"
}

variable "aws_ami" {
  description = "The AMI ID of the runtime to use for application instances."
  type        = string
  default     = "ami-088b41ffb0933423f"
}

######## Output of the process. This should take the same form from one vendor to another.

output "alb_dns_name" {
  value       = aws_lb.example.dns_name
  description = "The domain name of the load balancer"
}

######## Fully templatized component definitions. Any remaining hardcoded settings constitute "opinionation".

provider "aws" {
  region = var.aws_region
}

resource "aws_security_group" "instance" {
  name = "terraform-example-instance"
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "example" {
  image_id        = var.aws_ami
  instance_type   = var.aws_instance_type
  security_groups = [aws_security_group.instance.id]

  user_data = var.startup_script

  # Required when using a launch configuration with an ASG.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnets.default.ids
  
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = var.autoscaling_minsize
  max_size = var.autoscaling_maxsize

  tag {
    key                 = "Name"
    value               = "webapp-nossl"
    propagate_at_launch = true
  }
}

resource "aws_lb" "example" {
  name               = "terraform-asg-example"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = 80
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "asg" {
  name     = "terraform-asg-example"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

resource "aws_security_group" "alb" {
  name = "terraform-example-alb"
  # Allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}