#!/usr/bin/env bash
# End-to-end stress test of a running Wraith stack on http://localhost.
set -u
B=http://localhost; A=$B/api; FAIL=0
pass(){ echo "PASS  $*"; }
fail(){ echo "FAIL  $*"; FAIL=1; }
expect(){ if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got '$2', want '$3'"; fi; }
codes(){ sort | uniq -c | awk '{printf "%sx%s ", $1, $2}'; }
json(){ curl -s -H 'content-type: application/json' "$@"; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
sql(){ docker exec wraith-db psql -U postgres -d wraith -tAc "$1"; }

echo "== Waiting for the stack"
for i in $(seq 1 120); do [ "$(code $A/auth/registration-status)" = 200 ] && break; sleep 2; done
expect "API reachable through the frontend proxy" "$(code $A/auth/registration-status)" 200

echo "== Branding"
html=$(curl -s $B/)
if grep -q '<title>Wraith' <<<"$html"; then pass "page title"; else fail "page title"; fi
expect "manifest name" "$(curl -s $B/manifest.json | jq -r '.name + "/" + .short_name')" "Wraith/Wraith"
expect "version.json" "$(curl -s $B/version.json | jq -r .version)" 0.1.0
if curl -s $B/sw.js | grep -q "wraith-v0.1.0"; then pass "service worker cache name"; else fail "service worker cache name"; fi
expect "icon served" "$(code $B/icon.svg)" 200
js=$(curl -s "$B$(grep -o '/assets/index-[^"]*\.js' <<<"$html" | head -1)")
if grep -q 'Wraith' <<<"$js"; then pass "bundle names Wraith"; else fail "bundle names Wraith"; fi
if grep -qi 'priceghost' <<<"$js"; then fail "bundle still says PriceGhost"; else pass "bundle has no PriceGhost"; fi
if grep -q 'github.com/cozmocode474/wraith' <<<"$js"; then pass "settings links to cozmocode474/wraith"; else fail "settings link"; fi
if docker logs wraith-backend 2>&1 | grep -q 'Wraith API server running'; then pass "backend start line"; else fail "backend start line"; fi
expect "database named wraith" "$(sql 'select 1')" 1

echo "== Accounts"
admin=$(json -X POST $A/auth/register -d '{"email":"admin@test.dev","password":"password123"}' | jq -r .token)
if [ -n "$admin" ] && [ "$admin" != null ]; then pass "first registration"; else fail "first registration"; fi
expect "first user is admin" "$(sql "select is_admin from users where email='admin@test.dev'")" t

t0=$SECONDS
r=$(seq 1 200 | xargs -P 50 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST $A/auth/register -H 'content-type: application/json' -d '{"email":"u{}@test.dev","password":"password123"}' | codes)
echo "      200 parallel registrations in $((SECONDS-t0))s: $r"
expect "200 parallel registrations" "$r" "200x201 "

r=$(seq 1 20 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST $A/auth/register -H 'content-type: application/json' -d '{"email":"race@test.dev","password":"password123"}' | codes)
echo "      20 racing registrations of one email: $r"
expect "same email stored once" "$(sql "select count(*) from users where email='race@test.dev'")" 1
expect "racing registrations: one 201, the rest 409" "$r" "1x201 19x409 "

t0=$SECONDS
r=$(seq 1 400 | xargs -P 50 -I{} sh -c 'n=$(( ({} % 200) + 1 )); curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost/api/auth/login -H "content-type: application/json" -d "{\"email\":\"u$n@test.dev\",\"password\":\"password123\"}"' | codes)
echo "      400 parallel logins in $((SECONDS-t0))s: $r"
expect "400 parallel logins" "$r" "400x200 "
expect "wrong password refused" "$(code -X POST $A/auth/login -H 'content-type: application/json' -d '{"email":"u1@test.dev","password":"nope12345"}')" 401
expect "no token refused" "$(code $A/products)" 401
expect "forged token refused" "$(code -H 'Authorization: Bearer abc.def.ghi' $A/products)" 401

echo "== Tracking 50 products in parallel"
t0=$SECONDS
seq 1 50 | xargs -P 10 -I{} sh -c 'echo "{} $(.stress/add_product.sh "$0" http://shop/p/{}.html)"' "$admin" > /tmp/adds.txt
echo "      in $((SECONDS-t0))s: $(awk '{print $2}' /tmp/adds.txt | codes)"
expect "50 products added" "$(awk '$2==201' /tmp/adds.txt | wc -l | tr -d ' ')" 50
bad=$(awk '{want=10.99+$1; if (($3+0) - want > 0.001 || want - ($3+0) > 0.001) print $1":"$3}' /tmp/adds.txt | tr '\n' ' ')
if [ -z "$bad" ]; then pass "every tracked price matches its page"; else fail "wrong prices: $bad"; fi
expect "out-of-stock product can be added" "$(.stress/add_product.sh "$admin" http://shop/p/oos.html | cut -d' ' -f1)" 201
r=$(seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST $A/products -H "Authorization: Bearer $admin" -H 'content-type: application/json' -d '{"url":"http://shop/p/1.html","selectedPrice":11.99,"selectedMethod":"json-ld"}' | codes)
echo "      10 racing re-adds of a tracked product: $r"
expect "racing re-adds all refused with 409" "$r" "10x409 "
expect "product rows" "$(sql 'select count(*) from products')" 51

echo "== Reads under load"
t0=$SECONDS
seq 1 1000 | xargs -P 100 -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H "Authorization: Bearer $admin" $A/products > /tmp/reads.txt
r=$(awk '{print $1}' /tmp/reads.txt | codes)
p95=$(awk '{print $2}' /tmp/reads.txt | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.95)]}')
echo "      1000 product lists, 100 at a time, in $((SECONDS-t0))s, p95 ${p95}s: $r"
expect "1000 product lists" "$r" "1000x200 "
id1=$(json -H "Authorization: Bearer $admin" $A/products | jq '.[0].id')
u1=$(json -X POST $A/auth/login -d '{"email":"u1@test.dev","password":"password123"}' | jq -r .token)
expect "another user can't read it" "$(code -H "Authorization: Bearer $u1" $A/products/$id1)" 404
expect "another user can't delete it" "$(code -X DELETE -H "Authorization: Bearer $u1" $A/products/$id1)" 404
expect "another user's list is empty" "$(json -H "Authorization: Bearer $u1" $A/products | jq length)" 0

