# Shared settings for the infra scripts.
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
ECR_REPO="ticket-api"
SG_NAME="ticket-api-sg"
INSTANCE_NAME="ticket-api-host"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"   # Free Tier eligible
ROLE_NAME="ticket-api-ec2-role"
INSTANCE_PROFILE="ticket-api-ec2-profile"
KEY_NAME="${KEY_NAME:-}"   # optional; EC2 Instance Connect needs no key pair
