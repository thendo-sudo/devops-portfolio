# Infrastructure as Code — Azure Kubernetes Cluster

Terraform configuration that provisions a two-node Kubernetes cluster on Azure. All resources are defined declaratively and can be stood up or torn down with a single command.

---

## What It Provisions

| Resource | Name | Details |
|---|---|---|
| Resource Group | `k8s-portfolio-rg` | Logical container for all resources |
| Virtual Network | `k8s-vnet` | Address space `10.0.0.0/16` |
| Subnet | `k8s-subnet` | `10.0.1.0/24` |
| Network Security Group | `k8s-nsg` | Rules for SSH (443), Kubernetes API (6443) |
| Public IP — Control Plane | `k8s-controlplane-pip` | Static, Standard SKU |
| Public IP — Worker | `k8s-worker-pip` | Static, Standard SKU |
| Network Interface — Control Plane | `k8s-controlplane-nic` | Attached to subnet + public IP |
| Network Interface — Worker | `k8s-worker-nic` | Attached to subnet + public IP |
| Linux VM — Control Plane | `k8s-controlplane` | Ubuntu 22.04 LTS Gen2, SSH on port 443 |
| Linux VM — Worker | `k8s-worker` | Ubuntu 22.04 LTS Gen2 |

Both VMs run **Ubuntu 22.04 LTS (Jammy)** and are sized at `Standard_B2s_v2` by default. The control plane VM has a custom script extension that reconfigures SSH to listen on port 443 instead of 22.

---

## Directory Structure

```
devops-portfolio/
└── 01-kubernetes-cluster/
    └── terraform/
        ├── providers.tf          # AzureRM provider, Terraform version constraint
        ├── variables.tf          # Input variable declarations
        ├── main.tf               # All resource definitions
        ├── outputs.tf            # Public IPs and SSH connection strings
        ├── k8s-setup-controlplane.sh   # Post-provision kubeadm bootstrap script
        └── k8s-setup-worker.sh         # Post-provision worker join script
```

The Terraform configuration lives in [01-kubernetes-cluster/terraform/](../01-kubernetes-cluster/terraform/).

---

## Prerequisites

| Tool | Minimum Version | Purpose |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `>= 1.0` | Provision and manage infrastructure |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | any recent | Authenticate to Azure |
| SSH key pair | — | Passwordless VM access |

### Authenticate to Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### Generate an SSH key pair (if you don't have one)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k8s_portfolio -C "k8s-portfolio"
```

The default `ssh_public_key_path` variable points to `~/.ssh/k8s_portfolio.pub`. Override it if your key lives elsewhere.

---

## Usage

All commands run from the `01-kubernetes-cluster/terraform/` directory.

```bash
cd 01-kubernetes-cluster/terraform/
```

### 1. Initialize

Downloads the AzureRM provider plugin.

```bash
terraform init
```

### 2. Plan

Previews what will be created, modified, or destroyed — no changes are made.

```bash
terraform plan
```

To override a variable at plan time:

```bash
terraform plan -var="vm_size=Standard_B4ms"
```

### 3. Apply

Creates all resources. Confirm the prompt with `yes`.

```bash
terraform apply
```

After apply completes, Terraform prints the outputs (public IPs and SSH commands).

### 4. Destroy

Tears down every resource managed by this configuration.

```bash
terraform destroy
```

> Run `destroy` when the cluster is not in use to avoid unnecessary compute charges.

---

## Variables Reference

| Name | Description | Default |
|---|---|---|
| `resource_group_name` | Name of the Azure resource group | `k8s-portfolio-rg` |
| `location` | Azure region | `South Africa North` |
| `vm_size` | VM SKU for both nodes | `Standard_B2s_v2` |
| `admin_username` | Linux admin user on both VMs | `k8sadmin` |
| `ssh_public_key_path` | Filesystem path to your SSH public key | `~/.ssh/k8s_portfolio.pub` |

Override any variable via `-var` flag or a `terraform.tfvars` file:

```hcl
# terraform.tfvars
location            = "West Europe"
vm_size             = "Standard_B4ms"
ssh_public_key_path = "~/.ssh/id_rsa.pub"
```

---

## Outputs Reference

| Name | Description |
|---|---|
| `controlplane_public_ip` | Public IP address of the control plane node |
| `worker_public_ip` | Public IP address of the worker node |
| `ssh_controlplane` | Ready-to-run SSH command for the control plane node |
| `ssh_worker` | Ready-to-run SSH command for the worker node |

Retrieve outputs at any time without re-applying:

```bash
terraform output
```

---

## Cost Management

**`Standard_B2s_v2` pricing** (South Africa North, as of 2025): approximately **$0.05–$0.07 USD/hour per VM**. Running both nodes 24/7 costs roughly **$70–$100/month**.

Tips to keep costs low:

- **Destroy when idle** — `terraform destroy` removes all billable compute resources. State is preserved locally so you can re-provision in minutes.
- **Deallocate instead of destroy** — if you want to preserve VM state between sessions, deallocate via the Azure CLI (`az vm deallocate`) to stop compute billing while retaining disks and public IPs. Note that Standard Public IPs still incur a small charge when allocated but detached from a running VM.
- **Use `Standard_B2s_v2` or smaller** — the B-series burstable SKUs are the most cost-effective for workloads that are idle most of the time.
- **Pick a nearby region** — data egress costs vary by region; `South Africa North` prices differ from `West Europe` or `East US`.

---

## Security Notes

### SSH key authentication only

Password authentication is disabled. The `admin_ssh_key` block in `main.tf` enforces key-based login. Never add `disable_password_authentication = false` unless required for a specific reason.

### SSH on port 443

The control plane VM's custom script extension reconfigures `sshd` to listen on port 443 instead of 22. This allows SSH traffic through firewalls that block non-standard ports and reduces automated scanner noise on port 22.

### NSG rules and source IP restriction

The NSG restricts inbound SSH (port 443) and HTTPS access to a single source IP. Before deploying, update the `source_address_prefix` values in `main.tf` to your own public IP:

```hcl
# main.tf — security_rule blocks
source_address_prefix = "<your-public-ip>"   # e.g. "203.0.113.42"
```

Find your current public IP:

```bash
curl -s https://checkip.amazonaws.com
```

The Kubernetes API server port (6443) is open to `*` to allow `kubectl` access from anywhere. Restrict this to your IP as well for tighter security:

```hcl
security_rule {
  name                  = "allow-k8s-api"
  source_address_prefix = "<your-public-ip>"
  ...
}
```
