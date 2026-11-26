# Shared settings for the deploy / test / teardown scripts.
export AWS_REGION="${AWS_REGION:-us-east-1}"   # Learner Lab region
export AWS_DEFAULT_REGION="$AWS_REGION"
TABLE_NAME="Tickets"
FUNCTION_NAME="tickets-api-fn"
API_NAME="tickets-api"
