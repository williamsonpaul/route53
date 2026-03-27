# Route 53 DNS Management Scripts

Bash scripts for managing Route 53 A records on AWS EC2 instances. Uses IMDSv2 to automatically determine the instance IP and AZ, mapping the AZ to an index to produce a predictable FQDN.

**FQDN format:** `{app-prefix}-{az-index}.{app-suffix}.{domain}`
**Example:** `my-app-0.service.development.mydomain`

AZ index is derived from the availability zone ID (`az1`=0, `az2`=1, `az3`=2).

---

## Scripts

### `update_route53.sh`
Registers the instance's A record on startup. Skips the upsert if the record already exists with the correct IP. Waits up to 10 minutes for DNS propagation to confirm.

### `delete_route53.sh`
Removes the instance's A record on shutdown. Fetches the existing record's TTL from Route 53 to ensure the DELETE request matches exactly.

### `shutdown-hooks.service`
A generic systemd unit that runs all scripts in `/etc/shutdown-hooks.d/` on instance termination (not reboot).

---

## IAM Requirements

The EC2 instance role must have the following Route 53 permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "route53:ListHostedZones",
    "route53:ListResourceRecordSets",
    "route53:ChangeResourceRecordSets"
  ],
  "Resource": "*"
}
```

---

## Setup

### 1. Copy scripts

```bash
sudo mkdir -p /opt/scripts
sudo cp update_route53.sh /opt/scripts/update_route53.sh
sudo cp delete_route53.sh /opt/scripts/delete_route53.sh
sudo chmod +x /opt/scripts/update_route53.sh /opt/scripts/delete_route53.sh
```

### 2. Install the shutdown service

```bash
sudo cp shutdown-hooks.service /etc/systemd/system/shutdown-hooks.service
sudo mkdir -p /etc/shutdown-hooks.d
```

Create a wrapper script for the Route 53 delete (note: `run-parts` requires filenames with no dots):

```bash
sudo tee /etc/shutdown-hooks.d/10-delete-route53 <<'EOF'
#!/usr/bin/env bash
/opt/scripts/delete_route53.sh \
  --app-prefix my-app \
  --app-suffix service \
  --domain development.mydomain \
  --proxy http://proxy.example.com:8080
EOF
sudo chmod +x /etc/shutdown-hooks.d/10-delete-route53
```

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now shutdown-hooks.service
```

### 3. Call `update_route53.sh` on startup

Add to your application's startup script or systemd unit `ExecStartPost`:

```bash
/opt/scripts/update_route53.sh \
  --app-prefix my-app \
  --app-suffix service \
  --domain development.mydomain \
  --proxy http://proxy.example.com:8080
```

---

## Adding further shutdown hooks

Drop any executable script into `/etc/shutdown-hooks.d/`. Use a numeric prefix to control execution order:

```bash
sudo cp my-script.sh /etc/shutdown-hooks.d/20-my-script
sudo chmod +x /etc/shutdown-hooks.d/20-my-script
```

---

## Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `--app-prefix` | First part of the app name (e.g. `my-app`) | Yes |
| `--app-suffix` | Last part of the app name (e.g. `service`) | Yes |
| `--domain` | Hosted zone domain suffix (e.g. `development.mydomain`) | Yes |
| `--proxy` | HTTPS proxy URL | Yes |
| `--ttl` | DNS TTL in seconds (default: 15) — `update_route53.sh` only | No |
