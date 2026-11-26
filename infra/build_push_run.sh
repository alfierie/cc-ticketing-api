#!/usr/bin/env bash
# Run ON the EC2 instance (via EC2 Instance Connect), from the repo root:
#   1. build the ticket-api Docker image
#   2. push it to Amazon ECR (auth through the instance profile; no keys on disk)
#   3. start both services (api + db) with Docker Compose and wait for /health
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f /var/tmp/bootstrap-done ]; then
  echo "Waiting for first-boot setup (Docker install) to finish..."
  sudo cloud-init status --wait >/dev/null || true
fi
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/ticket-api"
TAG=$(git rev-parse --short HEAD)

echo "[1/3] Building ticket-api:$TAG"
$DOCKER build -t "ticket-api:$TAG" ./app

echo "[2/3] Pushing to $IMAGE"
aws ecr get-login-password --region "$REGION" | $DOCKER login --username AWS --password-stdin "$REGISTRY"
$DOCKER tag "ticket-api:$TAG" "$IMAGE:$TAG"
$DOCKER tag "ticket-api:$TAG" "$IMAGE:latest"
$DOCKER push "$IMAGE:$TAG"
$DOCKER push "$IMAGE:latest"

echo "[3/3] Starting services with Docker Compose"
if [ ! -f .env ]; then
  umask 077
  cat > .env <<ENV
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
DB_USER=ticket_app
DB_PASSWORD=$(openssl rand -hex 16)
API_IMAGE=$IMAGE:$TAG
ENV
  echo "      generated .env with random DB passwords (not committed)"
else
  sed -i "s#^API_IMAGE=.*#API_IMAGE=$IMAGE:$TAG#" .env
fi
$DOCKER compose up -d

echo -n "      waiting for http://localhost/health "
for _ in $(seq 1 40); do
  if curl -fsS http://localhost/health >/dev/null 2>&1; then echo " up"; break; fi
  echo -n "."; sleep 3
done
$DOCKER compose ps
curl -sS http://localhost/health; echo
echo
aws ecr describe-images --repository-name ticket-api --region "$REGION" \
  --query 'imageDetails[].{tags:imageTags[0],pushedAt:imagePushedAt,sizeMB:imageSizeInBytes}' --output table
