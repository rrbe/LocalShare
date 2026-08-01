# Remote Sharing Plan

> Status: app implementation complete. Public-server deployment and end-to-end internet acceptance remain environment-specific.

## Goal

Allow a Mac running LocalShare to share files with a remote device that has only a web browser.

The first version should:

- use a user-owned public server and domain;
- require no companion app, VPN, or account on the receiving device;
- keep files on the Mac and stream them through the server without storage;
- preserve the existing `FileServer`, URL paths, token authentication, and QR flow;
- expose remote shares only while explicitly enabled;
- add no package-external runtime dylibs.

## Options Considered

| Approach | Browser-only receiver | Self-hosted | Fit for LocalShare |
|---|---:|---:|---|
| [frp SSH Tunnel Gateway](https://gofrp.org/en/docs/features/common/ssh/) behind Nginx | Yes | Yes | **Selected.** Uses macOS `/usr/bin/ssh`, reuses `FileServer`, and needs no bundled tunnel client. |
| Plain OpenSSH reverse forwarding behind Nginx | Yes | Yes | Smallest single-Mac setup, but frp adds HTTP host routing and a path to multiple clients without a custom control service. |
| [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/) / [ngrok](https://ngrok.com/docs/agent/) | Yes | No | Mature UX reference, but requires a vendor account, agent, and hosted edge. |
| [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) / [NetBird Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy) | Yes | Depends on provider | Adds a VPN identity/control plane and another agent; public proxy features are broader than the first version needs. |
| Tailscale, Headscale, or raw WireGuard mesh | No, unless a public gateway is added | Yes | Good for trusted devices or connected sites, but the receiver otherwise needs a VPN client. |
| [zrok](https://github.com/openziti/zrok) / [Pangolin](https://docs.pangolin.net/) | Yes | Yes | Closest complete products, but their control planes, connectors, and licensing/operations are unnecessary for one server and one active share. |
| WebRTC or relay-assisted transfer, such as [PairDrop](https://github.com/schlagmichdoch/PairDrop) or [Magic Wormhole](https://magic-wormhole.readthedocs.io/en/latest/file-transfer-protocol.html) | Sometimes | Yes | Requires a new transfer protocol and receiver flow instead of reusing LocalShare's HTTP browser. |
| Upload files to temporary cloud storage | Yes | Yes | Lets the Mac go offline, but stores file contents on the server and changes LocalShare's live-sharing model. |

## Decision

Use Nginx for the public HTTPS endpoint and frp's SSH Tunnel Gateway for temporary reverse forwarding:

```text
browser
  -> HTTPS :443
Nginx
  -> HTTP 127.0.0.1:18080
frps HTTP virtual host
  -> encrypted SSH reverse tunnel
macOS /usr/bin/ssh
  -> LocalShare FileServer
```

This is a relayed design, not peer-to-peer NAT traversal. All remote traffic crosses the user's server.

For the first version:

- one fixed public hostname, such as `share.example.com`;
- one active remote share per server;
- no database, allocation API, wildcard domain, or bundled tunnel binary;
- Nginx and frps run continuously, while the proxy registration, SSH connection, and share token are temporary.

## Server Plan

### Nginx

Nginx owns ports 80 and 443, redirects to HTTPS, and proxies the fixed share hostname to the private frps HTTP port.

The server block must:

- preserve `Host`;
- set `X-Forwarded-Proto` and `X-Forwarded-For`;
- disable response buffering for streamed downloads;
- allow only `GET` and `HEAD` in the first version;
- disable access logs for the share host, or redact the `t` query parameter;
- never cache responses.

Minimal proxy shape:

```nginx
location / {
    limit_except GET HEAD { deny all; }

    proxy_pass http://127.0.0.1:18080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 1h;
}
```

### frps

frps provides the SSH gateway and HTTP host routing.

Suggested ports:

| Port | Purpose | Public |
|---|---|---:|
| 443 | Nginx HTTPS | Yes |
| 2200 | frps SSH Tunnel Gateway | Yes |
| 18080 | frps HTTP virtual host | No |
| 7000 | regular frpc transport, unused by v1 | No |

Production configuration must:

- authenticate SSH clients with `sshTunnelGateway.authorizedKeysFile`;
- use a persistent SSH host key;
- run as an unprivileged service account;
- block ports 18080 and 7000 at the public firewall;
- avoid logging LocalShare share tokens.

## LocalShare Plan

### Configuration

Store only non-secret connection settings:

- public HTTPS origin;
- SSH host and port;
- optional SSH identity path;
- server host-key verification state.

Use the system SSH configuration, agent, `known_hosts`, and Keychain where available. Never disable strict host-key verification.

### Tunnel Lifecycle

Add one small `RemoteTunnel` component that launches `/usr/bin/ssh` with `Process`, passes arguments directly without a shell, captures errors, and exposes connection state.

The command shape is:

```bash
/usr/bin/ssh -T \
  -o BatchMode=yes \
  -o ClearAllForwardings=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -p 2200 \
  -R :80:<local-listen-address>:<local-port> \
  v0@relay.example.com \
  http --proxy_name localshare --custom_domain share.example.com
```

Lifecycle rules:

- start the tunnel only after `FileServer` has a listening port;
- keep the tunnel when share content changes, but rotate the share token;
- stop the tunnel when remote sharing or the share itself stops;
- keep it alive when the window closes, matching current server behavior;
- stop it when the app exits;
- report disconnection and retry with capped backoff while remote sharing remains enabled.

When "Current network only" is enabled, forward to the server's selected listen address instead of assuming loopback.

### URL and UI

Refactor URL construction to accept either the current LAN origin or the configured public HTTPS origin while preserving existing paths and `?t=` authentication.

The share screen adds:

- a Remote Access switch;
- connecting, online, and offline states;
- the public URL and QR code while remote access is active;
- retry and stop actions.

The LAN URL remains available.

### Security

Before enabling public access:

- raise share-token entropy to at least 128 bits;
- force remote sharing to read-only and disable upload/text receive routes at both the app and Nginx layers;
- mark cookies `Secure` for trusted HTTPS proxy requests;
- give remote shares a default one-hour lifetime;
- invalidate old tokens immediately on content change or stop;
- trust forwarded client IP headers only when remote mode is active and the request arrived through the local tunnel;
- document that Nginx terminates TLS, so the user-owned server is inside the trust boundary.

End-to-end encryption against an untrusted relay is not part of the first version.

## Delivery

1. Deploy Nginx and frps on a test server and repeat the existing local proof of concept over the public internet.
2. Add strong tokens and public-origin URL construction with unit tests.
3. Add `RemoteTunnel`, connection settings, and lifecycle handling.
4. Add the minimal remote-share UI and fixed expiration behavior.
5. Run unit tests, headless smoke tests, release build, and the dependency gate.

Public-server acceptance checks:

- no token returns 403;
- browser `?t=` -> cookie -> clean URL flow still works;
- a large file downloaded through Nginx and frp matches its source checksum;
- changing or stopping a share invalidates the old URL;
- stopping SSH makes the public endpoint unavailable;
- network changes reconnect without reviving an expired token;
- ports 18080 and 7000 are unreachable publicly;
- Nginx/frps logs do not contain share tokens.

## Deferred

Add these only when the single-server limit becomes real:

- multiple simultaneous Macs or users;
- wildcard subdomains and dynamic proxy allocation;
- a management API or account system;
- browser authentication beyond the LocalShare capability URL;
- P2P/WebRTC transport;
- resumable downloads;
- end-to-end encryption against an untrusted relay.
