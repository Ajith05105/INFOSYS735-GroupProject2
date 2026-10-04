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

module "app" {
  source           = "../../modules/app"
  environment      = var.environment
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.app_subnet_ids
  alb_sg_id        = module.security.app_alb_sg_id
  instance_sg_id   = module.security.app_sg_id
  instance_profile = module.security.app_instance_profile
  app_port         = var.app_port
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

# Still to add: data, observability, edge and the forecasting feature.