echo "== Prices drop by 2.00, 50 refreshes in parallel"
.stress/make_shop.sh -200
json -H "Authorization: Bearer $admin" $A/products | jq -r '.[] | select(.url|test("/p/[0-9]+\\.html")) | "\(.id) \(.url)"' > /tmp/ids.txt
t0=$SECONDS
r=$(awk '{print $1}' /tmp/ids.txt | xargs -P 25 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $admin" $A/products/{}/refresh | codes)
echo "      in $((SECONDS-t0))s: $r"
expect "50 refreshes" "$r" "50x200 "
bad=""
while read -r id url; do
  n=$(basename "$url" .html)
  got=$(json -H "Authorization: Bearer $admin" "$A/products/$id" | jq -r .current_price)
  ok=$(awk -v a="$got" -v n="$n" 'BEGIN{d=a-(8.99+n); print (d<0.001 && d>-0.001)}')
  [ "$ok" = 1 ] || bad="$bad $n:$got"
done < /tmp/ids.txt
if [ -z "$bad" ]; then pass "every refresh recorded the new lower price"; else fail "refresh prices:$bad"; fi
expect "price history rows (2 per product, 1 for sold out)" "$(sql 'select count(*) from price_history')" 101

echo "== Restart"
docker restart wraith-backend >/dev/null
for i in $(seq 1 60); do [ "$(code $A/auth/registration-status)" = 200 ] && break; sleep 1; done
expect "token still valid after restart" "$(code -H "Authorization: Bearer $admin" $A/products)" 200
expect "products kept after restart" "$(json -H "Authorization: Bearer $admin" $A/products | jq length)" 51

echo "== Health"
for c in wraith-db wraith-backend wraith-frontend; do
  expect "$c running, no crash restarts" "$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' $c)" "running 0"
done
n=$(docker logs wraith-backend 2>&1 | grep -ciE 'unhandled|uncaught|FATAL|too many clients|timeout exceeded when trying to connect' || true)
expect "backend log free of crashes and pool exhaustion" "$n" 0

if [ $FAIL = 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; docker logs wraith-backend 2>&1 | tail -80; fi
exit $FAIL
