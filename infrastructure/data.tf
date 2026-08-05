locals {
  vms = {
    "master1"  = { id = 100, ip = "10.0.0.100" }
    "master2"  = { id = 101, ip = "10.0.0.101" }
    "master3"  = { id = 102, ip = "10.0.0.102" }
    "worker1"  = { id = 103, ip = "10.0.0.103" }
    "worker2"  = { id = 104, ip = "10.0.0.104" }
    "database" = { id = 105, ip = "10.0.0.105" }

  }
}

data "external" "env" {
  program = ["bash", "${path.module}/read_env.sh"]
}
