#!/bin/bash

BUILD_DIR=/tmp/vcap
CACHE_DIR=/tmp/vcap/cache
DEPS_DIR=/tmp/vcap/deps
DEPS_IDX=0

export ROOT=$BUILD_DIR
# VCAP_SERVICES is a file with the dump of VCAP_SERVICES variable in CF
export VCAP_SERVICES=$(cat VCAP_SERVICES)

mkdir -p $BUILD_DIR
mkdir -p $CACHE_DIR
mkdir -p $DEPS_DIR
mkdir -p $ROOT

echo ">>>> STAGING"
(
    set -x
    ./bin/detect $BUILD_DIR                                    && \
    ./bin/supply $BUILD_DIR $CACHE_DIR $DEPS_DIR $DEPS_IDX     && \
    ./bin/finalize $BUILD_DIR $CACHE_DIR $DEPS_DIR $DEPS_IDX   && \
    ./bin/release $BUILD_DIR
)

echo ">>>> RUNNING"

export VCAP_SERVICES=$(cat VCAP_SERVICES)
export SQLPROXY_ROOT="${DEPS_DIR}/${DEPS_IDX}/sql_proxy"
(
    set -euo pipefail
    cd $BUILD_DIR
    export BUILD_DIR
    # export DEBUG=1
    ./.cloud_sql_proxy.sh
)

