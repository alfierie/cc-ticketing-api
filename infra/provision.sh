#!/usr/bin/env bash
# Provision AWS resources for Track B (idempotent: safe to re-run).
#   1. ECR repository   ticket-api (scan on push)
#   2. IAM role         ticket-api-ec2-role + instance profile (ECR login + push/pull on ticket-api only)
#   3. Security group   ticket-api-sg (HTTP 80 from anywhere, SSH 22 only from EC2 Instance Connect)
#   4. EC2 instance     ticket-api-host (Amazon Linux 2023 t3.micro, Docker via user data)
# Run from the repo root in AWS CloudShell (or any shell with admin AWS credentials):
#   bash infra/provision.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
mkdir -p build

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# ---- 1. ECR repository ------------------------------------------------------
if aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  echo "[1/4] ECR repository '$ECR_REPO' already exists"
else
  echo "[1/4] Creating ECR repository '$ECR_REPO'"
  aws ecr create-repository --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true >/dev/null
fi
ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO" \
  --query 'repositories[0].repositoryUri' --output text)

# ---- 2. IAM role + instance profile (least privilege) -------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[2/4] IAM role '$ROLE_NAME' already exists"
else
  echo "[2/4] Creating IAM role '$ROLE_NAME' (trusted by EC2)"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://infra/iam/ec2-trust-policy.json \
    --description "ticket-api EC2 host: ECR login and push/pull on the ticket-api repo only" >/dev/null
fi
REPO_ARN="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}"
sed "s#__REPO_ARN__#${REPO_ARN}#" infra/iam/ecr-access-policy.json > build/ecr-access-policy.json
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name ticket-api-ecr-access \
  --policy-document file://build/ecr-access-policy.json
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$ROLE_NAME"
  echo "      created instance profile '$INSTANCE_PROFILE'"
fi

# ---- 3. Security group (default VPC) ----------------------------------------
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  echo "[3/4] Creating security group '$SG_NAME' in $VPC_ID"
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
  echo "[3/4] Security group '$SG_NAME' already exists ($SG_ID)"
fi

# ---- 4. EC2 instance --------------------------------------------------------
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
  if [ -n "$KEY_NAME" ]; then KEY_ARGS=(--key-name "$KEY_NAME"); fi
  echo "[4/4] Launching $INSTANCE_TYPE '$INSTANCE_NAME' from $AMI_ID"
  # a new instance profile can take a few seconds to become usable, so retry
  for attempt in 1 2 3 4 5 6; do
    if INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
      --security-group-ids "$SG_ID" \
      --iam-instance-profile Name="$INSTANCE_PROFILE" \
      --metadata-options HttpTokens=required \
      --user-data file://infra/user-data.sh \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=cc-ticketing-api}]" \
      --query 'Instances[0].InstanceId' --output text 2>build/run-instances.err); then
      break
    fi
    if [ "$attempt" = 6 ] || ! grep -q "Invalid IAM Instance Profile" build/run-instances.err; then
      cat build/run-instances.err >&2; exit 1
    fi
    echo "      instance profile not ready yet, retrying in 10s..."; sleep 10
  done
else
  echo "[4/4] Instance '$INSTANCE_NAME' already exists ($INSTANCE_ID); starting it if stopped"
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "http://$PUBLIC_IP" > build/api_url.txt
cat <<SUMMARY

Provisioned.
  ECR repository : $ECR_URI
  IAM role       : $ROLE_NAME (instance profile $INSTANCE_PROFILE)
  Security group : $SG_ID
  EC2 instance   : $INSTANCE_ID  ($INSTANCE_TYPE, public IP $PUBLIC_IP)

Next (wait ~2 minutes for Docker to install):
  EC2 console -> $INSTANCE_NAME -> Connect -> EC2 Instance Connect -> Connect, then run:
    git clone https://github.com/alfierie/cc-ticketing-api.git && cd cc-ticketing-api
    bash infra/build_push_run.sh
SUMMARY
