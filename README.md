# Seafile on Kubernetes

Image and example manifests for deploying Seafile on Kubernetes clusters. Based on [Gronis/docker-seafile](https://github.com/Gronis/docker-seafile).

## Features

- Seafile 7.1,
- MySQL / SQLite support,
- Auto upgrade / database init,
- Auto offline garbage collection on startup (CE version doesn't have online GC),
- Fluentbit sidecar aggregating logs from all Seafile components,
- nginx sidecar container static assets cache (optional if your ingress controller can handle prefix rewrite) 

## Usage

There's Kustomize base available in `kubernetes/base` directory.

Rendered manifests along with simple MariaDB example available in `examples` directory.

## Known issues

- Crashes during database migrations (first time init, upgrades) are difficult to recover from.
- Currently config gets generated on first time init and doesn't update from environment variables 
