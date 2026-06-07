variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "k8s-portfolio-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "South Africa North"
}

variable "vm_size" {
  description = "Size of the VMs"
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
  default     = "k8sadmin"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/k8s_portfolio.pub"
}
