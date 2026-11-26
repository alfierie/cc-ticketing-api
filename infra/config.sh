# Shared settings for the deploy / test / teardown scripts.
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"   # Region selected for the AWS project
export AWS_DEFAULT_REGION="$AWS_REGION"
TABLE_NAME="Tickets"
FUNCTION_NAME="tickets-api-fn"
API_NAME="tickets-api"
ROLE_NAME="tickets-api-lambda-role"
