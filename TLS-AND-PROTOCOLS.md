# TLS termination, VLESS, REALITY, and why protocol choice matters

Background notes for the single-port 3x-ui deployment. This explains what "edge mode" and
"direct mode" mean, what TLS termination is, how VLESS and REALITY work, how they compare
with other VPN protocols, and why this family of protocols tends to hold up on networks
that filter by traffic type, with Pakistan as the example.

> **Before publishing anything from this:** the section on Pakistan summarises public
> reporting as I recall it, not anything measured in this project. Check current sources
> for dates and specifics, and check the current legal position on VPN use and
> registration. Nothing here is legal advice.

## 1. The layers involved

A proxied connection is several connections stacked inside each other. Keeping them apart
makes everything else easier to follow.

| Layer | What it is | Runs between |
|---|---|---|
| TCP | The basic reliable byte stream | Your device and the first server that answers |
| TLS | Encryption plus proof of the server's identity | Your device and whoever holds the certificate |
| HTTP transport (XHTTP, WebSocket) | A way to carry a stream inside ordinary web requests | Your client and Xray |
| VLESS | The tunnel protocol: "I am this user, connect me to that destination" | Your client and Xray |
| Your real traffic | For example an HTTPS visit to a website, with its own TLS | Your browser and that website |

Each layer can end at a different place. "Where does the buck stop" has a different
answer per layer.

## 2. What TLS termination means

TLS termination is the point where the encrypted connection from the client is decrypted.
Three things happen there, and they always happen together:

1. **Authentication.** The terminator presents a certificate and proves it holds the
   matching private key. The client is verifying *that* party, not anything behind it.
2. **Decryption.** The TLS layer is removed. Everything past this point is in whatever
   form it had inside the TLS.
3. **Interpretation.** Having decrypted the traffic, the terminator can read and act on
   it: route by hostname and path, apply timeouts, buffer, log.

So the terminator is where the *encryption* buck stops, and where the client's *TCP
connection* stops too, because the terminator opens a new, separate connection onward.
It is not where the data stops. The data carries on to the container and then out to the
internet.

## 3. Edge mode and direct mode

### Edge mode: the platform terminates TLS

```
client ══ TLS ══▶ platform edge ── plain HTTP ──▶ Caddy ──▶ Xray ──▶ internet
                  (holds the cert,
                   decrypts here)
```

- The platform (Railway, Cloud Run, Render and similar) owns the certificate for the
  public domain and answers the TLS handshake.
- It forwards plain HTTP requests to the container on one port.
- Inside the container, Caddy routes by URL path: one path to the panel, another to Xray.
- This is the default mode and the one proven in practice.

### Direct mode: the container terminates TLS

```
client ══════════ TLS ══════════▶ Caddy ──▶ Xray ──▶ internet
          (platform forwards        (holds the cert,
           bytes it cannot read)     decrypts here)
```

- The platform passes raw TCP on port 443 to the container without touching it.
- Caddy obtains its own certificate for your domain and answers the handshake.
- Needs a platform that offers raw TCP on 443 (a VM, ECS behind a network load balancer,
  Fly.io) and a domain you control.

### Side by side

| | Edge mode | Direct mode |
|---|---|---|
| Who holds the certificate and private key | The platform | Caddy, inside your container |
| Who the client actually authenticates | The platform | Your container |
| What arrives at the container | Plain HTTP requests | Encrypted TCP on 443 |
| What the platform can read in transit | The HTTP requests, including the VLESS header | Only that a TLS connection to your domain exists, plus sizes and timing |
| What the platform must provide | An HTTPS domain | Raw TCP passthrough on 443 |
| Certificate work for you | None | Automatic via Caddy, but you need a domain |
| Usable transports | HTTP-based only | HTTP-based here; raw ones possible with more work |

### Where each layer ends, per mode

| Layer | Edge mode ends at | Direct mode ends at |
|---|---|---|
| Client's TCP connection | Platform edge | Caddy |
| TLS session | Platform edge | Caddy |
| VLESS tunnel | Xray | Xray |
| Your website's own TLS | The website | The website |

The privacy consequence follows directly. In edge mode there is a stretch, between the
platform's edge and Xray, where the tunnel travels without TLS. In this setup VLESS adds
no encryption of its own, so on that stretch the platform is able to read the VLESS
header: the client's ID and the destination of each connection. It cannot read content
that is itself encrypted, such as HTTPS pages, only where that traffic is going. In
either mode the host can also see the container's outbound connections.

This is a statement about what is technically visible, not about what any platform
actually inspects or logs.

