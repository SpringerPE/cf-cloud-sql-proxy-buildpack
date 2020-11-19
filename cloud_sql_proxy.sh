#!/usr/bin/env bash
[ -z "$DEBUG" ] || set -x
set -euo pipefail

# See bin/finalize to check predefined vars
ROOT="${BUILD_DIR:-/home/vcap}"
export AUTH_ROOT="${ROOT}/auth"
# SQL Proxy path is already defined, otherwise 
# SQLPROXY_ROOT=$(find ${ROOT}/deps -name cloud_sql_proxy -type d -maxdepth 2)
export SQLPROXY_ROOT=${SQLPROXY_ROOT}
export PATH=${PATH}:${SQLPROXY_ROOT}/bin


# Service Broker binding name, define it if you have multiple DBs
export DB_BINDING_NAME="${DB_BINDING_NAME:-}"

# Variables exported, they are automatically filled from the  service broker instances.
export DATABASE_URL="${DATABASE_URL:-}"
export DB_TYPE=""
export DB_USER=""
export DB_HOST=""
export DB_PASS=""
export DB_PORT=""
export DB_NAME=""
export DB_CA_CERT=""
export DB_CLIENT_CERT=""
export DB_CLIENT_KEY=""
export DB_CERT_NAME=""
export DB_TLS=""


###

get_binding_service() {
    local binding_name="${1}"
    jq --arg b "${binding_name}" '.[][] | select(.binding_name == $b)' <<<"${VCAP_SERVICES}"
}


get_db_vcap_service() {
    local binding_name="${1}"

    if [[ -z "${binding_name}" ]] || [[ "${binding_name}" == "null" ]]
    then
        # search for a sql service looking at the label
        jq '[.[][] | select(.credentials.uri) | select(.credentials.uri | split(":")[0] == ("mysql","postgres"))] | first | select (.!=null)' <<<"${VCAP_SERVICES}"
    else
        get_binding_service "${binding_name}"
    fi
}


get_db_vcap_service_type() {
    local db="${1}"
    jq -r '.credentials.uri | split(":")[0]' <<<"${db}"
}


