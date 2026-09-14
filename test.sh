#!/bin/sh
# Compile the key logic together with its test as a tiny command line program and run it.
cd "$(dirname "$0")" && rm -rf /tmp/keylight-test && mkdir -p /tmp/keylight-test \
  && cp camelot.swift /tmp/keylight-test/ && cp camelot_test.swift /tmp/keylight-test/main.swift \
  && xcrun swiftc -swift-version 5 -o /tmp/keylight-test/test /tmp/keylight-test/camelot.swift /tmp/keylight-test/main.swift \
  && /tmp/keylight-test/test
