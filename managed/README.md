# The single-port image

One image, one exposed port. [Caddy](https://caddyserver.com) runs in front of the panel
and routes each request by its path:

| Request path | Goes to |
|---|---|
| `PANEL_PATH*` (default `/panel/`) | the 3x-ui panel on `127.0.0.1:2053` |
| `VPN_PATH_PREFIX/<port>[/...]` (default `/vpn/<port>`) | the Xray inbound on `127.0.0.1:<port>`, ports 10000–10999 |
| anything else | the subscription server on `127.0.0.1:2096` |

The container needs no host networking and no `NET_ADMIN`. Fail2ban is off by default
because it cannot apply bans without `NET_ADMIN`.

For a step-by-step deployment with a working VLESS connection, see
[SETUP.md](../SETUP.md). This page is the reference for the image itself.

## Modes

| `PROXY_MODE` | TLS is terminated by | Container listens on | Needs |
|---|---|---|---|
| `edge` (default) | the platform's HTTPS edge | plain HTTP on `$PORT` (default 8080) | nothing |
| `direct` | Caddy, with an automatic certificate | 443 | `DOMAIN`, and 443 reachable from the internet |

Edge mode is the one in real use, and the one [SETUP.md](../SETUP.md) describes. The
root [README](../README.md#platforms-that-work-in-edge-mode) lists examples of platforms
it fits. Direct mode is for a host that passes port 443 to the container untouched, such
as a VM running Docker; the README has
[examples of those](../README.md#platforms-that-work-in-direct-mode) too. It has only
been tested locally with `DOMAIN=localhost`, which gives a locally-signed certificate; it
has not been run against a public domain yet.

## Run it locally

```bash
cp .env.managed.example .env.managed
```

```bash
docker compose -f docker-compose.managed.yml up -d --build
```

Before the second command, edit `.env.managed`: fill in `PANEL_USERNAME` and
`PANEL_PASSWORD`, and change `PANEL_PATH` and `VPN_PATH_PREFIX`. With the example paths
the panel is at `http://localhost:8080/change-me-panel/`.

The compose file publishes `8080:8080`, so leave `PORT` unset there. For direct mode, set
`PROXY_MODE=direct` and `DOMAIN`, and swap the published port to `443:443` as the comment
in the compose file shows.

`PANEL_USERNAME` and `PANEL_PASSWORD` are required. The container stops at start if
either is missing, so the login never has to be dug out of the log.

## Run it on a platform

Point the platform at the repository's `Dockerfile`. It builds this image by default;
`docker build --target upstream .` gives the stock 3x-ui image instead.

- Set the variables from [.env.managed.example](../.env.managed.example).
- Route the platform's public HTTPS port to the container's `$PORT`. Most platforms
  inject `PORT` themselves; otherwise it is 8080.
- Keep `/etc/x-ui` on a persistent volume, or set `XUI_DB_TYPE=postgres` and
  `XUI_DB_DSN`. Without either, every deploy starts from an empty disk and wipes the
  inbounds, clients, hosts and panel settings. That includes a deploy triggered by a push
  to the repository.

The Dockerfile declares no `VOLUME`, because some platforms reject images that do. Mount
the volume at deploy time.

## Settings

| Variable | Default | Notes |
|---|---|---|
| `PROXY_MODE` | `edge` | `edge` or `direct` |
| `PORT` | `8080` | edge mode listen port |
| `DOMAIN` | — | required in direct mode |
| `PANEL_PATH` | `/panel/` | letters, digits, `_` and `-`; applied to the panel on every start |
| `VPN_PATH_PREFIX` | `/vpn` | same character rules; must not be inside `PANEL_PATH`, or contain it |
| `PANEL_USERNAME`, `PANEL_PASSWORD` | — | required; the panel login, applied on every start |
| `TRUSTED_PROXIES` | `private_ranges` | edge mode: which upstream addresses may supply the client IP |

All upstream `XUI_*` variables still work.

`PANEL_PATH`, the login and the panel's listen address (`127.0.0.1`) are written to the
panel from the environment on every start, so changing them in the panel UI does not stick. The
panel does not strip a proxy prefix, which is why its base path has to equal the public
sub-path.

A setting the entrypoint rejects stops the container at start with a line beginning
`[managed] ERROR:` in the log.

## Adding a VLESS inbound

In the panel, *Inbounds → Add Inbound*:

1. *Basics* tab: protocol `vless`, Address `127.0.0.1` (this is the listen address), port
   between `10000` and `10999`, e.g. `10001`.
2. *Stream* tab: Transmission `XHTTP` (preferred; Xray marks WebSocket as deprecated),
   `WebSocket` or `HTTPUpgrade`, with the path `VPN_PATH_PREFIX/<port>`, e.g.
   `/vpn/10001`. Leave Host blank.
3. *Security* tab: `none`. TLS is added in front, by the platform or by Caddy.
4. On the *Hosts* page (sidebar), add a host for this inbound: address = your public
   hostname, port `443`, security `tls`, SNI = the hostname. Both are bare hostnames, with
   no `https://`. This makes the generated links and QR codes point at `hostname:443`
   with TLS.

The path must start with `VPN_PATH_PREFIX`, not `PANEL_PATH`. Requests under the panel
path go to the panel and return 404.

Client settings, if entered by hand: address = public hostname, port 443, TLS on,
SNI and Host = public hostname, same transmission and path.

Not supported behind this proxy: REALITY, raw TCP / XTLS-Vision, gRPC, and UDP-based
transports. On platforms that buffer request bodies, use XHTTP in `packet-up` mode or
WebSocket.

## Subscriptions

In *Panel Settings → Subscription*, set *Reverse Proxy URI* to
`https://<public hostname>/<subscription path>/`, so subscription links use the public
address. The subscription paths themselves need no routing setup: every path that is not
the panel or a VLESS route already goes to the subscription server.

## Files

| File | Purpose |
|---|---|
| `entrypoint.sh` | validates the settings, applies them to the panel, then runs Caddy and the stock 3x-ui entrypoint together; the container exits if either stops |
| `routes.caddy` | the path routing shared by both modes |
| `Caddyfile.edge` | plain HTTP listener on `$PORT`, trusting the platform's forwarded client IP |
| `Caddyfile.direct` | HTTPS listener for `$DOMAIN` with an automatic certificate |
