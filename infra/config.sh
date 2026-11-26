# Shared settings for the infra scripts.
export AWS_REGION="${AWS_REGION:-us-east-1}"   # Learner Lab region
export AWS_DEFAULT_REGION="$AWS_REGION"
ECR_REPO="ticket-api"
SG_NAME="ticket-api-sg"
INSTANCE_NAME="ticket-api-host"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
INSTANCE_PROFILE="LabInstanceProfile"   # Learner Lab's pre-made profile (wraps LabRole)
KEY_NAME="vockey"                        # Learner Lab's default key pair (optional)
