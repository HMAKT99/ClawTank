# Reaching your Mac from anywhere

ClawTank only accepts connections from your local network. It never opens a port to the internet. To connect from outside your home or office, use **Tailscale**: a free (for personal use) private network between your own devices, built on WireGuard. ClawTank already accepts Tailscale addresses, so you don't need to change any settings.

## One-time setup (about 5 minutes)

1. **On the Mac:** install Tailscale from <https://tailscale.com/download/mac> (or the Mac App Store). Open it and sign in.
2. **On the device you'll connect from** (Windows PC, laptop, iPad, iPhone): install Tailscale and sign in with **the same account**.
3. On the Mac, open **ClawTank → Settings → Remote Access**. It shows a green check and the name to use, for example `studio.tail1234.ts.net`. Click **Copy**. The ClawTank menu also has **Copy Remote Address**.
4. In Windows App, Microsoft Remote Desktop or `mstsc`, add a PC with that name. Use your ClawTank username and password.

To connect, make sure Tailscale is connected on both devices. It reconnects automatically once set up. ClawTank checks the Tailscale status every 30 seconds.

## Why not port forwarding?

Forwarding TCP 3389 on your router exposes the Mac's login to everyone on the internet, and RDP ports are scanned constantly. ClawTank rejects public addresses by default, even if a port is forwarded. Allowing them takes deliberately turning off **Settings → Security → Local network only**, which we don't recommend. With Tailscale, only devices signed in to your tailnet can even reach the port.

## Waking a sleeping Mac

A sleeping Mac can't accept connections. Options, from simplest:

- **Keep it awake.** For an always-on Mac (for example a Mac mini), go to System Settings → Energy and turn on "Prevent automatic sleeping when the display is off". ClawTank itself keeps the Mac awake during a session.
- **Wake for network access.** Go to System Settings → Energy (laptops: Battery → Options) and turn on "Wake for network access". ClawTank shows whether it's on in Settings → Remote Access.
  - With a Mac on Ethernet and another always-on device on the same LAN, you can send a Wake-on-LAN magic packet. For example, `wakeonlan <mac-address>` from a Raspberry Pi or router that's reachable over Tailscale.
  - The Mac's Ethernet hardware address is in System Settings → Network → Ethernet → Details → Hardware.
  - Over Wi-Fi, wake from deep sleep is unreliable. Prefer keeping the Mac awake.
- **After a power cut:** on a Mac mini, turn on System Settings → Energy → "Start up automatically after a power failure".

Note that a locked Mac shows remote clients only the wallpaper (a macOS limitation, ADR-018). Log in at the Mac once after a restart.

## Troubleshooting

- **"Tailscale is installed but not connected (needs login)":** open Tailscale and sign in.
- **Connects at home but not away:** check that the other device shows Tailscale as connected, and that you're using the `*.ts.net` name or the `100.x.y.z` address, not the LAN address.
- **Name doesn't resolve:** turn on MagicDNS in the Tailscale admin console, or use the `100.x.y.z` address that ClawTank shows.