## 4. The traditional VPN protocols

These were designed for security and speed on networks that are not trying to stop them.
None of them attempts to hide what it is.

### OpenVPN

- **How it works.** A control channel runs a TLS handshake to authenticate both sides and
  agree keys; a separate data channel then carries encrypted IP packets. It runs over UDP
  (default port 1194) or TCP.
- **Why it is easy to spot.** OpenVPN wraps its TLS inside its own packet framing. Every
  packet starts with an opcode, and the first packet of a session is a "hard reset" with a
  fixed value in a fixed position. A filter needs to look at one packet. Moving it to TCP
  port 443 does not help, because the bytes still are not a normal TLS handshake.

### WireGuard

- **How it works.** A fixed, modern design: a Noise-protocol handshake using Curve25519,
  then ChaCha20-Poly1305 for data, all over UDP. About 4,000 lines of code, in the Linux
  kernel, and very fast.
- **Why it is easy to spot.** The simplicity is the giveaway. The handshake initiation
  message is always the same length (148 bytes) and begins with a fixed type field; the
  response is always 92 bytes. The designers state plainly that hiding is not a goal.
- **Second weakness.** It is UDP only. Networks that throttle or drop unknown UDP break it
  without identifying it at all.

### IPsec / IKEv2 and the older ones

- **IKEv2/IPsec** negotiates on UDP ports 500 and 4500 and carries data in a dedicated IP
  protocol (ESP). Fixed ports and formats; blocking it is a firewall rule.
- **L2TP and PPTP** are older still, with fixed ports and, in PPTP's case, broken
  cryptography.

**The common thread:** each has a recognisable first packet. Deep packet inspection (DPI)
equipment ships with signatures for all of them, so one policy switch blocks them for a
whole country regardless of which server they connect to.

## 5. The circumvention family

These come mostly from the Chinese-speaking developer community, built in direct response
to national-scale filtering. Their history is a sequence of moves and counter-moves, and
each protocol makes more sense as an answer to the weakness of the one before.

### Shadowsocks (2012): look like nothing

- **Idea.** Encrypt everything, from the first byte, with a key both sides already share.
  There is no handshake and no readable header. On the wire it is a stream of
  random-looking bytes.
- **What went wrong.** "Looks like nothing" turned out to be a signature. Almost all real
  traffic has recognisable structure in its first packet (a TLS hello, an HTTP verb).
  Published research on China's firewall describes it flagging connections whose first
  packet is *entirely* high-entropy and matches no known protocol. Earlier versions were
  also vulnerable to **active probing**: the censor replays or alters captured packets and
  watches how the server reacts.

### VMess (V2Ray, ~2016): a richer protocol

- **Idea.** A full proxy protocol with its own encryption, users identified by UUID, and
  authentication tied to the current time so that captured packets cannot be replayed
  later. It can be carried over different transports (TCP, WebSocket, HTTP/2).
- **Trade-off.** More features, more overhead, clock synchronisation required, and still
  doing its own encryption even when wrapped in TLS.

### Trojan (2019): stop inventing, use real TLS

- **Idea.** The reverse of Shadowsocks. Rather than looking like nothing, look exactly
  like the most common thing on the internet: an HTTPS web server.
- **How it works.** The server is a genuine TLS server with a genuine certificate for a
  real domain. After the TLS handshake, the client's first bytes are a hash of a password
  followed by the destination. If the hash is right, the server proxies. If it is anything
  else, such as a browser or a censor's probe, the connection is handed to a real web
  server sitting behind it.
- **Why it matters.** A prober sees a working website. The proxy adds no encryption of
  its own, because TLS already provides it.

### VLESS (2020): the same idea, minimal

VLESS, from the Xray project (a fork of V2Ray), applies Trojan's philosophy inside the
V2Ray ecosystem.

**The request header** is close to the minimum possible:

| Field | Size | Purpose |
|---|---|---|
| Version | 1 byte | Currently 0 |
| User ID | 16 bytes | The client's UUID |
| Add-ons | variable | Optional settings, such as the flow-control mode |
| Command | 1 byte | TCP, UDP, or multiplexed |
| Port | 2 bytes | Destination port |
| Address type + address | variable | IPv4, IPv6 or a domain name |

After that header, the connection is a plain two-way byte stream. The server's reply
header is two bytes.

**What it leaves out, on purpose:**

- **No encryption.** The name is literal: it is VMess with less. The tunnel is expected
  to sit inside TLS or REALITY. Recent Xray versions enforce this by refusing to send
  plain VLESS to a public address, which is why the client in this project must use TLS
  even though the server-side inbound says "security: none".
