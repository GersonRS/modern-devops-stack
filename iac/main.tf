# Providers configuration

# These providers depend on the output of the respectives modules declared below.
# However, for clarity and ease of maintenance we grouped them all together in this section.

provider "kubernetes" {
  host                   = module.kind.parsed_kubeconfig.host
  client_certificate     = module.kind.parsed_kubeconfig.client_certificate
  client_key             = module.kind.parsed_kubeconfig.client_key
  cluster_ca_certificate = module.kind.parsed_kubeconfig.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = module.kind.parsed_kubeconfig.host
    client_certificate     = module.kind.parsed_kubeconfig.client_certificate
    client_key             = module.kind.parsed_kubeconfig.client_key
    cluster_ca_certificate = module.kind.parsed_kubeconfig.cluster_ca_certificate
  }
}

provider "argocd" {
  server_addr                 = "127.0.0.1:8080"
  auth_token                  = module.argocd_bootstrap.argocd_auth_token
  insecure                    = true
  plain_text                  = true
  port_forward                = true
  port_forward_with_namespace = module.argocd_bootstrap.argocd_namespace
  kubernetes {
    host                   = module.kind.parsed_kubeconfig.host
    client_certificate     = module.kind.parsed_kubeconfig.client_certificate
    client_key             = module.kind.parsed_kubeconfig.client_key
    cluster_ca_certificate = module.kind.parsed_kubeconfig.cluster_ca_certificate
  }
}

provider "keycloak" {
  client_id                = "admin-cli"
  username                 = module.keycloak.admin_credentials.username
  password                 = module.keycloak.admin_credentials.password
  url                      = "https://keycloak.apps.${local.cluster_name}.${local.base_domain}"
  tls_insecure_skip_verify = true
  initial_login            = false
}

# Module declarations and configuration

module "kind" {
  source = "./modules/kind"

  cluster_name       = local.cluster_name
  kubernetes_version = local.kubernetes_version
}

module "metallb" {
  source = "./modules/metallb"

  subnet = module.kind.kind_subnet
}

module "argocd_bootstrap" {
  source = "./modules/argocd/bootstrap"
}

module "traefik" {
  source = "./modules/traefik"

  cluster_name = local.cluster_name

  # TODO fix: the base domain is defined later. Proposal: remove redirection from traefik module and add it in dependent modules.
  # For now random value is passed to base_domain. Redirections will not work before fix.
  base_domain = "placeholder.com"

  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  enable_service_monitor = local.enable_service_monitor

  dependency_ids = {
    argocd = module.argocd_bootstrap.id
  }
}

module "cert-manager" {
  source = "./modules/cert-manager"

  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  enable_service_monitor = local.enable_service_monitor

  dependency_ids = {
    argocd = module.argocd_bootstrap.id
  }
}

module "keycloak" {
  source = "./modules/keycloak"

  cluster_name     = local.cluster_name
  base_domain      = local.base_domain
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  dependency_ids = {
    traefik      = module.traefik.id
    cert-manager = module.cert-manager.id
  }
}

module "oidc" {
  source = "./modules/oidc"

  cluster_name   = local.cluster_name
  base_domain    = local.base_domain
  cluster_issuer = local.cluster_issuer

  dependency_ids = {
    keycloak = module.keycloak.id
  }
}

module "minio" {
  source = "./modules/minio"

  cluster_name     = local.cluster_name
  base_domain      = local.base_domain
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  enable_service_monitor = local.enable_service_monitor

  config_minio = local.minio_config

  oidc = module.oidc.oidc

  dependency_ids = {
    traefik      = module.traefik.id
    cert-manager = module.cert-manager.id
    oidc         = module.oidc.id
  }
}

module "loki-stack" {
  source = "./modules/loki-stack"

  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  distributed_mode = true

  logs_storage = {
    bucket_name       = local.minio_config.buckets.0.name
    endpoint          = module.minio.endpoint
    access_key        = local.minio_config.users.0.accessKey
    secret_access_key = local.minio_config.users.0.secretKey
  }

  dependency_ids = {
    minio = module.minio.id
  }
}

module "thanos" {
  source = "./modules/thanos"

  cluster_name     = local.cluster_name
  base_domain      = local.base_domain
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  metrics_storage = {
    bucket_name       = local.minio_config.buckets.1.name
    endpoint          = module.minio.endpoint
    access_key        = local.minio_config.users.1.accessKey
    secret_access_key = local.minio_config.users.1.secretKey
  }

  thanos = {
    oidc = module.oidc.oidc
  }

  dependency_ids = {
    traefik      = module.traefik.id
    cert-manager = module.cert-manager.id
    minio        = module.minio.id
    oidc         = module.oidc.id
  }
}

module "kube-prometheus-stack" {
  source = "./modules/kube-prometheus-stack"

  cluster_name     = local.cluster_name
  base_domain      = local.base_domain
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  metrics_storage = {
    bucket     = local.minio_config.buckets.1.name
    endpoint   = module.minio.endpoint
    access_key = local.minio_config.users.1.accessKey
    secret_key = local.minio_config.users.1.secretKey
  }

  prometheus = {
    oidc = module.oidc.oidc
  }
  alertmanager = {
    oidc = module.oidc.oidc
  }
  grafana = {
    oidc = module.oidc.oidc
  }

  dependency_ids = {
    traefik      = module.traefik.id
    cert-manager = module.cert-manager.id
    minio        = module.minio.id
    oidc         = module.oidc.id
  }
}