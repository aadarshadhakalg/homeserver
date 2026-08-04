resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


resource "proxmox_vm_qemu" "master_nodes" {
  for_each         = local.vms
  vmid             = each.value.id
  name             = each.key
  target_node      = "pve"
  agent            = 1
  cores            = each.value.id > 2 ? 4 : 2
  memory           = each.value.id > 2 ? 4096 : 2048
  boot             = "order=scsi0"    # has to be the same as the OS disk of the template
  clone            = "alma-cloudinit" # The name of the template
  scsihw           = "virtio-scsi-single"
  vm_state         = "running"
  automatic_reboot = true

  # Cloud-Init configuration
  cicustom   = "vendor=local:snippets/qemu-guest-agent.yml" # /var/lib/vz/snippets/qemu-guest-agent.yml
  ciupgrade  = true
  nameserver = "1.1.1.1 8.8.8.8"
  ipconfig0  = "${each.value.ip}/24,gw=10.0.0.1,ip6=dhcp"
  skip_ipv6  = true
  ciuser     = "root"
  cipassword = random_password.password.result
  sshkeys    = data.external.env.result["SSH_KEY"]

  # Most cloud-init images require a serial device for their display
  serial {
    id = 0
  }

  disks {
    scsi {
      scsi0 {
        # We have to specify the disk from our template, else Terraform will think it's not supposed to be there
        disk {
          storage = "local-lvm"
          # The size of the disk should be at least as big as the disk in the template. If it's smaller, the disk will be recreated
          size = each.value.id > 2 ? "30G" : "20G"
        }
      }
    }
    ide {
      # Some images require a cloud-init disk on the IDE controller, others on the SCSI or SATA controller
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    bridge = "vmbr0"
    model  = "virtio"
  }
}
