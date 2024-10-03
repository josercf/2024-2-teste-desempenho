# Configuração do Provedor AWS
provider "aws" {
  region     = var.region
  access_key = var.access_key
  secret_key = var.secret_key
  token      = var.session_token
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Tabela de Rotas Pública
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Subnets em diferentes AZs com CIDRs atualizados
resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_subnet_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.20.0/24"
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
}

# Associação das Subnets à Tabela de Rotas
resource "aws_route_table_association" "public_rt_assoc_a" {
  subnet_id      = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_rt_assoc_b" {
  subnet_id      = aws_subnet.public_subnet_b.id
  route_table_id = aws_route_table.public_rt.id
}

# Security Group (sem configuração da porta 22)
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template com Correção no User Data
resource "aws_launch_template" "web_lt" {
  name_prefix   = "web_lt"
  image_id      = "ami-0c94855ba95c71c99" # AMI Amazon Linux 2 (us-east-1)
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo amazon-linux-extras install nginx1 -y
    echo 'server {
      listen 80;
      location / {
        add_header Content-Type text/plain;
        # Simula atraso aleatório entre 1 e 5 segundos
        sleep $(( ( RANDOM % 5 )  + 1 ));
        return 200 "Response from \$HOSTNAME\n";
      }
    }' | sudo tee /etc/nginx/conf.d/default.conf
    sudo systemctl restart nginx
    EOF
  )
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  name                      = "web_asg"
  max_size                  = 4
  min_size                  = 1
  desired_capacity          = 1
  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }
  vpc_zone_identifier       = [
    aws_subnet.public_subnet_a.id,
    aws_subnet.public_subnet_b.id
  ]
  target_group_arns         = [aws_lb_target_group.web_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "web_server"
    propagate_at_launch = true
  }
}

# Load Balancer
resource "aws_lb" "web_lb" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [
    aws_subnet.public_subnet_a.id,
    aws_subnet.public_subnet_b.id
  ]
}

# Target Group
resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    unhealthy_threshold = 2
    healthy_threshold   = 5
    matcher             = "200-399"
  }
}

# Listener
resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# Políticas de Auto Scaling e Alarmes do CloudWatch
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale_out_policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "scale_in_policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu_high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "70"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }

  alarm_description = "Alarme quando CPU > 70% por 2 períodos de 2 minutos"
  alarm_actions     = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu_low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "30"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }

  alarm_description = "Alarme quando CPU < 30% por 2 períodos de 2 minutos"
  alarm_actions     = [aws_autoscaling_policy.scale_in.arn]
}

# Output do DNS do Load Balancer
output "load_balancer_dns" {
  description = "DNS público do Load Balancer"
  value       = aws_lb.web_lb.dns_name
}