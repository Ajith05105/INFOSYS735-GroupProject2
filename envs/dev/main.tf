locals {
  # With a domain, CloudFront to ALB is HTTPS too. See var.domain_name.
  origin_port = var.domain_name == null ? 80 : 443
}

module "network" {
  source      = "../../modules/network"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  app_port    = var.app_port
  origin_port = local.origin_port
}

module "security" {
  source      = "../../modules/security"
  environment = var.environment
  vpc_id      = module.network.vpc_id
  app_port    = var.app_port
  origin_port = local.origin_port
}

module "data" {
  source      = "../../modules/data"
  environment = var.environment
  subnet_ids  = module.network.data_subnet_ids
  db_sg_id    = module.security.db_sg_id
}

module "app" {
  source           = "../../modules/app"
  environment      = var.environment
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.app_subnet_ids
  alb_sg_id        = module.security.app_alb_sg_id
  instance_sg_id   = module.security.app_sg_id
  instance_profile = module.security.app_instance_profile
  app_port         = var.app_port
  db_host          = module.data.address
}

module "web" {
  source              = "../../modules/web"
  environment         = var.environment
  vpc_id              = module.network.vpc_id
  alb_subnet_ids      = module.network.public_subnet_ids
  instance_subnet_ids = module.network.web_subnet_ids
  alb_sg_id           = module.security.alb_sg_id
  instance_sg_id      = module.security.web_sg_id
  instance_profile    = module.security.web_instance_profile
  domain_name         = var.domain_name
  app_alb_dns_name    = module.app.alb_dns_name
}

module "observability" {
  source                   = "../../modules/observability"
  environment              = var.environment
  vpc_id                   = module.network.vpc_id
  permissions_boundary_arn = module.security.permissions_boundary_arn
  alert_email              = var.alert_email

  tiers = {
    web = {
      asg_name                = module.web.asg_name
      alb_arn_suffix          = module.web.alb_arn_suffix
      target_group_arn_suffix = module.web.target_group_arn_suffix
    }
    app = {
      asg_name                = module.app.asg_name
      alb_arn_suffix          = module.app.alb_arn_suffix
      target_group_arn_suffix = module.app.target_group_arn_suffix
    }
  }
}

# Still to add: edge and the forecasting feature.
