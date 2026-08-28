# Runbook 4 — Connecting to validation-storage

## Purpose
SSH access to the validation-storage VM for debugging XRootD/Teapot
config, container logs, or scitokens issues in place, without a
Terraform apply cycle.

## Prerequisites
- `roles/compute.osLogin` (read-only) or `roles/compute.osAdminLogin`
  (sudo-capable) on the target project — granted via
  `deploy/terraform/bootstrap`'s `os_login_admins` variable. OS Login
  is enabled project-wide; metadata SSH keys are not used and won't
  work.
- `gcloud` authenticated (`gcloud auth login`), with access to the
  target project.

## Connect

```bash
gcloud compute ssh dep-dlm-<env>-validation-storage \
  --zone=<zone> \
  --project=<project_id> \
  --tunnel-through-iap

# e.g.
gcloud compute ssh dep-dlm-staging-validation-storage \
  --zone=europe-west3-b \
  --project=dep-dlm-staging-e52e0d90 \
  --tunnel-through-iap
```

`--tunnel-through-iap` is required — the VM's firewall only allows
port 22 from Google's fixed IAP range (`35.235.240.0/20`), not
`0.0.0.0/0` (see `deploy/terraform/modules/validation-storage/main.tf`'s
`validation_storage_iap_ssh` firewall rule).

First connection auto-provisions your OS Login home directory
(`/home/<your_email_with_underscores>`) — no key generation step.

## Common gotcha: `docker` needs `sudo`

The startup-script runs Docker Compose as root; your OS Login user
isn't in the `docker` group:

```bash
docker ps      # permission denied: dial unix /var/run/docker.sock
sudo docker ps # works
```

See `docs/troubleshooting.md` for this and related symptoms.

## Useful commands once connected

```bash
sudo docker ps
sudo docker logs <container> --tail 50
sudo cat /etc/validation-storage/config/xrootd/xrdrucio-scitokens.cfg
sudo cat /etc/validation-storage/config/xrootd/scitokens.conf
sudo cat /etc/validation-storage/config/teapot/application.yml
```
