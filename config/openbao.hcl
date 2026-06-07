# OpenBao server configuration for Fly.io deployment.
# Connection URL is provided via BAO_PG_CONNECTION_URL (set from DB_CONNECTION_URI by entrypoint).
# API address is provided via BAO_API_ADDR (set from FLY_APP_NAME by entrypoint).

storage "postgresql" {
  table             = "vault_kv_store"
  ha_table          = "vault_ha_locks"
  skip_create_table = true
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

ui             = true
disable_mlock  = true