- **No time-based authentication.** The UUID alone identifies the user, so clocks need
  not agree. Replay protection is left to the outer TLS layer.

**What that buys:** very low overhead, and no appearance of its own. An observer sees
only the outer layer.

**Fallbacks.** Like Trojan, a VLESS server on raw TCP can pass anything that is not valid
VLESS to another service, typically a real website.

Newer Xray versions add an optional "VLESS Encryption" setting that encrypts the VLESS
stream itself. It was not used or tested in this project; it would close the visibility
gap described for edge mode in section 3.

### The transports: how the stream is carried

VLESS needs something to carry its byte stream. This choice decides where it can run.

| Transport | How it carries the stream | Behind an HTTPS edge |
|---|---|---|
| Raw TCP + TLS or REALITY | Directly inside the encrypted connection | No |
| WebSocket | One HTTPS request upgraded to a two-way socket | Yes, but deprecated by Xray |
| HTTPUpgrade | Like WebSocket without the WebSocket framing | Yes |
| gRPC | HTTP/2 streams | Only if the edge passes HTTP/2 end to end |
| XHTTP | Ordinary HTTP requests and responses | Yes; the recommended choice |

**XHTTP in more detail.** It exists because some proxies and content-delivery networks
handle WebSocket poorly or mark it as unusual. XHTTP splits the stream into plain HTTP:

- **Download** is one long-running `GET` whose response body streams data to the client.
- **Upload** is either one streaming `POST`, or, in "packet-up" mode, a series of small
  `POST` requests each carrying a sequence number so the server can reassemble them.

That is exactly what appeared in this project's request log: repeated
`GET <path>/<session-id>` and `POST <path>/<session-id>/<number>`. Packet-up works even
through edges that buffer request bodies, at some cost in efficiency. Requests also carry
random padding so their sizes are less regular.

### Two refinements worth knowing

**Browser fingerprints (uTLS).** A TLS client reveals what software it is by the exact
contents and ordering of its opening message. A proxy client written in Go has a
different fingerprint from Chrome. Xray uses a library that reproduces a real browser's
opening message byte for byte, so the handshake is not an outlier.

**TLS inside TLS, and Vision.** When you browse an HTTPS site through a TLS tunnel, there
is an inner TLS handshake inside the outer encrypted stream. Its content is hidden, but
its *shape* is not: the sizes and timing of the first few records are characteristic.
Research has shown this can be detected statistically. Xray's "Vision" flow control
responds in two ways: it pads the early inner-handshake records to disguise their sizes,
and once the inner connection is carrying already-encrypted data it stops encrypting a
second time and passes those records through as they are. The second part also saves
CPU. Vision needs raw TCP, so it is not available in edge mode.

## 6. REALITY

REALITY (2023) replaces TLS as the outer layer. It is the most involved piece here, so
this section goes step by step.

### The problems it solves

Running Trojan or VLESS over ordinary TLS has costs:

1. **You need a domain and a certificate.** Registration leaves a paper trail, the
   certificate appears in public transparency logs, and the domain can be blocked by name.
2. **Your domain has no reputation.** A newly registered name receiving heavy traffic
   from one country is itself a signal.
3. **Your "real website" fallback is a prop.** It is usually an empty or template page,
   which a careful prober can tell from a genuine site.

REALITY removes all three by not having an identity of its own. It borrows one.

### The setup

- **Server:** generates a long-term key pair (X25519) and chooses a **target**: a real,
  popular, unrelated website that supports TLS 1.3. The server also defines one or more
  **short IDs**, which work like per-client labels.
- **Client:** is given the server's IP address, the server's *public* key, a short ID,
  and the target's hostname to present as the server name.

### A connection from a legitimate client

1. **The opening message.** The client sends a TLS 1.3 `ClientHello` that mimics a real
   browser's and names the target site. As in any TLS 1.3 handshake, it includes a fresh
   one-time public key.
2. **The hidden proof.** The client combines its one-time private key with the server's
   long-term public key to compute a shared secret. Using a key derived from that secret,
   it encrypts a small message (version, timestamp, short ID) and places the result in the
   `ClientHello`'s **session ID** field. In real TLS 1.3 that field holds 32 arbitrary
   bytes, so random-looking content there is normal.
3. **Recognition.** The server combines its long-term private key with the client's
   one-time public key and arrives at the same shared secret. It tries to decrypt the
   session ID. If that succeeds and the timestamp and short ID are acceptable, this is a
   real client.
