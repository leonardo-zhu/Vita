#!/bin/sh
# 把评测用到的真实标签照片从 R4S 的 Vita API 拷到 fixtures/（不进 git：照片里有手和家里的背景）。
# 需要能 ssh 到 istoreos。用法：sh tools/agent-eval/fetch-fixtures.sh
set -eu
cd "$(dirname "$0")"
mkdir -p fixtures
for pair in milk:75fd1abb-d936-40bb-9e52-90f8c37b8c9d coffee:d9fea46e-94b5-44ac-9c94-1c695e226f11 xiaolongbao:47803f31-d358-443e-9805-906680efda59; do
  name=${pair%%:*}; id=${pair#*:}
  ssh -o BatchMode=yes istoreos "docker exec vita-api sh -c 'cat /data/files/label-$id.*'" > "fixtures/$name.jpeg" 2>/dev/null
  echo "fixtures/$name.jpeg $(wc -c < "fixtures/$name.jpeg") bytes"
done
