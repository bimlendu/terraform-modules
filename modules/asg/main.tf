resource "tls_private_key" "self_signed" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "self_signed" {
  key_algorithm   = "${tls_private_key.self_signed.algorithm}"
  private_key_pem = "${tls_private_key.self_signed.private_key_pem}"

  subject {
    common_name  = "${var.name}-jenkins.com"
    organization = "${upper(var.name)}, Inc"
  }

  validity_period_hours = 2400

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

resource "aws_iam_server_certificate" "self_signed" {
  name_prefix      = "${var.name}-jenkins"
  certificate_body = "${tls_self_signed_cert.self_signed.cert_pem}"
  private_key      = "${tls_private_key.self_signed.private_key_pem}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "lb" {
  name_prefix = "${var.name}-lb-sg-"
  description = "Security group for asg ALB."
  vpc_id      = "${lookup(var.asg, "vpc_id")}"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${lookup(var.elb, "allowed_network")}"]
  }

  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["${lookup(var.elb, "allowed_network")}"]
  }

  ingress {
    from_port   = 2015
    to_port     = 2015
    protocol    = "tcp"
    cidr_blocks = ["${lookup(var.elb, "allowed_network")}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${merge(var.default_tags, map(
    "Name", format("%s-lb-sg", var.name)
  ))}"
}

resource "aws_elb" "lb" {
  name = "${var.name}-lb"

  subnets         = ["${split(",", lookup(var.elb, "subnets"))}"]
  internal        = "${lookup(var.elb, "internal")}"
  security_groups = ["${aws_security_group.lb.id}"]

  listener {
    instance_port      = "${lookup(var.elb, "instance_port")}"
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${aws_iam_server_certificate.self_signed.arn}"
  }

  listener {
    instance_port     = 9000
    instance_protocol = "http"
    lb_port           = 9000
    lb_protocol       = "http"
  }

  listener {
    instance_port     = 2015
    instance_protocol = "http"
    lb_port           = 2015
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 4
    target              = "TCP:${lookup(var.elb, "instance_port")}"
    interval            = 30
  }

  tags = "${merge(var.default_tags, map(
    "Name", format("%s-lb", var.name)
  ))}"
}

resource "aws_launch_configuration" "lc" {
  name_prefix          = "${var.name}-lc-"
  image_id             = "${lookup(var.lc, "ami")}"
  instance_type        = "${lookup(var.lc, "instance_type")}"
  key_name             = "${lookup(var.lc, "key_name")}"
  security_groups      = ["${lookup(var.lc, "security_groups")}"]
  user_data            = "${lookup(var.lc, "user_data")}"
  iam_instance_profile = "${lookup(var.lc, "iam_instance_profile")}"

  lifecycle = {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  depends_on = ["aws_launch_configuration.lc"]

  name_prefix      = "${var.name}-asg-"
  max_size         = "${lookup(var.asg, "max_size")}"
  min_size         = "${lookup(var.asg, "min_size")}"
  desired_capacity = "${lookup(var.asg, "desired_capacity")}"

  launch_configuration = "${aws_launch_configuration.lc.id}"

  health_check_type         = "${lookup(var.asg, "health_check_type")}"
  health_check_grace_period = "${lookup(var.asg, "health_check_grace_period")}"

  load_balancers = ["${aws_elb.lb.id}"]

  vpc_zone_identifier = ["${split(",", lookup(var.asg, "subnets"))}"]
}