4. **The server answers as itself.** It completes the TLS 1.3 handshake using a temporary
   certificate it creates on the spot, marked with a signature derived from the shared
   secret.
5. **The client checks the server.** The client does not validate this certificate
   against public authorities. It checks the secret-derived signature. Only the holder of
   the server's private key could have produced it, so this proves the client reached the
   real server and not an impostor in the middle.
6. **Tunnel.** VLESS now runs inside this encrypted connection.

An observer cannot see the temporary certificate, because TLS 1.3 encrypts everything
after the first reply. What is visible is a normal-looking handshake naming a well-known
site.

### A connection from anyone else

If the session ID does not decrypt, as with a browser, a scanner or a censor's probe, the
server does nothing clever. It opens a connection to the real target site and relays
bytes in both directions, unmodified. The visitor completes a genuine handshake with the
genuine site, receives its genuine certificate, and can browse its genuine pages.

So the server is not imitating the target. For everyone without the key, it *is* the
target, by relay.

### What this achieves

- **No domain, no certificate, nothing to register.**
- **Probing reveals a real, major website,** with valid certificate and real content.
- **Blocking by server name means blocking that major website.**
- **Captured traffic cannot be replayed,** because of the timestamp and one-time keys,
  and past sessions stay secret even if the server's key later leaks.
- **Interception is detected.** If something in the path substitutes the real target's
  certificate, the client notices the missing signature and does not send tunnel traffic.

### Limits

- **The address does not match the name.** The server's IP belongs to a hosting provider,
  not to the target site's network. A censor that checks whether a server name is being
  served from a plausible address can flag the mismatch. Choosing a target hosted near
  your server reduces this.
- **Traffic patterns remain.** Volume, timing and the TLS-inside-TLS shape are still
  observable. REALITY is normally paired with Vision for that reason.
- **It needs raw TCP.** REALITY depends on the server reading the client's original
  opening message byte for byte. Behind a platform edge, that message has already been
  consumed by the platform and the container receives only decrypted HTTP. This is why
  REALITY cannot run in edge mode, and needs a VM or a platform with TCP passthrough.

## 7. Newer protocols and where things are heading

### QUIC-based: Hysteria2 and TUIC

QUIC is the encrypted, UDP-based transport underneath HTTP/3. Two protocols build on it:

- **Hysteria2** presents as an HTTP/3 web server and authenticates clients through what
  looks like an ordinary HTTP/3 request; anyone else gets a normal web response. Its
  distinctive feature is a congestion controller that sends at a rate you configure and
  does not back off on packet loss. On lossy or deliberately throttled links this can be
  far faster than TCP, at the cost of being a poor neighbour on shared networks.
- **TUIC** also uses QUIC, focusing on fast connection setup and carrying UDP traffic
  (games, calls) natively and efficiently.

Both depend on UDP reaching the server, and on the network treating QUIC normally. Where
UDP is throttled, or QUIC is blocked to push users back to inspectable TCP, they fail.

### Modified WireGuard: AmneziaWG

Keeps WireGuard's cryptography but adds junk packets and changes the fixed header values
and message sizes, so the standard WireGuard signature no longer matches. A pragmatic
patch for signature-based blocking, without a deeper disguise.

### Others in the same space

- **NaiveProxy** uses the actual Chrome network stack for its connections, so its
  fingerprint is Chrome's by construction, not by imitation.
- **ShadowTLS** performs a real handshake with a third-party site and then switches to
  carrying proxy data, an idea related to REALITY's.
- **MASQUE** is the standards-body version of proxying over HTTP/3, used by some
  commercial privacy relays. It is designed for privacy, not for hiding.

### Encrypted Client Hello (ECH)

A TLS extension, now being deployed, that encrypts the server name in the opening
message. Today that name is the one piece of a TLS connection a filter can always read.
If ECH becomes widespread, blocking by server name stops working for ordinary websites
too, which changes the picture for everyone, not only for proxies.

### The pattern

| Generation | Strategy | Defeated by |
|---|---|---|
| OpenVPN, WireGuard, IPsec | Be secure; make no attempt to hide | A signature for the first packet |
| Shadowsocks | Look like random noise | "Random noise" being itself unusual; probing |
| VMess | Own encryption plus pluggable transports | Overhead; recognisable patterns |
| Trojan, VLESS + TLS | Be a real HTTPS server | Blocking the domain; TLS-in-TLS analysis |
| VLESS + XHTTP behind a platform or CDN | Be ordinary web requests to a shared host | Blocking the specific hostname |
| VLESS + REALITY + Vision | Be indistinguishable from a major third-party site | Name-to-address checks; statistical analysis |
| Hysteria2, TUIC | Be HTTP/3 | UDP or QUIC throttling |

