
terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc08"
    }
  }

  cloud {

    organization = "aadarshadhakalg"

    workspaces {
      name = "homeserver"
    }
  }
}


