# Deployment Plan: Ticketing API (Track C, Serverless)

## Budget strategy
All three services are pay-per-use, so an idle deployment costs roughly $0. DynamoDB is on-demand,
Lambda is billed per request, and the HTTP API is billed per million requests. The only thing that wastes credits
is leaving the lab session running. Even so, `teardown.sh` removes everything after grading.

| Resource | Name | Config |
|---|---|---|
| DynamoDB table | `Tickets` | PK `ticketId` (S), PAY_PER_REQUEST |
| Lambda function | `tickets-api-fn` | python3.12, 128 MB, 10 s timeout, role `LabRole`, env `TABLE_NAME=Tickets` |
| API Gateway | `tickets-api` | HTTP API, AWS_PROXY → Lambda (payload 2.0), 5 routes, `$default` stage with auto-deploy |
| Logs | `/aws/lambda/tickets-api-fn` | CloudWatch Logs, created automatically |

Region: `us-east-1`

## Steps

### 0. Prerequisites
- AWS Academy Learner Lab: **Start Lab**, wait for the green dot, then open **AWS** (console) and the lab terminal.
- The lab terminal already has AWS CLI credentials set up. Check with:
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
2. Zips `src/app.py` and creates the Lambda function with `LabRole`
3. Creates the HTTP API, the Lambda proxy integration, 5 routes, an auto-deploy `$default` stage, and the invoke permission
4. Prints the base URL and saves it to `build/api_url.txt`

It's safe to re-run: existing resources are detected, and only the Lambda code gets updated.

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
6. Console: API Gateway → tickets-api → Routes
7. Console: CloudWatch → Log groups → `/aws/lambda/tickets-api-fn` → latest log stream

### 5. Teardown
```bash
bash infra/teardown.sh
```
Then click **End Lab**.

## Console fallback (no CLI)
1. **DynamoDB** → Create table → name `Tickets`, partition key `ticketId` (String) → table settings: Customize → On-demand.
2. **Lambda** → Create function → Author from scratch → `tickets-api-fn`, Python 3.12 → Execution role: *Use an existing role* → `LabRole`.
   Paste `src/app.py` into `lambda_function.py`, set Handler to `lambda_function.lambda_handler`, add env var `TABLE_NAME=Tickets`, then Deploy.
3. **API Gateway** → Create API → HTTP API → Integration: Lambda `tickets-api-fn` → add the 5 routes → stage `$default` (auto-deploy).

## Roadmap after Week 12
- Cognito user pool + JWT authorizer (only authenticated users can create or update tickets)
- GSI on `status` so tickets can be listed by status without a Scan
- CI pipeline: run unit tests on every push (GitHub Actions)
