terraform {
  required_version = ">= 0.12.0"
}

module "consul_auto_join_instance_role" {
  source = "github.com/tmekaumput/consul-auto-join-instance-role-aws"

  create = var.create
  name   = var.name
}

data "aws_ami" "vault" {
  count       = var.create && var.image_id == "" ? 1 : 0
  most_recent = true
  owners      = [var.ami_owner]
  name_regex  = "vault-image_${lower(var.release_version)}_vault_${lower(var.vault_version)}_consul_${lower(var.consul_version)}_${lower(var.os)}_${var.os_version}.*"

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "template_file" "vault_init" {
  count    = var.create ? 1 : 0
  template = file("${path.module}/templates/init-systemd.sh.tpl")

  vars = {
    name      = var.name
    user_data = var.user_data != "" ? var.user_data : "echo 'No custom user_data'"
  }
}

module "vault_server_sg" {
  source = "github.com/tmekaumput/vault-server-ports-aws"

  create      = var.create
  name        = "${var.name}-vault-server"
  vpc_id      = var.vpc_id
  cidr_blocks = [var.public ? "0.0.0.0/0" : var.vpc_cidr] # If there's a public IP, open Vault ports for public access - DO NOT DO THIS IN PROD
}

module "consul_client_sg" {
  source = "github.com/tmekaumput/consul-client-ports-aws"

  create      = var.create
  name        = "${var.name}-vault-consul-client"
  vpc_id      = var.vpc_id
  cidr_blocks = [var.public ? "0.0.0.0/0" : var.vpc_cidr] # If there's a public IP, open Consul ports for public access - DO NOT DO THIS IN PROD
}

resource "aws_security_group_rule" "ssh" {
  count = var.create ? 1 : 0

  security_group_id = module.vault_server_sg.vault_server_sg_id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.public ? "0.0.0.0/0" : var.vpc_cidr] # If there's a public IP, open port 22 for public access - DO NOT DO THIS IN PROD
}

resource "aws_launch_configuration" "vault" {
  count = var.create ? 1 : 0

  name_prefix                 = format("%s-vault-", var.name)
  associate_public_ip_address = var.public
  ebs_optimized               = false
  instance_type               = var.instance_type
  image_id                    = var.image_id != "" ? var.image_id : element(concat(data.aws_ami.vault.*.id, [""]), 0) # TODO: Workaround for issue #11210
  iam_instance_profile        = var.instance_profile != "" ? var.instance_profile : module.consul_auto_join_instance_role.instance_profile_id
  user_data                   = data.template_file.vault_init[0].rendered
  key_name                    = var.ssh_key_name

  security_groups = [
    module.vault_server_sg.vault_server_sg_id,
    module.consul_client_sg.consul_client_sg_id,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

module "vault_lb_aws" {
  source = "github.com/tmekaumput/vault-lb-aws"

  create             = var.create
  name               = var.name
  vpc_id             = var.vpc_id
  cidr_blocks        = [var.public ? "0.0.0.0/0" : var.vpc_cidr] # If there's a public IP, open port 22 for public access - DO NOT DO THIS IN PROD
  subnet_ids         = var.subnet_ids
  is_internal_lb     = false == var.public
  use_lb_cert        = var.use_lb_cert
  lb_cert            = var.lb_cert
  lb_private_key     = var.lb_private_key
  lb_cert_chain      = var.lb_cert_chain
  lb_ssl_policy      = var.lb_ssl_policy
  lb_bucket          = var.lb_bucket
  lb_bucket_override = var.lb_bucket_override
  lb_bucket_prefix   = var.lb_bucket_prefix
  lb_logs_enabled    = var.lb_logs_enabled
  tags               = var.tags
}

resource "aws_autoscaling_group" "vault" {
  count = var.create ? 1 : 0

  name_prefix          = aws_launch_configuration.vault[0].name
  launch_configuration = aws_launch_configuration.vault[0].id
  vpc_zone_identifier  = var.subnet_ids
  max_size             = var.node_count != -1 ? var.node_count : length(var.subnet_ids)
  min_size             = var.node_count != -1 ? var.node_count : length(var.subnet_ids)
  desired_capacity     = var.node_count != -1 ? var.node_count : length(var.subnet_ids)
  default_cooldown     = 30
  force_delete         = true

  target_group_arns = compact(
    concat(
      [
        module.vault_lb_aws.vault_tg_http_8200_arn,
        module.vault_lb_aws.vault_tg_https_8200_arn,
      ],
      var.target_groups,
    ),
  )

  # TF-UPGRADE-TODO: In Terraform v0.10 and earlier, it was sometimes necessary to
  # force an interpolation expression to be interpreted as a list by wrapping it
  # in an extra set of list brackets. That form was supported for compatibility in
  # v0.11, but is no longer supported in Terraform v0.12.
  #
  # If the expression in the following list itself returns a list, remove the
  # brackets to avoid interpretation as a list of lists. If the expression
  # returns a single list item then leave it as-is and remove this TODO comment.
  tags = concat(
      [
        {
          "key"                 = "Name"
          "value"               = format("%s-vault-node", var.name)
          "propagate_at_launch" = "true"
        },
        {
          "key"                 = "Consul-Auto-Join"
          "value"               = var.name
          "propagate_at_launch" = "true"
        },
      ],
      var.tags_list,
    )

  lifecycle {
    create_before_destroy = true
  }
}

