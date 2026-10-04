module "network" {
  source      = "../../modules/network"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  app_port    = var.app_port
}

module "security" {
  source      = "../../modules/security"
  environment = var.environment
  vpc_id      = module.network.vpc_id
  app_port    = var.app_port
}

# Add the other modules below as they are built (web, app, data,
# feature). Pass network outputs in with module.network.<output>, for example:
#
# module "web" {
#   source              = "../../modules/web"
#   environment         = var.environment
#   vpc_id              = module.network.vpc_id
#   alb_subnet_ids      = module.network.public_subnet_ids
#   instance_subnet_ids = module.network.web_subnet_ids
# }
