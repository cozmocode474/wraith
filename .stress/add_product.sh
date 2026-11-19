#!/usr/bin/env bash
# add_product.sh <token> <url>: the two-step add the UI does. Prints "<http code> <price>".
set -u
tok=$1; url=$2; B=http://localhost/api
r=$(curl -s -w '\n%{http_code}' -X POST "$B/products" -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d "{\"url\":\"$url\"}")
code=$(tail -1 <<<"$r"); body=$(sed '$d' <<<"$r")
if [ "$code" = 200 ] && jq -e .needsReview >/dev/null 2>&1 <<<"$body"; then
  sel=$(jq -c --arg u "$url" '((.priceCandidates | map(select(.method=="json-ld"))) + .priceCandidates)[0] | {url:$u, selectedPrice:.price, selectedMethod:.method}' <<<"$body")
  r=$(curl -s -w '\n%{http_code}' -X POST "$B/products" -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d "$sel")
  code=$(tail -1 <<<"$r"); body=$(sed '$d' <<<"$r")
fi
echo "$code $(jq -r '.current_price // .error // "-"' <<<"$body" 2>/dev/null || echo '?')"
