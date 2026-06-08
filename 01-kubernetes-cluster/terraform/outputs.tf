output "controlplane_public_ip" {
  description = "Public IP address of the control plane node"
  value       = azurerm_public_ip.controlplane.ip_address
}

output "worker_public_ip" {
  description = "Public IP address of the worker node"
  value       = azurerm_public_ip.worker.ip_address
}

output "ssh_controlplane" {
  description = "SSH command to connect to the control plane node"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.controlplane.ip_address}"
}

output "ssh_worker" {
  description = "SSH command to connect to the worker node"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.worker.ip_address}"
}
