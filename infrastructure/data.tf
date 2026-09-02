locals {
  # Sizing is explicit per VM: the previous `id > 2` ternaries were always true
  # (every id is >= 100), so every VM silently got the same shape.
  vms = {
    "master1"  = { id = 100, ip = "10.0.0.100", cores = 4, memory = 4096, disk = "30G" }
    "master2"  = { id = 101, ip = "10.0.0.101", cores = 4, memory = 4096, disk = "30G" }
    "master3"  = { id = 102, ip = "10.0.0.102", cores = 4, memory = 4096, disk = "30G" }
    "worker1"  = { id = 103, ip = "10.0.0.103", cores = 4, memory = 4096, disk = "30G" }
    "worker2"  = { id = 104, ip = "10.0.0.104", cores = 4, memory = 4096, disk = "30G" }
    "database" = { id = 105, ip = "10.0.0.105", cores = 4, memory = 4096, disk = "30G" }
    # NFS export for media PVCs and the Harbor registry blob store.
    "storage" = { id = 106, ip = "10.0.0.106", cores = 2, memory = 4096, disk = "100G" }
  }
}

data "external" "env" {
  program = ["bash", "${path.module}/read_env.sh"]
}
