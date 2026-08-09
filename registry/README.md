# brain-registry

A minimal HTTP registry for `brainwrt-ct` bundle tarballs: push from a
build machine (token-authenticated), pull from anywhere reachable on the
network (no auth). Single static Go binary, filesystem storage, no
database, no third-party dependencies.

## API

- `PUT /bundles/{name}/{version}` — body is the bundle tar. Requires
  `Authorization: Bearer <PUSH_TOKEN>`. `{version}` may not literally be
  `"latest"` (that string is reserved for GET-time resolution).
- `GET /bundles/{name}/{version}` — returns the tar. `{version}` may be
  `latest` to fetch the most recently pushed version for that name.
- `GET /api/bundles` — no auth. JSON listing of every registered bundle:
  `{"<name>": {"versions": [...], "latest": "..."}}`, versions sorted
  alphabetically. Returns `{}` if nothing has been pushed yet.
- `GET /` — no auth. A self-contained HTML page (embedded in the binary)
  that fetches `/api/bundles` and renders it as a table, with each version
  linking to its `GET /bundles/{name}/{version}` download.

`{name}`/`{version}` must match `^[A-Za-z0-9._-]+$` and may not be `.` or
`..`.

## Configuration (environment variables)

| Variable | Default | Notes |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | |
| `DATA_DIR` | `./data` | created on startup if missing |
| `PUSH_TOKEN` | *(none)* | **required** — the process refuses to start if unset |

## Build

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o brain-registryd .
```

(swap `GOARCH` for the deploy target's architecture, e.g. `arm64`)

## Run

```sh
PUSH_TOKEN=<token> DATA_DIR=/var/lib/brain-registry ./brain-registryd
```

See `deploy/brain-registry.service` for a systemd unit example. TLS
termination and any remote-access story (e.g. Tailscale) are out of scope
for this server — it speaks plain HTTP only; put a proxy or tailnet in
front of it if needed.

## Smoke test

```sh
curl -X PUT --data-binary @bundle.tar -H "Authorization: Bearer $TOKEN" \
  http://<host>:8080/bundles/webcam/20260720_120000_abcd1234
curl http://<host>:8080/bundles/webcam/latest -o bundle.tar
```
