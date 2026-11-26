#!/usr/bin/env bash
# Provision the Ticketing API (idempotent: safe to re-run).
#   DynamoDB table -> IAM execution role -> Lambda function -> API Gateway HTTP API
# Run from the repo root in AWS CloudShell (signed in as an IAM admin user):
#   bash infra/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID | Region: $AWS_REGION"
mkdir -p build

# ---- 1. DynamoDB table -------------------------------------------------------
if aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  echo "[1/4] DynamoDB table '$TABLE_NAME' already exists"
else
  echo "[1/4] Creating DynamoDB table '$TABLE_NAME' (on-demand billing)"
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=ticketId,AttributeType=S \
    --key-schema AttributeName=ticketId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME"
fi

# ---- 2. IAM execution role (least privilege) ---------------------------------
TABLE_ARN="arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
LOG_GROUP_ARN="arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${FUNCTION_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[2/4] IAM role '$ROLE_NAME' already exists"
else
  echo "[2/4] Creating IAM role '$ROLE_NAME' (trusted by Lambda)"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://infra/iam/lambda-trust-policy.json \
    --description "tickets-api-fn: CRUD on the Tickets table + its own logs only" >/dev/null
fi
sed -e "s#__TABLE_ARN__#${TABLE_ARN}#" -e "s#__LOG_GROUP_ARN__#${LOG_GROUP_ARN}#g" \
  infra/iam/lambda-access-policy.json > build/lambda-access-policy.json
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name tickets-api-access \
  --policy-document file://build/lambda-access-policy.json
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

# ---- 3. Lambda function ------------------------------------------------------
python3 -c "import zipfile; z=zipfile.ZipFile('build/function.zip','w',zipfile.ZIP_DEFLATED); z.write('src/app.py','app.py'); z.close()"

if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  echo "[3/4] Updating Lambda code for '$FUNCTION_NAME'"
  aws lambda update-function-code --function-name "$FUNCTION_NAME" \
    --zip-file fileb://build/function.zip >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
else
  echo "[3/4] Creating Lambda function '$FUNCTION_NAME'"
  # a brand-new role takes a few seconds before Lambda can assume it, so retry
  for attempt in 1 2 3 4 5 6; do
    if aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime python3.12 \
      --handler app.lambda_handler \
      --role "$ROLE_ARN" \
      --zip-file fileb://build/function.zip \
      --timeout 10 --memory-size 128 \
      --environment "Variables={TABLE_NAME=$TABLE_NAME}" >/dev/null 2>build/create-function.err; then
      break
    fi
    if [ "$attempt" = 6 ] || ! grep -q "cannot be assumed" build/create-function.err; then
      cat build/create-function.err >&2; exit 1
    fi
    echo "      role not ready yet, retrying in 10s..."; sleep 10
  done
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
fi
FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" \
  --query Configuration.FunctionArn --output text)

# ---- 4. API Gateway HTTP API -------------------------------------------------
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ "$API_ID" != "None" ] && [ -n "$API_ID" ]; then
  echo "[4/4] HTTP API '$API_NAME' already exists ($API_ID)"
else
  echo "[4/4] Creating HTTP API '$API_NAME'"
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
