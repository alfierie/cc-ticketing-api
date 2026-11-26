#!/usr/bin/env bash
# End-to-end connectivity test: exercises every route against the live API.
#   bash infra/test_api.sh [BASE_URL]      (default: build/api_url.txt from provision.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
BASE_URL="${1:-$(cat build/api_url.txt)}"
echo "Testing $BASE_URL"

req() {  # method path [json-body]
  echo; echo ">>> $1 $2"
  if [ $# -ge 3 ]; then
    curl -s -X "$1" "$BASE_URL$2" -H 'Content-Type: application/json' -d "$3" -w '\nHTTP %{http_code}\n'
  else
    curl -s -X "$1" "$BASE_URL$2" -w '\nHTTP %{http_code}\n'
  fi
}

req GET /health                                    # API <-> MySQL connectivity

OUT=$(req POST /tickets '{"title":"Projector in room E6 not working","description":"No signal from HDMI","priority":"HIGH","requesterName":"Diffie"}')
echo "$OUT"                                        # CREATE -> 201
TICKET_ID=$(echo "$OUT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read().split('\n')[2])['ticketId'])")
echo "Created ticketId = $TICKET_ID"

req GET /tickets                                   # READ list -> 200
req GET "/tickets/$TICKET_ID"                      # READ one  -> 200
req PUT "/tickets/$TICKET_ID" '{"status":"IN_PROGRESS"}'   # UPDATE -> 200
req POST /tickets '{"title":""}'                   # validation -> 400
req DELETE "/tickets/$TICKET_ID"                   # DELETE -> 204
req GET "/tickets/$TICKET_ID"                      # gone -> 404
