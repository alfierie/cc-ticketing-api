#!/usr/bin/env bash
# Delete every resource created by deploy.sh (do this after grading/screenshots
# to protect your Learner Lab budget).
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
[ "$API_ID" != "None" ] && aws apigatewayv2 delete-api --api-id "$API_ID" && echo "Deleted API $API_ID"
aws lambda delete-function --function-name "$FUNCTION_NAME" && echo "Deleted Lambda $FUNCTION_NAME"
aws dynamodb delete-table --table-name "$TABLE_NAME" >/dev/null && echo "Deleted table $TABLE_NAME"
