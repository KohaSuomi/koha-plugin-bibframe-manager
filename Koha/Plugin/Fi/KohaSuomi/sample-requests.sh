#!/usr/bin/env bash
#
# BIBFRAME Manager - sample API requests with curl
#
# Usage:
#   export BASE_URL="http://localhost:8081/api/v1"
#   export TOKEN="<oauth2 bearer token>"
#   export BIBLIO="2"
#   bash sample-requests.sh
#
# To run a single request, copy the curl command you need. All requests are
# independent, so each block works on its own.
#
# Get a token with the client credentials flow:
#   curl -sS -X POST "$BASE_URL/oauth/token" \
#     -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET"

BASE_URL="${BASE_URL:-http://localhost:8081/api/v1}"
TOKEN="${TOKEN:-REPLACE_WITH_TOKEN}"
BIBLIO="${BIBLIO:-2}"

AUTH=(-H "Authorization: Bearer $TOKEN")
JSON=(-H "Content-Type: application/json" -H "Accept: application/json")

# --------------------------------------------------------------------------
echo "### Export stored record as LoC 3-level BIBFRAME 2.0 (JSON)"
curl -sS -X POST "$BASE_URL/contrib/kohasuomi/bibframe/store" \
  "${AUTH[@]}" "${JSON[@]}" \
  --data @- <<JSON
{"method":"biblio_id","biblio_id":${BIBLIO},"standard":"bibframe2","format":"json"}
JSON
echo

# --------------------------------------------------------------------------
echo "### Export stored record as BFFI 4-level WEMI (JSON)"
curl -sS -X POST "$BASE_URL/contrib/kohasuomi/bibframe/store" \
  "${AUTH[@]}" "${JSON[@]}" \
  --data @- <<JSON
{"method":"biblio_id","biblio_id":${BIBLIO},"standard":"bffi","format":"json","base_uri":"http://urn.fi/URN:NBN:fi:bib:"}
JSON
echo

# --------------------------------------------------------------------------
echo "### Export stored record as RDF/XML"
curl -sS -X POST "$BASE_URL/contrib/kohasuomi/bibframe/store" \
  "${AUTH[@]}" "${JSON[@]}" \
  --data @- <<JSON
{"method":"biblio_id","biblio_id":${BIBLIO},"standard":"bibframe2","format":"rdf-xml"}
JSON
echo

# --------------------------------------------------------------------------
echo "### Export a stored resource by resource_id (Turtle)"
curl -sS -X POST "$BASE_URL/contrib/kohasuomi/bibframe/store" \
  "${AUTH[@]}" "${JSON[@]}" \
  --data '{"method":"resource_id","resource_id":1,"standard":"bibframe2","format":"turtle"}'
echo

# --------------------------------------------------------------------------
echo "### Read stored summary (work / instances / agents)"
curl -sS -X GET "$BASE_URL/contrib/kohasuomi/bibframe/summary?biblio_id=${BIBLIO}" \
  "${AUTH[@]}" -H "Accept: application/json"
echo

# --------------------------------------------------------------------------
echo "### Convert a MARC record (biblio) and store it (save_to_db)"
curl -sS -X POST "$BASE_URL/contrib/kohasuomi/bibframe/convert" \
  "${AUTH[@]}" "${JSON[@]}" \
  --data @- <<JSON
{"method":"biblio","biblionumber":${BIBLIO},"standard":"bibframe2","format":"json","save_to_db":true}
JSON
echo