set_env_DB() {
    local db="${1}"
    local uri=""

    DB_TYPE=$(get_db_vcap_service_type "${db}")
    uri="${DB_TYPE}://"
    if ! DB_USER=$(jq -r -e '.credentials.Username' <<<"${db}")
    then
        DB_USER=$(jq -r -e '.credentials.uri | split("://")[1] | split(":")[0]' <<<"${db}") || DB_USER=''
    fi
    uri="${uri}${DB_USER}"
    if ! DB_PASS=$(jq -r -e '.credentials.Password' <<<"${db}")
    then
        DB_PASS=$(jq -r -e '.credentials.uri | split("://")[1] | split(":")[1] | split("@")[0]' <<<"${db}") || DB_PASS=''
    fi
    uri="${uri}:${DB_PASS}"
    if ! DB_HOST=$(jq -r -e '.credentials.host' <<<"${db}")
    then
        DB_HOST=$(jq -r -e '.credentials.uri | split("://")[1] | split(":")[1] | split("@")[1] | split("/")[0]' <<<"${db}") || DB_HOST=''
    fi
    uri="${uri}@${DB_HOST}"
    case "${DB_TYPE}" in
        mysql)
            DB_PORT="3306"
            uri="${uri}:${DB_PORT}"
            DB_TLS="false"
        ;;
        postgres)
            DB_PORT="5432"
            uri="${uri}:${DB_PORT}"
            DB_TLS="disable"
        ;;
    esac
    if ! DB_NAME=$(jq -r -e '.credentials.database_name' <<<"${db}")
    then
        DB_NAME=$(jq -r -e '.credentials.uri | split("://")[1] | split(":")[1] | split("@")[1] | split("/")[1] | split("?")[0]' <<<"${db}") || DB_NAME=''
    fi
    uri="${uri}/${DB_NAME}"
    # TLS
    mkdir -p ${AUTH_ROOT}
    if jq -r -e '.credentials.ClientCert' <<<"${db}" >/dev/null
    then
        jq -r '.credentials.CaCert' <<<"${db}" > "${AUTH_ROOT}/${DB_NAME}-ca.crt"
        jq -r '.credentials.ClientCert' <<<"${db}" > "${AUTH_ROOT}/${DB_NAME}-client.crt"
        jq -r '.credentials.ClientKey' <<<"${db}" > "${AUTH_ROOT}/${DB_NAME}-client.key"
        DB_CA_CERT="${AUTH_ROOT}/${DB_NAME}-ca.crt"
        DB_CLIENT_CERT="${AUTH_ROOT}/${DB_NAME}-client.crt"
        DB_CLIENT_KEY="${AUTH_ROOT}/${DB_NAME}-client.key"
        if instance=$(jq -r -e '.credentials.instance_name' <<<"${db}")
        then
            DB_CERT_NAME="${instance}"
            if project=$(jq -r -e '.credentials.ProjectId' <<<"${db}")
            then
                # Google GCP format
                DB_CERT_NAME="${project}:${instance}"
            fi
            [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="true"
            [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="verify-full"
        else
            DB_CERT_NAME=""
            [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="skip-verify"
            [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="require"
        fi
    fi
    echo "${uri}"
}


# Given a DB from vcap services, defines the proxy files ${DB_NAME}-auth.json and
# ${AUTH_ROOT}/${DB_NAME}.proxy
set_DB_proxy() {
    local db="${1}"

    local proxy
    # If it is a google service, setup proxy by creating 2 files: auth.json and
    # cloudsql proxy configuration on ${DB_NAME}.proxy
    # It will also overwrite the variables to point to localhost
    if jq -r -e '.tags | contains(["gcp"])' <<<"${db}" >/dev/null
    then
        jq -r '.credentials.PrivateKeyData' <<<"${db}" | base64 -d > "${AUTH_ROOT}/${DB_NAME}-auth.json"
        proxy=$(jq -r '.credentials.ProjectId + ":" + .credentials.region + ":" + .credentials.instance_name' <<<"${db}")
        echo "${proxy}=tcp:${DB_PORT}" > "${AUTH_ROOT}/${DB_NAME}.proxy"
        [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="false"
        [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="disable"
        DB_HOST="127.0.0.1"
        echo "${DB_TYPE}://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        return 0
    fi
    return 1
}


# exec process in bg
launch() {
    (
        echo "Launching pid=$$: '$@'"
        {
            exec $@
        } 2>&1
    ) &
    pid=$!
    sleep 15
    if ! ps -p ${pid} >/dev/null 2>&1
    then
        echo
        echo "Error launching '$@'."
        rvalue=1
    else
        echo "Pid=${pid} running"
        rvalue=0
    fi
    return ${rvalue}
}


run_sql_proxies() {
    local instance
    local dbname

    if [[ -d ${AUTH_ROOT} ]]
    then
        for filename in $(find ${AUTH_ROOT} -name '*.proxy')
        do
            dbname=$(basename "${filename}" | sed -n 's/^\(.*\)\.proxy$/\1/p')
            instance=$(head "${filename}")
            echo "Launching local sql proxy for instance ${instance} ..."
            launch cloud_sql_proxy -verbose \
                  -instances="${instance}" \
                  -credential_file="${AUTH_ROOT}/${dbname}-auth.json" \
                  -term_timeout=30s -ip_address_types=PRIVATE,PUBLIC
        done
    fi
}


run() {
    local service="${1}"

    local db
    local connection

    db=$(get_db_vcap_service "${service}")
    if [[ -n "${db}" ]]
    then
        set_env_DB "${db}" >/dev/null
        if connection=$(set_DB_proxy "${db}")
        then
            export DATABASE_URL="${connection}"
            run_sql_proxies
        fi
    fi
}


# Run!
run "${DB_BINDING_NAME}"


