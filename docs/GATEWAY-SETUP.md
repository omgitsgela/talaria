# Pointing Talaria at a Hermes gateway

Talaria is a client. Everything it shows you comes from a Hermes Agent gateway that you run or that
somebody shares with you. This page is the short version of getting one running and reachable from
your phone.

The process the app connects to is the Hermes **dashboard** server. That is what serves the WebSocket
and the JSON RPC the app speaks; the messaging gateway (Telegram, Discord, Slack and the rest) is a
separate process and is not what Talaria talks to.

## 1. Install Hermes Agent on the machine that will run the gateway

Follow the [Hermes Agent documentation](https://hermes-agent.nousresearch.com/docs) for installation.
You do not need to run the agent interactively for Talaria to work, but the machine should be one
that stays on: a home server, a spare computer, or a VM.

## 2. Start the dashboard

By default it listens on loopback only, which a phone cannot reach:

```bash
hermes dashboard
# http://127.0.0.1:9119, and it opens a browser for you
```

For a phone, bind an address your network can reach and skip the browser:

```bash
hermes dashboard --host 0.0.0.0 --port 9119 --no-open
```

**A non-loopback dashboard refuses to start without an authentication provider.** That is deliberate
and it is what keeps your gateway from being an open door on your network. The first interactive run
offers to set one up on the spot; see the next step for doing it yourself.

## 3. Give it something to authenticate with

Two supported options, and Talaria works with either:

**Username and password (the bundled `basic` provider).** In `~/.hermes/config.yaml`:

```yaml
dashboard:
  basic_auth:
    username: you
    password_hash: "<hash>"
    # generate the hash with:
    # python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('YOUR-PASSWORD'))"
```

**OAuth.** Point the gateway at an identity provider with `hermes dashboard register`.

Either way the gateway advertises its native sign-in flow, which is what makes **Sign in with Hermes**
appear in the app. The sign-in happens in your phone's real browser, so password managers and passkeys
work normally. A token-only provider does not advertise it, and the app will not offer that button.

## 4. Check it from the phone before you open the app

Open this in your phone's browser, using the same address you will type into Talaria:

```
http://YOUR-GATEWAY-ADDRESS:9119/api/status
```

You are looking for two things:

- `"auth_required": true` means the gate is on. If it says `false`, the dashboard is bound to
  loopback and your phone will be refused at the socket, no matter what credentials you use.
- a provider in `"auth_providers"` (for example `["basic"]`) means the sign-in it offers will work.

Then open `http://YOUR-GATEWAY-ADDRESS:9119` itself. The dashboard page should load. If both of those
work in the browser, the app can reach the gateway too.

## 5. Connect the app

Launch Talaria, enter the URL (for example `http://192.168.1.50:9119`), and tap **Sign in with
Hermes**. The browser opens, you approve, and the app stores its own token on the device.

If you would rather not sign in, the app also accepts a bearer token you minted elsewhere, and a
session token for loopback or `--insecure` gateways. Those are the fallbacks, not the main path.

## 6. Keep the dashboard running

A gateway you started by hand stops when you close the terminal or reboot. Run it as a service. Under
`systemd`, with the credentials in `~/.hermes/.env`:

```ini
[Service]
EnvironmentFile=%h/.hermes/.env
ExecStart=/path/to/venv/bin/python -m hermes_cli.main dashboard \
    --host 0.0.0.0 --port 9119 --no-open
Restart=on-failure
```

## Reaching it from outside your own network

The simplest option that stays safe is a private network between your devices: WireGuard, Tailscale or
ZeroTier. Install it on the gateway machine and on your phone, then use the address it gives the
gateway. Nothing is exposed to the public internet.

If you must reach it over the internet, put it behind a reverse proxy with TLS and use an `https://`
address in the app, because everything you send, including your credentials, travels with each request.
Do not expose a plain HTTP dashboard to the internet.

## When it does not connect

- **The phone's browser cannot open the address.** The network is the problem, not the app. Check the
  firewall, confirm both devices are on the same network or the same VPN, and confirm the dashboard
  was started with `--host 0.0.0.0`.
- **`/api/status` says `auth_required: false`.** The dashboard is on loopback only. Restart it bound
  to a reachable address.
- **The sign-in page opens but the app never finishes connecting.** Look at the dashboard's own log
  and the WebSocket close code: `4403` means the request guard rejected it, usually because the host
  in the URL does not match what the dashboard is bound to, and `4401` means the sign-in ticket did
  not authenticate. Retrying with the exact address the dashboard was started on fixes the first
  case.
- **It worked yesterday and not today.** A hand-started dashboard died with its terminal, or the
  machine's address changed. Give it a static address or a name, and run it as a service.
