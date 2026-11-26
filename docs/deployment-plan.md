# Deployment Plan: Ticketing API (Track B: EC2 + Docker + ECR)

## Resources

| Resource | Name | Config |
|---|---|---|
| ECR repository | `ticket-api` | Private, scan on push, tags `<git-sha>` + `latest` |
| Security group | `ticket-api-sg` | In: tcp/80 from 0.0.0.0/0, tcp/22 from the EC2 Instance Connect range only |
| IAM role | `ticket-api-ec2-role` | Trusted by EC2; inline policy: `ecr:GetAuthorizationToken` + push/pull on the `ticket-api` repo only; attached via instance profile `ticket-api-ec2-profile` |
| EC2 instance | `ticket-api-host` | t3.micro (Free Tier eligible), Amazon Linux 2023, default VPC/public subnet, IMDSv2 required |
| Container 1 | `ticket-api` | Image from ECR, Gunicorn on port 8000 → host port 80 |
| Container 2 | `ticket-db` | `mysql:8.0`, volume `db-data`, not published |

Region: `us-east-1`

## Account and budget
- **Account:** a personal AWS account on the **Free plan**, used because Learner Lab access wasn't available. New accounts get $100 in credits at sign-up (up to $200 total). On the Free plan, usage is charged to those credits, not to the card.
- **Cost:** a t3.micro is about $0.0104/hour in `us-east-1`, and ECR private storage is free up to 500 MB/month for new customers (the image is about 60 MB). A full day of testing costs well under $1 of credits.
- **Guardrails:** MFA on the root user, deploy as an IAM admin user (not root), a **zero-spend budget** alert in Billing → Budgets, and `teardown.sh` when finished.

## Steps

### 0. Account setup (one time)
1. Sign up at aws.amazon.com and choose the **Free plan**.
2. Root user → Security credentials → turn on **MFA**.
3. IAM → Users → create `diffie-admin` with console access and the `AdministratorAccess` policy, then sign in as that user from now on.
4. Billing and Cost Management → Budgets → **Create budget** → *Zero spend budget* (sends an email alert).
5. Set the region (top right) to **US East (N. Virginia) us-east-1** and open **CloudShell** (the `>_` icon):
```bash
aws sts get-caller-identity          # screenshot: CLI connectivity
```

### 1. Provision AWS resources (CloudShell)
```bash
git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
bash infra/provision.sh
```
This creates the ECR repository, the IAM role with its instance profile, and the security group, then launches the EC2 instance. User data installs Docker, Docker Compose, and git, which takes about 2 minutes after the instance shows as running.

### 2. Build, push, and run (on the EC2 instance)
EC2 console → Instances → `ticket-api-host` → **Connect** → *EC2 Instance Connect* → **Connect**:
```bash
git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
bash infra/build_push_run.sh
```
Expected output: the image builds, both tags are pushed to ECR, `docker compose ps` shows `ticket-api` and `ticket-db` running (healthy), and `/health` returns `{"status":"ok","database":"up"}`.

### 3. Verify connectivity from outside (CloudShell)
```bash
bash infra/test_api.sh
```
Expected status codes: health `200` → create `201` → list `200` → get `200` → update `200` → invalid body `400` → delete `204` → get `404`.

### 4. Evidence to capture
1. `aws sts get-caller-identity`
2. `provision.sh` output
3. `build_push_run.sh` output: build, push, `docker compose ps`, and health
4. `test_api.sh` output
5. Console: ECR → `ticket-api` → Images (tags and scan status)
6. Console: EC2 → `ticket-api-host` (running, public IP, IAM role, security group)
7. Console: IAM → Roles → `ticket-api-ec2-role` → Permissions (the least-privilege policy)
8. Console: Security group inbound rules
9. Browser: `http://<public-ip>/tickets`

### 5. Teardown
```bash
bash infra/teardown.sh     # terminates EC2; deletes the SG, ECR repo, IAM role + instance profile
```

## Roadmap after Week 12
- Move `ticket-db` to Amazon RDS MySQL (managed backups), keeping the API image unchanged
- Application Load Balancer + HTTPS, with the instance in a private subnet
- GitHub Actions: run tests, build, and push to ECR on every push
