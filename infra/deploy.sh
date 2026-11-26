#!/usr/bin/env bash
# Provision the Ticketing API in AWS Learner Lab (idempotent: safe to re-run).
#   DynamoDB table  ->  Lambda function (LabRole)  ->  API Gateway HTTP API
# Run from the repo root inside the Learner Lab terminal or AWS CloudShell:
#   bash infra/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"   # Learner Lab cannot create IAM roles
echo "Account: $ACCOUNT_ID | Region: $AWS_REGION | Role: $ROLE_ARN"

# ---- 1. DynamoDB table -------------------------------------------------------
if aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  echo "[1/3] DynamoDB table '$TABLE_NAME' already exists"
else
  echo "[1/3] Creating DynamoDB table '$TABLE_NAME' (on-demand billing)"
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=ticketId,AttributeType=S \
    --key-schema AttributeName=ticketId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME"
fi

# ---- 2. Lambda function ------------------------------------------------------
mkdir -p build
python3 -c "import zipfile; z=zipfile.ZipFile('build/function.zip','w',zipfile.ZIP_DEFLATED); z.write('src/app.py','app.py'); z.close()"

if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  echo "[2/3] Updating Lambda code for '$FUNCTION_NAME'"
  aws lambda update-function-code --function-name "$FUNCTION_NAME" \
    --zip-file fileb://build/function.zip >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
else
  echo "[2/3] Creating Lambda function '$FUNCTION_NAME'"
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --handler app.lambda_handler \
    --role "$ROLE_ARN" \
    --zip-file fileb://build/function.zip \
    --timeout 10 --memory-size 128 \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
fi
FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" \
  --query Configuration.FunctionArn --output text)

# ---- 3. API Gateway HTTP API -------------------------------------------------
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ "$API_ID" != "None" ] && [ -n "$API_ID" ]; then
  echo "[3/3] HTTP API '$API_NAME' already exists ($API_ID)"
else
  echo "[3/3] Creating HTTP API '$API_NAME'"
  API_ID=$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    --cors-configuration "AllowOrigins=*,AllowMethods=GET,POST,PUT,DELETE,AllowHeaders=content-type" \
    --query ApiId --output text)

  INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$FUNCTION_ARN" \
    --payload-format-version 2.0 --query IntegrationId --output text)

  for ROUTE in "POST /tickets" "GET /tickets" "GET /tickets/{id}" "PUT /tickets/{id}" "DELETE /tickets/{id}"; do
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$ROUTE" \
      --target "integrations/$INTEGRATION_ID" >/dev/null
    echo "      route: $ROUTE"
  done

  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null

  # Resource-based policy: allow only this API to invoke the function
  aws lambda add-permission --function-name "$FUNCTION_NAME" \
    --statement-id "apigw-invoke-$API_ID" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" >/dev/null
fi

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
echo "$API_URL" > build/api_url.txt
echo
echo "Deployed. Base URL: $API_URL"
echo "Next: bash infra/test_api.sh"