Each step raises what the censor must spend, in equipment and in collateral damage, to
block it. None makes blocking impossible.

### Summary table

| Protocol | Own encryption | Appearance on the wire | Needs |
|---|---|---|---|
| OpenVPN | Yes | Distinctive first packet | UDP or TCP |
| WireGuard | Yes | Fixed-size UDP handshake | UDP |
| IPsec / IKEv2 | Yes | Fixed ports and formats | UDP 500/4500 |
| Shadowsocks | Yes | Random bytes | TCP/UDP |
| VMess | Yes | Depends on transport | Varies |
| Trojan | No, relies on TLS | HTTPS to your own domain | TCP, domain, certificate |
| VLESS + TLS + XHTTP/WS | No, relies on TLS | HTTPS requests to a web host | An HTTPS endpoint |
| VLESS + REALITY | No, relies on REALITY | TLS to a well-known third-party site | Raw TCP |
| Hysteria2, TUIC | Yes (QUIC) | HTTP/3 | UDP |

## 8. Why this matters on filtered networks, with Pakistan as the example

**How filtering works in general.** A network operator that wants to restrict VPNs has a
few tools, in rising order of cost:

1. **Block known addresses.** Lists of commercial VPN server IPs and domains.
2. **Block by protocol signature.** Deep packet inspection recognises the fixed handshake
   of OpenVPN, WireGuard or IKEv2 and drops or throttles it, whatever server it goes to.
3. **Block by destination name.** Read the server name in the TLS handshake and block
   specific ones.
4. **Active probing and traffic analysis.** Connect to suspected servers, or study timing
   and size patterns statistically.

Methods 1 and 2 are cheap and catch the great majority of ordinary VPN use.

**The Pakistani context, as publicly reported.** Over the last few years there have been
recurring reports of platform-level blocks (including a prolonged block of X), of
upgrades to national filtering infrastructure with deep packet inspection capability, of
periods where commercial VPN services became slow or unreliable, and of a regulatory push
by the telecom authority toward registering VPN use, particularly for businesses and
freelancers. Verify the details and current status before quoting any of this.

**Why VLESS-style setups can be more effective there.**

- **No signature to match.** Method 2 does not apply. VLESS inside TLS presents as an
  HTTPS connection, which is what most of the internet already is.
- **Not on any list.** A self-hosted endpoint is not in a database of commercial VPN
  addresses, so method 1 does not apply either.
- **Blocking it has collateral cost.** In edge mode the connection goes to a mainstream
  cloud platform's domain on port 443. Blocking that address range or domain suffix also
  breaks every legitimate site hosted there. With REALITY the visible server name belongs
  to a major third-party site.
- **It survives on restricted networks.** Everything rides on TCP port 443, which is
  essentially never closed, where UDP-based protocols such as WireGuard are sometimes
  throttled or dropped outright.
- **Probing finds nothing.** With REALITY a probe gets a real website. In edge mode a
  request to any path other than the secret ones gets an ordinary "not found".

**What it does not give you.**

- **It is not invisible.** A specific domain can still be blocked by name (method 3), and
  statistical analysis (method 4) can flag tunnels, including the pattern of TLS traffic
  nested inside TLS. These are expensive for a censor, not impossible.
- **It is not anonymity.** The hosting platform knows who you are and, in edge mode, can
  see where your traffic goes. A proxy moves trust from your ISP to your host.
- **It is not a way around rules.** Hosting platforms' terms of service often restrict
  proxy workloads, and local law on VPN use applies regardless of the protocol.

## 9. Summary

- TLS termination is where encryption ends and the terminator can read the traffic. In
  edge mode that is the hosting platform; in direct mode it is your own container.
- VLESS is a minimal tunnel with no encryption of its own, which makes it fast and gives
  it no recognisable shape. It relies on its outer layer for both secrecy and disguise.
- REALITY is the strongest outer layer, impersonating a real website without needing a
  domain or certificate, but it requires raw TCP and so cannot run behind an HTTPS edge.
- Traditional VPN protocols are easy to recognise and therefore easy to block. Protocols
  that look like ordinary HTTPS are much harder to single out without breaking unrelated
  services.
- The single-port edge setup trades some privacy from the host for the ability to run on
  platforms that only offer one HTTPS port.
