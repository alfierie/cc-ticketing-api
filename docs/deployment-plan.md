# Deployment Plan: Ticketing API (Track C, Serverless)

## Account and budget
- **Account:** a personal AWS account on the **Free plan**, used because Learner Lab access wasn't available. New accounts get $100 in credits at sign-up (up to $200 total), and on the Free plan, usage is charged to those credits, not to the card.
- **Cost:** all three services are pay-per-request, so an idle deployment costs about $0. Lambda and DynamoDB have always-free monthly allowances, and the test run's handful of API Gateway calls costs a fraction of a cent.
- **Guardrails:** MFA on the root user, deploy as an IAM admin user (not root), a **zero-spend budget** alert in Billing → Budgets, and `teardown.sh` when finished.

| Resource | Name | Config |
|---|---|---|
| DynamoDB table | `Tickets` | PK `ticketId` (S), PAY_PER_REQUEST |
| IAM role | `tickets-api-lambda-role` | Trusted by Lambda; inline policy: CRUD on the `Tickets` table + its own log group only |
| Lambda function | `tickets-api-fn` | python3.12, 128 MB, 10 s timeout, role `tickets-api-lambda-role`, env `TABLE_NAME=Tickets` |
| API Gateway | `tickets-api` | HTTP API, AWS_PROXY → Lambda (payload 2.0), 5 routes, `$default` stage with auto-deploy |
| Logs | `/aws/lambda/tickets-api-fn` | CloudWatch Logs, created automatically |

Region: `us-east-1`

## Steps

### 0. Account setup (one time)
1. Sign up at aws.amazon.com and choose the **Free plan**.
2. Root user → Security credentials → turn on **MFA**.
3. IAM → Users → create `diffie-admin` with console access and the `AdministratorAccess` policy, then sign in as that user from now on.
4. Billing and Cost Management → Budgets → **Create budget** → *Zero spend budget* (sends an email alert).
5. Set the region (top right) to **US East (N. Virginia) us-east-1** and open **CloudShell** (the `>_` icon). CloudShell already has the AWS CLI, git, and Python. Check with:
   `aws sts get-caller-identity` (screenshot this: it proves CLI connectivity)

### 1. Get the code
```bash
git clone https://github.com/alfierie/cc-ticketing-api.git
cd cc-ticketing-api
python3 -m unittest discover -s tests -v      # optional sanity check
```

### 2. Provision
```bash
bash infra/deploy.sh
```
The script does the following, in order:
1. Creates the `Tickets` table and waits until it's ACTIVE
2. Creates the IAM role `tickets-api-lambda-role` from `infra/iam/` (trust policy + least-privilege inline policy)
3. Zips `src/app.py` and creates the Lambda function with that role
4. Creates the HTTP API, the Lambda proxy integration, 5 routes, an auto-deploy `$default` stage, and the invoke permission
5. Prints the base URL and saves it to `build/api_url.txt`

It's safe to re-run: existing resources are detected, the role policy is re-applied, and only the Lambda code gets updated.

### 3. Verify connectivity
```bash
bash infra/test_api.sh
```
Expected: `201` create → `200` list → `200` get → `200` update → `400` invalid body → `204` delete → `404` after delete.

### 4. Evidence to capture
1. `aws sts get-caller-identity` output
2. `deploy.sh` output showing the base URL
3. `test_api.sh` output (all status codes)
4. Console: DynamoDB → Tickets → *Explore items* (with a ticket present; run only the POST from the test first)
5. Console: Lambda → tickets-api-fn (function overview showing the API Gateway trigger)
   and Configuration → Permissions (the execution role and its DynamoDB/Logs access)
6. Console: API Gateway → tickets-api → Routes
7. Console: CloudWatch → Log groups → `/aws/lambda/tickets-api-fn` → latest log stream

### 5. Teardown
```bash
bash infra/teardown.sh     # deletes the API, function, table, log group, and IAM role
```

## Console fallback (no CLI)
1. **DynamoDB** → Create table → name `Tickets`, partition key `ticketId` (String) → table settings: Customize → On-demand.
2. **Lambda** → Create function → Author from scratch → `tickets-api-fn`, Python 3.12 → Execution role: *Create a new role with basic Lambda permissions*, then in IAM add an inline policy from `infra/iam/lambda-access-policy.json` (with the real table ARN).
   Paste `src/app.py` into `lambda_function.py`, set Handler to `lambda_function.lambda_handler`, add env var `TABLE_NAME=Tickets`, then Deploy.
3. **API Gateway** → Create API → HTTP API → Integration: Lambda `tickets-api-fn` → add the 5 routes → stage `$default` (auto-deploy).

## Roadmap after Week 12
- Cognito user pool + JWT authorizer (only authenticated users can create or update tickets)
- GSI on `status` so tickets can be listed by status without a Scan
- CI pipeline: run unit tests on every push (GitHub Actions)
