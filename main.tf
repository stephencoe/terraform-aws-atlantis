locals {
  # VPC - existing or new?
  vpc_id             = "${var.vpc_id == "" ? module.vpc.vpc_id : var.vpc_id}"
  private_subnet_ids = "${coalescelist(module.vpc.private_subnets, var.private_subnet_ids)}"
  public_subnet_ids  = "${coalescelist(module.vpc.public_subnets, var.public_subnet_ids)}"

  # Atlantis
  atlantis_image      = "${var.atlantis_image == "" ? "runatlantis/atlantis:${var.atlantis_version}" : "${var.atlantis_image}" }"
  atlantis_url        = "https://${coalesce(element(concat(aws_route53_record.atlantis.*.fqdn, list("")), 0), module.alb.dns_name)}"
  atlantis_url_events = "${local.atlantis_url}/events"

  container_definitions = "${var.custom_container_definitions == "" ? data.template_file.container_definitions.rendered : var.custom_container_definitions}"

  tags = "${merge(map("Name", var.name), var.tags)}"
}

data "aws_region" "current" {}

data "aws_route53_zone" "this" {
  count = "${var.create_route53_record}"

  name         = "${var.route53_zone_name}"
  private_zone = false
}

###################
# Secret for webhook
###################
resource "random_id" "webhook" {
  byte_length = "64"
}

resource "aws_ssm_parameter" "webhook" {
  name  = "${var.webhook_ssm_parameter_name}"
  type  = "SecureString"
  value = "${random_id.webhook.hex}"
}

resource "aws_ssm_parameter" "atlantis_github_user_token" {
  count = "${var.atlantis_github_user_token != "" ? 1 : 0}"

  name  = "${var.atlantis_github_user_token_ssm_parameter_name}"
  type  = "SecureString"
  value = "${var.atlantis_github_user_token}"
}

resource "aws_ssm_parameter" "atlantis_gitlab_user_token" {
  count = "${var.atlantis_gitlab_user_token != "" ? 1 : 0}"

  name  = "${var.atlantis_gitlab_user_token_ssm_parameter_name}"
  type  = "SecureString"
  value = "${var.atlantis_gitlab_user_token}"
}

###################
# VPC
###################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "v1.49.0"

  create_vpc = "${var.vpc_id == ""}"

  name = "${var.name}"

  cidr            = "${var.cidr}"
  azs             = "${var.azs}"
  private_subnets = "${var.private_subnets}"
  public_subnets  = "${var.public_subnets}"

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = "${local.tags}"
}

###################
# ALB
###################
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "v3.4.0"

  load_balancer_name = "${var.name}"

  vpc_id          = "${local.vpc_id}"
  subnets         = ["${local.public_subnet_ids}"]
  security_groups = ["${module.alb_https_sg.this_security_group_id}"]
  logging_enabled = false

  https_listeners = [{
    port            = 443
    certificate_arn = "${var.certificate_arn == "" ? module.acm.this_acm_certificate_arn : var.certificate_arn}"
  }]

  https_listeners_count = 1

  target_groups = [{
    name                 = "${var.name}"
    backend_protocol     = "HTTP"
    backend_port         = "${var.atlantis_port}"
    target_type          = "ip"
    deregistration_delay = 10
  }]

  target_groups_count = 1

  tags = "${local.tags}"
}

###################
# Security groups
###################
module "alb_https_sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/https-443"
  version = "v2.9.0"

  name        = "${var.name}-alb"
  vpc_id      = "${local.vpc_id}"
  description = "Security group with HTTPS ports open for everybody (IPv4 CIDR), egress ports are all world open"

  ingress_cidr_blocks = "${var.alb_ingress_cidr_blocks}"

  tags = "${local.tags}"
}

module "atlantis_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "v2.9.0"

  name        = "${var.name}"
  vpc_id      = "${local.vpc_id}"
  description = "Security group with open port for Atlantis (${var.atlantis_port}) from ALB, egress ports are all world open"

  computed_ingress_with_source_security_group_id = [
    {
      from_port                = "${var.atlantis_port}"
      to_port                  = "${var.atlantis_port}"
      protocol                 = "tcp"
      description              = "Atlantis"
      source_security_group_id = "${module.alb_https_sg.this_security_group_id}"
    },
  ]

  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  tags = "${local.tags}"
}

###################
# ACM (SSL certificate)
###################
module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "v1.0.0"

  create_certificate = "${var.certificate_arn == "" ? 1 : 0}"

  domain_name = "${var.acm_certificate_domain_name == "" ? join(".", list(var.name, var.route53_zone_name)) : var.acm_certificate_domain_name}"
  zone_id     = "${data.aws_route53_zone.this.id}"

  tags = "${local.tags}"
}

###################
# Route53 record
###################
resource "aws_route53_record" "atlantis" {
  count = "${var.create_route53_record}"

  zone_id = "${data.aws_route53_zone.this.zone_id}"
  name    = "${var.name}"
  type    = "A"

  alias {
    name                   = "${module.alb.dns_name}"
    zone_id                = "${module.alb.load_balancer_zone_id}"
    evaluate_target_health = true
  }
}

