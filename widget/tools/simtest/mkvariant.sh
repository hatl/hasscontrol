#!/usr/bin/env bash
# usage: mkvariant.sh <src-widget-dir> <dst-dir> key=value [key=value ...]
# Copies the widget sources and overrides property defaults in resources/properties.xml.
set -eu
SRC="$1"; DST="$2"; shift 2
rm -rf "$DST"; mkdir -p "$DST"
cp -r "$SRC"/. "$DST"/
rm -rf "$DST/bin" "$DST/sdk" "$DST/export"
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  python3 - "$DST/resources/properties.xml" "$k" "$v" <<'PY'
import re,sys
p,k,v=sys.argv[1:4]
s=open(p).read()
pat=re.compile(r'(<property id="%s" type="[a-z]+">)([^<]*)(</property>)' % re.escape(k))
if not pat.search(s): sys.exit("property %s not found" % k)
s=pat.sub(lambda m: m.group(1)+v+m.group(3), s, count=1)
open(p,'w').write(s)
PY
done
grep -o '<property id="[a-zA-Z_]*" type="[a-z]*">[^<]*' "$DST/resources/properties.xml" | sed 's/<property id="//; s/" type="[a-z]*">/ = /'
