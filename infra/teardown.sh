#!/usr/bin/env bash
# Delete everything provision.sh created (run after grading to save Learner Lab credits).
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$INSTANCE_ID" != "None" ]; then
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
  echo "Terminating $INSTANCE_ID ..."; aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
fi
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
[ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID" && echo "Deleted security group $SG_ID"
aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null && echo "Deleted ECR repository $ECR_REPO (and its images)"
