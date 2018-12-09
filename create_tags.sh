#!/bin/bash
rm tags/*
for TAG in $(grep -hm1 '^tags:' _posts/* | cut -d' ' -f2- | sed 's/\ /\n/g' | sort -u)
do
echo "---
layout: tag
tag: $TAG
---" > "tags/${TAG}.html"
done
