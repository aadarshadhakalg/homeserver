provider "proxmox" {
  pm_api_url          = "https://100.79.85.44:8006/api2/json"
  pm_tls_insecure     = true
  pm_api_token_id     = data.external.env.result["PM_API_TOKEN_ID"]
  pm_api_token_secret = data.external.env.result["PM_API_TOKEN_SECRET"]
}