###################
# ECS
###################
module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "v1.0.0"

  name = "${var.name}"
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.name}-ecs_task_execution"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  count = "${length(var.policies_arn)}"

  role       = "${aws_iam_role.ecs_task_execution.id}"
  policy_arn = "${element(var.policies_arn, count.index)}"
}

// ref: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data.html
//resource "aws_iam_role_policy" "ecs_task_access_secrets" {
//  count = "${var.atlantis_github_user_token != "" || var.atlantis_gitlab_user_token != "" ? 1 : 0}"
//
//  role       = "${aws_iam_role.ecs_task_execution.id}"
//  policy = <<EOF
//{
//  "Version": "2012-10-17",
//  "Statement": [
//    {
//      "Effect": "Allow",
//      "Action": [
//        "ssm:GetParameters",
//        "secretsmanager:GetSecretValue"
//      ],
//      "Resource": [
//        "arn:aws:ssm:::parameter/*",
//        "arn:aws:secretsmanager:::secret:*",
//        "arn:aws:kms:region:aws_account_id:key:key_id"
//      ]
//    }
//  ]
//}
//EOF
//}

data "template_file" "container_definitions" {
  template = "${file("${path.module}/atlantis-task.json")}"

  vars {
    name                       = "${var.name}"
    atlantis_image             = "${local.atlantis_image}"
    logs_group                 = "${aws_cloudwatch_log_group.atlantis.name}"
    logs_region                = "${data.aws_region.current.name}"
    logs_stream_prefix         = "ecs"
    ATLANTIS_ALLOW_REPO_CONFIG = "${var.allow_repo_config}"
    ATLANTIS_LOG_LEVEL         = "debug"
    ATLANTIS_PORT              = "${var.atlantis_port}"
    ATLANTIS_ATLANTIS_URL      = "${local.atlantis_url}"
    ATLANTIS_REPO_WHITELIST    = "${join(",", var.atlantis_repo_whitelist)}"

    # When secrets will be supported in ECS Fargate use values from comment field
    # Ref: https://github.com/aws/amazon-ecs-agent/issues/1209
    ATLANTIS_GH_USER = "${var.atlantis_github_user}"

    ATLANTIS_GH_TOKEN          = "${element(concat(aws_ssm_parameter.atlantis_github_user_token.*.value, list("")), 0)}" # "${var.atlantis_github_user_token_ssm_parameter_name}"
    ATLANTIS_GH_WEBHOOK_SECRET = "${aws_ssm_parameter.webhook.value}"                                                    # "${var.webhook_ssm_parameter_name}"

    ATLANTIS_GITLAB_USER           = "${var.atlantis_gitlab_user}"
    ATLANTIS_GITLAB_TOKEN          = "${element(concat(aws_ssm_parameter.atlantis_gitlab_user_token.*.value, list("")), 0)}" # "${var.atlantis_gitlab_user_token_ssm_parameter_name}"
    ATLANTIS_GITLAB_WEBHOOK_SECRET = "${aws_ssm_parameter.webhook.value}"                                                    # "${var.webhook_ssm_parameter_name}"
  }
}

resource "aws_ecs_task_definition" "atlantis" {
  family                   = "${var.name}"
  execution_role_arn       = "${aws_iam_role.ecs_task_execution.arn}"
  task_role_arn            = "${aws_iam_role.ecs_task_execution.arn}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "${var.ecs_task_cpu}"
  memory                   = "${var.ecs_task_memory}"

  container_definitions = "${local.container_definitions}"
}

data "aws_ecs_task_definition" "atlantis" {
  task_definition = "${var.name}"
  depends_on      = ["aws_ecs_task_definition.atlantis"]
}

resource "aws_ecs_service" "atlantis" {
  name                               = "${var.name}"
  cluster                            = "${module.ecs.this_ecs_cluster_id}"
  task_definition                    = "${data.aws_ecs_task_definition.atlantis.family}:${max(aws_ecs_task_definition.atlantis.revision, data.aws_ecs_task_definition.atlantis.revision)}"
  desired_count                      = "${var.ecs_service_desired_count}"
  launch_type                        = "FARGATE"
  deployment_maximum_percent         = "${var.ecs_service_deployment_maximum_percent}"
  deployment_minimum_healthy_percent = "${var.ecs_service_deployment_minimum_healthy_percent}"

  network_configuration {
    subnets          = ["${local.private_subnet_ids}"]
    security_groups  = ["${module.atlantis_sg.this_security_group_id}"]
    assign_public_ip = "${var.ecs_service_assign_public_ip}"
  }

  load_balancer {
    container_name   = "${var.name}"
    container_port   = "${var.atlantis_port}"
    target_group_arn = "${element(module.alb.target_group_arns, 0)}"
  }
}

###################
# Cloudwatch logs
###################
resource "aws_cloudwatch_log_group" "atlantis" {
  name              = "${var.name}"
  retention_in_days = "${var.cloudwatch_log_retention_in_days}"

  tags = "${local.tags}"
}
