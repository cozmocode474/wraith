#!/usr/bin/env bash
# make_shop.sh <cents offset>: writes 50 product pages priced 10.99+i (+offset cents) and one out of stock.
set -eu
off=${1:-0}
mkdir -p .stress/shop/p
for i in $(seq 1 50); do
  price=$(awk -v i="$i" -v o="$off" 'BEGIN{printf "%.2f", 10.99 + i + o/100}')
  printf '%s\n' \
    '<!doctype html><html><head><title>Test Widget '"$i"'</title>' \
    '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"Test Widget '"$i"'","image":"http://shop/img.png","offers":{"@type":"Offer","price":"'"$price"'","priceCurrency":"USD","availability":"https://schema.org/InStock"}}</script>' \
    '</head><body><h1>Test Widget '"$i"'</h1><span class="price">$'"$price"'</span></body></html>' \
    > ".stress/shop/p/$i.html"
done
printf '%s\n' \
  '<!doctype html><html><head><title>Sold Out Widget</title>' \
  '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"Sold Out Widget","offers":{"@type":"Offer","price":"5.00","priceCurrency":"USD","availability":"https://schema.org/OutOfStock"}}</script>' \
  '</head><body><h1>Sold Out Widget</h1></body></html>' \
  > .stress/shop/p/oos.html
