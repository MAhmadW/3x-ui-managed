# Setting up a VLESS connection on the single-port image

This walks through deploying the image in **edge mode**, on a platform that terminates
HTTPS for you, and getting one working VLESS connection on port 443. The root
[README](README.md#platforms-that-work-in-edge-mode) lists examples of such platforms.
For how the image is built and every setting, see [managed/README.md](managed/README.md).

Before you deploy anywhere, read that platform's terms of service and acceptable-use
policy, and follow them.

## How traffic flows

```
client ──TLS, port 443──▶ platform edge ──plain HTTP──▶ Caddy in the container
                                                          ├─ PANEL_PATH/*            ▶ panel
                                                          ├─ VPN_PATH_PREFIX/<port>  ▶ Xray inbound on 127.0.0.1:<port>
                                                          └─ anything else           ▶ subscription server
```

Three consequences shape everything below:

- The platform provides TLS, so the **inbound has security "none"** but the **client must
  use TLS**.
- Only HTTP reaches the container, so the transport must be HTTP-based: **XHTTP**
  (preferred), WebSocket or HTTPUpgrade. Raw TCP and REALITY cannot work on the HTTPS
  domain.
- Caddy picks the destination by URL path, so the **inbound's path decides whether
  traffic reaches Xray at all**.

## 1. Deploy

The names of these steps differ per platform, but the steps are the same:

1. Create a service that builds this repository's `Dockerfile`, and set these variables:

   | Variable | Value |
   |---|---|
   | `PROXY_MODE` | `edge` |
   | `PORT` | `8080` |
   | `PANEL_PATH` | a random path, e.g. `/3f9c…/` |
   | `VPN_PATH_PREFIX` | a *different* random path, e.g. `/a71e…` |
   | `PANEL_USERNAME`, `PANEL_PASSWORD` | your panel login (required) |

2. Attach a persistent volume at `/etc/x-ui`. Without it, every redeploy wipes users and
   inbounds. On a platform with no persistent disk, set `XUI_DB_TYPE=postgres` and
   `XUI_DB_DSN` instead.
3. Give the service a public HTTPS domain that forwards to container port `8080`, the
   same value as `PORT`. If the platform injects its own `PORT`, leave the variable out
   and let the platform route to that port.
4. Deploy.

The panel is then at `https://<domain><PANEL_PATH>`. Every other path, including the
default `/panel/`, returns 404 by design.

## 2. Create the inbound

In the panel, *Inbounds → Add Inbound*:

| Tab | Field | Value |
|---|---|---|
| Basics | Protocol | `vless` |
| Basics | Address | `127.0.0.1` |
| Basics | Port | any free port from `10000` to `10999`, e.g. `10035` |
| Stream | Transmission | `XHTTP` |
| Stream | Host | leave blank |
| Stream | Path | `<VPN_PATH_PREFIX>/<port>`, e.g. `/a71e…/10035` |
| Security | Security | `none` |

Leave every other field at its default.

- **Address** is the address the inbound listens on; the form has no field called
  "Listen IP". Left blank it listens on all addresses, which also works, but `127.0.0.1`
  keeps the inbound reachable only through Caddy.
- **Host** restricts which HTTP `Host` header the inbound accepts. Blank accepts any, and
  the client then sends your public domain by itself. A value that does not match what
  the platform forwards makes every request fail, so blank is the safe choice.
- **Path** must contain the inbound's own port. Ports outside 10000–10999 are not routed.

## 3. Add a host so share links are correct

The inbound only knows about `127.0.0.1:<port>` without TLS, so a link generated from it
alone is unusable. Tell the panel the public address on the **Hosts** page (left sidebar),
with *Add Host*:

| Field | Value |
|---|---|
| Inbounds | the inbound from step 2 |
| Address | your public domain, as a bare hostname: no `https://`, no path |
| Port | `443` |
| Security | `tls` |
| SNI | tick "Use address as SNI", or enter the same bare hostname |
| Host header | leave blank |

The address and SNI are hostnames, not URLs. The panel accepts `https://<domain>` in the
SNI field without complaint, and the resulting link cannot connect.

Older guides call this "External Proxy" inside the inbound form. That section was
removed; Hosts replaces it.

## 4. Connect

Copy the inbound's share link or QR code into the client (v2rayN, v2rayNG and similar).
The imported profile should show:

- address = your public domain, port **443**
- transmission **XHTTP**, path = `<VPN_PATH_PREFIX>/<port>`
- security **TLS**, SNI = your public domain, with no `https://` in front
- Host empty or your public domain, never `127.0.0.1`

## Problems you are likely to hit

These are the ones we ran into, in the order we hit them.

### `/panel/` returns 404

The panel is only served at `PANEL_PATH`, which is random on purpose. Read the value from
the platform's variables.

### Client refuses to start: "vless without TLS or other encryption is prohibited"

Recent Xray cores will not send plain VLESS to a public address, and the client profile
has security "none". The inbound should be "none"; the client should not. Add the host
from step 3 and re-import the link so the client uses TLS on 443.

### Raw TCP inbound, or the client pointing at the inbound's port

A profile like `domain:48603` with raw TCP cannot work. The platform's HTTPS domain only
accepts port 443, and raw VLESS has no URL path for Caddy to route on. Use XHTTP on a port
in 10000–10999 and connect to 443.

### Client starts, logs "accepted", but nothing loads (delay `-1`)

The client log is misleading here: "accepted" only means the local SOCKS port took the
request. Check the platform's HTTP request log for the status of the client's requests.

- **No requests from the client at all**: the connection fails before it reaches the
  service, so the SNI or Host in the profile is wrong. The two we hit were a scheme in
  the SNI (`https://<domain>`) and `127.0.0.1` entered as Host. Fix the SNI on the Hosts
  page, clear Host there and in the inbound's Stream tab, then re-import the link.
- **404 on paths starting with `PANEL_PATH`**: the inbound's path uses the panel path
  instead of `VPN_PATH_PREFIX`, so requests are going to the panel. Fix the path, then
  re-import the link.
- **404 on other paths**: the path does not match `<VPN_PATH_PREFIX>/<port>`, or the port
  is outside 10000–10999, so the request fell through to the subscription server.
- **502**: routing is correct but nothing listens on that port. The inbound is disabled,
  on a different port than the one in its path, or not listening on `127.0.0.1`.

From the client side this looks like the ISP blocking the connection. It is a path
mismatch.

### After any change to the inbound

Re-copy the share link. The client keeps the old path, port and security until you do.

### REALITY

Not possible on the HTTPS domain, because the platform terminates TLS before Xray sees
the connection. Where a platform also offers a raw TCP proxy, REALITY would need that,
usually on a port other than 443. Sharing 443 needs a host where the container owns the
port (`PROXY_MODE=direct`) plus a server-name splitter that this image does not include.

## What the platform can see

TLS ends at the platform's edge, and the inbound adds no encryption of its own. Between
the edge and the container the platform is therefore able to read the VLESS header: the
client's ID and the destination of each connection. Content that is itself encrypted,
such as an HTTPS page, stays encrypted to its destination. This describes what is
technically visible, not what any platform inspects or logs.
