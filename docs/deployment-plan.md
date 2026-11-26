# Deployment Plan: Ticketing API (Track B: EC2 + Docker + ECR)

## Resources

| Resource | Name | Config |
|---|---|---|
| ECR repository | `ticket-api` | Private, scan on push, tags `<git-sha>` + `latest` |
| Security group | `ticket-api-sg` | In: tcp/80 from 0.0.0.0/0, tcp/22 from the EC2 Instance Connect range only |
| EC2 instance | `ticket-api-host` | t3.micro, Amazon Linux 2023, default VPC/public subnet, `LabInstanceProfile`, IMDSv2 required |
| Container 1 | `ticket-api` | Image from ECR, Gunicorn on port 8000 → host port 80 |
| Container 2 | `ticket-db` | `mysql:8.0`, volume `db-data`, not published |

Region: `us-east-1`

## Budget
A t3.micro costs about $0.01/hour, and Learner Lab stops it automatically when the session ends. ECR storage for one image of about 60 MB is around $0.01/month.
Run `teardown.sh` after grading and click **End Lab** when you're done.

## Steps

### 0. Start the lab
AWS Academy → Learner Lab → **Start Lab** → wait for the green dot. Then, in the lab terminal:
```bash
aws sts get-caller-identity          # screenshot: CLI connectivity
```

### 1. Provision AWS resources (lab terminal or CloudShell)
```bash
git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
bash infra/provision.sh
```
This creates the ECR repository and the security group, then launches the EC2 instance. User data installs Docker, Docker Compose, and git, which takes about 2 minutes after the instance shows as running.

### 2. Build, push, and run (on the EC2 instance)
EC2 console → Instances → `ticket-api-host` → **Connect** → *EC2 Instance Connect* → **Connect**:
```bash
git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
bash infra/build_push_run.sh
```
Expected output: the image builds, both tags are pushed to ECR, `docker compose ps` shows `ticket-api` and `ticket-db` running (healthy), and `/health` returns `{"status":"ok","database":"up"}`.

### 3. Verify connectivity from outside (lab terminal)
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
7. Console: Security group inbound rules
8. Browser: `http://<public-ip>/tickets`

### 5. Teardown
```bash
bash infra/teardown.sh     # terminates EC2, deletes the security group and the ECR repo
```

## Roadmap after Week 12
- Move `ticket-db` to Amazon RDS MySQL (managed backups), keeping the API image unchanged
- Application Load Balancer + HTTPS, with the instance in a private subnet
- GitHub Actions: run tests, build, and push to ECR on every push
