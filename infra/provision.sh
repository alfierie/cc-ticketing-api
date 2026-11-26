#!/usr/bin/env bash
# Provision AWS resources for Track B (idempotent: safe to re-run).
#   1. ECR repository   ticket-api (scan on push)
#   2. Security group   ticket-api-sg (HTTP 80 from anywhere, SSH 22 only from EC2 Instance Connect)
#   3. EC2 instance     ticket-api-host (Amazon Linux 2023, LabInstanceProfile, Docker via user data)
# Run from the repo root in the Learner Lab terminal or AWS CloudShell:  bash infra/provision.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
mkdir -p build

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# ---- 1. ECR repository ------------------------------------------------------
if aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  echo "[1/3] ECR repository '$ECR_REPO' already exists"
else
  echo "[1/3] Creating ECR repository '$ECR_REPO'"
  aws ecr create-repository --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true >/dev/null
fi
ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO" \
  --query 'repositories[0].repositoryUri' --output text)

# ---- 2. Security group (default VPC) ----------------------------------------
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  echo "[2/3] Creating security group '$SG_NAME' in $VPC_ID"
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "ticket-api: HTTP from internet, SSH from EC2 Instance Connect only" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  EIC_CIDR=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(next(p['ip_prefix'] for p in data['prefixes']
           if p['service'] == 'EC2_INSTANCE_CONNECT' and p['region'] == '$AWS_REGION'))")
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$EIC_CIDR" >/dev/null
  echo "      inbound: tcp/80 from 0.0.0.0/0, tcp/22 from $EIC_CIDR (EC2 Instance Connect)"
else
  echo "[2/3] Security group '$SG_NAME' already exists ($SG_ID)"
fi

# ---- 3. EC2 instance --------------------------------------------------------
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$INSTANCE_ID" = "None" ]; then
  AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text 2>/dev/null || \
    aws ec2 describe-images --owners amazon \
      --filters "Name=name,Values=al2023-ami-2023.*-kernel-*-x86_64" Name=state,Values=available \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  KEY_ARGS=()
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then KEY_ARGS=(--key-name "$KEY_NAME"); fi
  echo "[3/3] Launching $INSTANCE_TYPE '$INSTANCE_NAME' from $AMI_ID"
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile Name="$INSTANCE_PROFILE" \
    --metadata-options HttpTokens=required \
    --user-data file://infra/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=cc-ticketing-api}]" \
    --query 'Instances[0].InstanceId' --output text)
else
  echo "[3/3] Instance '$INSTANCE_NAME' already exists ($INSTANCE_ID); starting it if stopped"
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "http://$PUBLIC_IP" > build/api_url.txt
cat <<SUMMARY

Provisioned.
  ECR repository : $ECR_URI
  Security group : $SG_ID
  EC2 instance   : $INSTANCE_ID  ($INSTANCE_TYPE, public IP $PUBLIC_IP)

Next (wait ~2 minutes for Docker to install):
  EC2 console -> $INSTANCE_NAME -> Connect -> EC2 Instance Connect -> Connect, then run:
    git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
    bash infra/build_push_run.sh
SUMMARY
