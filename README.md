# cf-cloud-sql-proxy-buildpack

Having mysql or postgres instances deployed by Google Service Broker, this buildpack allows
the app to connect to the DB without TLS certificates. It defines env vars which 
can be used by the app to connect via the cloud sql proxy.

The Cloud SQL Proxy provides secure access to your instances without the need
for Authorized networks or for configuring SSL. More info: https://cloud.google.com/sql/docs/mysql/sql-proxy
and https://github.com/GoogleCloudPlatform/cloudsql-proxy

This buildpack is focused on CloudSQL offered by Google Service Broker.

# TLS with GCP Service Broker and Cloud SQL Proxy

Some applications/framework have issues dealing with TLS certificates or connection strings
with embedded certificates, the way to overcome to this situation
was using a Cloud SQL Proxy: https://github.com/GoogleCloudPlatform/cloudsql-proxy

When the builpack detects a GCP Service broker, it automatically runs the cloud-sql proxy
and change connection settings to point to localhost. The SQL proxy connects
to the DB server using the TLS settings and `PrivateData` auth.

## Using it

First of all, this buildpack has no requirements at all. The way it works is being an
intermediate builpack setting up the cloud-sql proxy and redefining the environment
variables for the app.

To use this buildpack, specify the URI of this repository when push to Cloud Foundry
by adding it to the list of buildpacks of your app, **not being the last one** which
is the one in charge of run your app.


```manifest.yml
---
applications:
- name: grafana
  memory: 512M
  instances: 1
  stack: cflinuxfs3
  random-route: true
  buildpacks:
  - https://github.com/SpringerPE/cf-cloud-sql-proxy-buildpack.git
  - https://github.com/SpringerPE/cf-grafana-buildpack.git
  env:
    ADMIN_USER: admin
    ADMIN_PASS: admin
    SECRET_KEY: yUeEBtX7eTmh2ixzz0oHsNyyxYmebSat
```

and deploy the application again


### Configuration and environment variables

In case you have multiple services bound to the app, you can define a specific
binding by defining `DB_BINDING_NAME` env var in the manifest.


The buildpack also redefines `DATABASE_URL` to point to localhost, so the app
can use the variable direclty as connection string. The rest of variables are:

```
# Variables exported, they are automatically filled from the  service broker instances
# These are their default values.
DB_TYPE=""
DB_USER=""
DB_HOST=""
DB_PASS=""
DB_PORT=""
DB_NAME=""
DB_CA_CERT=""
DB_CLIENT_CERT=""
DB_CLIENT_KEY=""
DB_CERT_NAME=""
DB_TLS=""
```

### Service brokers

As said, you can use a service broker instance which exposes a SQL connection string
in `.credentials.uri`, the DB connection string has to be properly formed and only
using `mysql` or `postgres`.

If you do not have a service broker implementation, you can still use it via user provided
services:

```
$ cf create-user-provided-service mysql-db -p '{"uri":"mysql://root:secret@dbserver.example.com:3306/mydatabase"}'
# bind a service instance to the application
$ cf bind-service <app name> <service name>
# restart the application so the new service is detected
$ cf restart
```

# Development

Implemented using bash scripts to make it easy to understand and change.

https://docs.cloudfoundry.org/buildpacks/understand-buildpacks.html

The builpack uses the `deps` and `cache` folders according the implementation purposes,
so, the first time the buildpack is used it will download all resources, next times 
it will use the cached resources.


# Author

(c) Jose Riguera Lopez  <jose.riguera@springernature.com>
Springernature Engineering Enablement

MIT License
