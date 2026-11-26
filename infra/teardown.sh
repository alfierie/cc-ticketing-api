#!/usr/bin/env bash
# Delete every resource created by deploy.sh (run after grading/screenshots
# so nothing is left in the account).
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
[ "$API_ID" != "None" ] && aws apigatewayv2 delete-api --api-id "$API_ID" && echo "Deleted API $API_ID"
aws lambda delete-function --function-name "$FUNCTION_NAME" && echo "Deleted Lambda $FUNCTION_NAME"
aws dynamodb delete-table --table-name "$TABLE_NAME" >/dev/null && echo "Deleted table $TABLE_NAME"
aws logs delete-log-group --log-group-name "/aws/lambda/$FUNCTION_NAME" 2>/dev/null && echo "Deleted log group /aws/lambda/$FUNCTION_NAME"
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name tickets-api-access 2>/dev/null
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && echo "Deleted IAM role $ROLE_NAME"
