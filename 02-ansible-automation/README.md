# 02 — Ansible Automation

Ansible roles and playbooks for provisioning and maintaining the Kubernetes cluster defined in `01-kubernetes-cluster/`. Covers OS baseline configuration, system patching, and full Kubernetes 1.28 cluster setup across Azure VMs.

---

## Directory Structure

```
01-kubernetes-cluster/terraform/
├── ansible.cfg                         # Ansible configuration
├── inventory/
│   ├── hosts.yml                       # Host definitions and groups
│   └── group_vars/
│       ├── all.yml                     # Vars applied to every host
│       └── k8s.yml                     # Vars scoped to the k8s group
├── playbooks/
│   ├── site.yml                        # Master playbook (patch + common + k8s)
│   ├── patch.yml                       # Patching only, with confirmation prompt
│   └── k8s-setup.yml                   # Kubernetes cluster setup
└── roles/
    ├── common/                         # OS baseline (packages, NTP, hostname, swap)
    │   ├── defaults/main.yml
    │   ├── handlers/main.yml
    │   ├── tasks/main.yml
    │   └── templates/chrony.conf.j2
    ├── patching/                       # Apt/yum upgrades with optional reboot
    │   ├── defaults/main.yml
    │   ├── handlers/main.yml
    │   └── tasks/main.yml
    └── kubernetes/                     # containerd, kubeadm, cluster init, Calico
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── tasks/main.yml
        └── templates/containerd-config.toml.j2
```

---

## Requirements

| Requirement | Version |
|-------------|---------|
| Ansible | >= 2.14 |
| Python | >= 3.9 |
| ansible.posix collection | >= 1.5 |
| community.general collection | >= 7.0 |

Install collections:

```bash
ansible-galaxy collection install ansible.posix community.general
```

SSH key must exist at `~/.ssh/k8s_portfolio` with the corresponding public key deployed to the VMs. After `terraform apply`, update `ansible_host` values in `inventory/hosts.yml` with the IP addresses from Terraform output:

```bash
terraform output controlplane_public_ip
terraform output worker_public_ip
```

---

## Playbooks

### site.yml — Full stack

Runs patching, common baseline, and Kubernetes setup against all hosts in order.

```bash
ansible-playbook playbooks/site.yml
```

### patch.yml — Patching only

Prompts for confirmation, then runs apt/yum upgrades and reboots if required.

```bash
ansible-playbook playbooks/patch.yml
```

To skip the interactive prompt (for CI/CD pipelines):

```bash
ansible-playbook playbooks/patch.yml -e confirm_patch=yes
```

### k8s-setup.yml — Kubernetes setup

Runs common baseline and full Kubernetes setup. Controlplane completes before workers start, ensuring the join command is available.

```bash
ansible-playbook playbooks/k8s-setup.yml
```

---

## Using Tags

Tags let you run a subset of tasks without a separate playbook.

| Tag | What it runs |
|-----|-------------|
| `common` | OS baseline tasks only (packages, NTP, hostname, swap) |
| `patching` | Patching tasks only |
| `kubernetes` or `k8s` | Kubernetes tasks only |
| `always` | Tasks that always run regardless of `--tags` |

Run only common baseline:

```bash
ansible-playbook playbooks/site.yml --tags common
```

Run only Kubernetes tasks:

```bash
ansible-playbook playbooks/site.yml --tags k8s
```

Skip patching and run everything else:

```bash
ansible-playbook playbooks/site.yml --skip-tags patching
```

---

## Check Mode (Dry Run)

Check mode reports what would change without making any changes. Use it before applying to production.

```bash
# Dry run the full site playbook
ansible-playbook playbooks/site.yml --check

# Dry run with diff output to see file content changes
ansible-playbook playbooks/site.yml --check --diff

# Dry run a specific role via tags
ansible-playbook playbooks/site.yml --tags k8s --check --diff
```

> Note: Some tasks use `ansible.builtin.command` which cannot be predicted in check mode and will be skipped. The `creates:` guard on those tasks will still be evaluated.

---

## Targeting Specific Hosts or Groups

```bash
# Run against the controlplane only
ansible-playbook playbooks/site.yml --limit controlplane

# Run against a single host
ansible-playbook playbooks/site.yml --limit k8s-worker

# Run against the k8s group
ansible-playbook playbooks/site.yml --limit k8s
```

---

## Useful Ad-hoc Commands

```bash
# Test connectivity to all hosts
ansible all -m ping

# Check uptime on all k8s nodes
ansible k8s -m command -a "uptime"

# Verify swap is off
ansible k8s -m command -a "swapon --show"

# Check kubelet status on controlplane
ansible controlplane -m service_facts -a "" | grep kubelet
```
