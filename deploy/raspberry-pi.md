# Raspberry Pi Deployment

Target: Raspberry Pi 4, 4 GB RAM, ARM64 Debian 13. Docker and Compose are already installed. This guide stages the backend on loopback first. It does not open LAN access or provision real vault credentials.

## 1. Check the Pi

```sh
docker info --format '{{.ServerVersion}} {{.OSType}}/{{.Architecture}}'
ip -4 -brief address
ip -4 route
```

The first command confirms daemon access, not just client installation. If access is denied, use your existing administrative Docker access method. No Rust installation is needed on the Pi. Check that `172.28.93.0/29` does not overlap Docker, LAN, or VPN routes before starting the stack.

The current runtime limits allow 256 MiB for the API and 192 MiB for Caddy, excluding Docker/host overhead. Build on the workstation to keep compilation and its writes off the Pi's microSD card. Keep backups on another host; the source database and backups on the same microSD are not independent recovery copies.

## Confirmed network and FRITZ!Box setup

The Pi reports Docker Engine 29.9.0 on Linux/aarch64, LAN address `192.168.178.33/24`, and gateway `192.168.178.1`. Its listed Docker routes are `172.17.0.0/16`, `172.18.0.0/16`, and `172.19.0.0/16`; none overlap the backend's `172.28.93.0/29`. Recheck any future VPN routes separately.

On the FRITZ!Box 6670 Cable, open **Heimnetz → Netzwerk**, edit the Pi's entry, and reserve its existing `192.168.178.33` address using **Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen**. Leave the Pi using DHCP. Keep the router's internet DNS settings unchanged for this step.

The user verified directly from the Mac that the router's DNS resolves `pi.fritz.box` to `192.168.178.33`. The staging template now uses `VAULT_HOST=pi.fritz.box`. Confirm the Pi's system resolver when needed with `getent ahostsv4 pi.fritz.box`; router DNS resolution does not establish that every client uses that resolver.

If `.env.pi` already exists, preserve its contents and update `VAULT_HOST` to `pi.fritz.box`; copying the example does not change an existing file. Leave `VAULT_LAN_IP=127.0.0.1` during staging. The future LAN binding is `192.168.178.33`, after forwarding/firewall rules are checked. Do not create router port forwards. Local DNS over a future VPN must also be verified separately.

## 2. Build ARM64 images on the workstation

From this repository on your Mac, create the staging environment file once:

```sh
test -e .env.pi || cp .env.pi.example .env.pi
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose --env-file .env.pi -p private-vault-pi-build -f compose.yaml -f deploy/compose.pi.yaml build

docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' private-vault-api:pi-staging private-vault-proxy:pi-staging
docker image save --platform linux/arm64 --output /tmp/private-vault-pi-images.tar private-vault-api:pi-staging private-vault-proxy:pi-staging
```

Both images must report `linux/arm64`. Record their image IDs and the source commit for this build. `pi-staging` tags are staging conveniences; use unique release tags and retain previous image IDs before production upgrades. Building container userspace from Debian bookworm does not require the Pi host to use bookworm.

Transfer the archive over SSH to your Pi, replacing the example destination:

```sh
scp /tmp/private-vault-pi-images.tar your-user@your-pi:/tmp/private-vault-pi-images.tar
```

Docker image export contains application images, not the database's named volume. Do not copy private CA keys, enrollment tokens, or recovery identities through Git.

## 3. Import and stage on the Pi

Clone or update this repository on the Pi to the same source commit used for the images. From its root:

```sh
test -e .env.pi || cp .env.pi.example .env.pi
docker image load --input /tmp/private-vault-pi-images.tar
docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' private-vault-api:pi-staging private-vault-proxy:pi-staging

docker compose --env-file .env.pi -p private-vault -f compose.yaml -f deploy/compose.pi.yaml config --quiet
docker compose --env-file .env.pi -p private-vault -f compose.yaml -f deploy/compose.pi.yaml run --rm --no-deps --pull never api migrate
docker compose --env-file .env.pi -p private-vault -f compose.yaml -f deploy/compose.pi.yaml up --detach --no-build --pull never
```

Confirm the imported image IDs match the workstation. Keep `VAULT_LAN_IP=127.0.0.1` for now. Use this same project name and both Compose files for subsequent commands so volumes and image selection remain consistent. Do not run `down --volumes` against this staging/deployment project when it contains data.

## 4. Verify HTTPS locally on the Pi

Caddy may need a few seconds to create its local CA. Export only its public root certificate, then make a verified HTTPS request:

```sh
docker compose --env-file .env.pi -p private-vault -f compose.yaml -f deploy/compose.pi.yaml exec -T proxy cat /data/caddy/pki/authorities/local/root.crt > /tmp/private-vault-root.crt
curl --fail --cacert /tmp/private-vault-root.crt --resolve pi.fritz.box:443:127.0.0.1 https://pi.fritz.box/health
```

Expect `{"status":"ok"}`. Use your chosen hostname in both places if you changed `VAULT_HOST`. Do not bypass certificate checks with `curl -k`.

## 5. Enable LAN access afterward

Reserve a stable Pi address, configure private DNS, check subnet overlaps, and define LAN/VPN source restrictions that also cover Docker forwarding. Then change only the intended interface binding in `.env.pi` and recreate the proxy. Distribute the public root certificate through a trusted channel. Do not forward this port on your internet router.

Choose the permanent hostname before authenticator enrollment: changing the WebAuthn RP ID breaks existing credential bindings. The frontend/enrollment client is not implemented yet, so leave account provisioning for that milestone; a ten-minute enrollment token created now would expire unused.

The overlay is statically validated, but Pi-specific runtime checks require the commands above. Workstation validation does not prove the Pi's networking, storage reliability, or power-loss behavior.

## References

- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [Docker image export](https://docs.docker.com/reference/cli/docker/image/save/)
- [Docker image import](https://docs.docker.com/reference/cli/docker/image/load/)

## 6. Install the scoped LAN firewall before publishing HTTPS

The inspected Pi uses Docker's iptables-nft backend, with an empty `DOCKER-USER` chain. Do not edit the nftables tables marked as managed by iptables. The supplied host profile is specific to `eth0`, `192.168.178.33`, and trusted source subnet `192.168.178.0/24`.

Sync the updated deployment files to the Pi, then, from the repository root:

```sh
sudo iptables-save > /tmp/private-vault-iptables-before.txt
sudo sh deploy/install-pi-firewall.sh
sudo systemctl status private-vault-firewall.service --no-pager
sudo iptables -S DOCKER-USER
sudo iptables -S PV_PI_HTTPS
```

The installer applies the policy now and installs a systemd prerequisite for future Docker starts. It does not restart Docker or existing containers. On future boots **Docker will not start if this firewall unit fails**, which also affects the availability of the Pi's other Docker services. This is deliberate fail-closed startup ordering. Review the installed profile before running the installer.

The hook matches the connection's original destination `192.168.178.33:443`, rather than the changing container address or translated port 8443. Only that IPv4/TCP service is restricted. Original-direction traffic entering `eth0` from `192.168.178.0/24` returns to Docker's existing policy; other sources to that tuple are dropped. Reply-direction packets are not matched. SSH INPUT rules and the existing published ports 53, 8080, and 8082 are not modified. No IPv6 HTTPS publication is configured.

The script flushes only its own `PV_PI_HTTPS` chain and preserves other firewall rules. A temporary tuple-scoped DROP guard stays installed if a policy update fails. Reapplication is idempotent. Root-owned installed scripts and units, not the repository directory, are executed at boot. Do not change this rule with native `nft` commands or save/restore all of Docker's dynamic rules as a persistence mechanism.

## 7. Publish only the Pi LAN address and verify from the Mac

Once the firewall unit is active and its rules are verified, set this in the Pi's `.env.pi`:

```dotenv
VAULT_HOST=pi.fritz.box
VAULT_LAN_IP=192.168.178.33
```

Recreate only the proxy using the previously defined `vault_pi` function (or the full Compose command from section 3):

```sh
vault_pi up --detach --no-build --pull never proxy
vault_pi ps
```

Expect `192.168.178.33:443->8443/tcp`, with no IPv6 or wildcard publication. Copy the already-exported **public** root certificate to the Mac over SSH:

```sh
scp YOUR_PI_USER@192.168.178.33:/tmp/private-vault-root.crt /tmp/private-vault-pi-root.crt
curl --fail --cacert /tmp/private-vault-pi-root.crt https://pi.fritz.box/health
```

Replace `YOUR_PI_USER` with your SSH account. Expect `{"status":"ok"}`. This checks the Mac's default DNS, real LAN routing, hostname, and HTTPS trust. Do not create router port forwards, enable automatic port sharing for the Pi, or bypass TLS verification. The rule trusts the specified LAN; it cannot identify an internet client that another trusted device deliberately proxies or source-NATs into that LAN.

After the positive LAN check, this optional probe on the Pi uses a disposable untrusted-side Docker client without mounting data:

```sh
docker run --rm --network bridge --read-only --cap-drop ALL --security-opt no-new-privileges \
  --entrypoint python3 private-vault-api:pi-staging -c '
import socket
try:
    connection = socket.create_connection(("192.168.178.33", 443), timeout=3)
except TimeoutError:
    print("Connection dropped as expected")
else:
    connection.close()
    raise SystemExit("FAIL: untrusted Docker client reached HTTPS")'
sudo iptables -vnL PV_PI_HTTPS
```

A timeout together with an incremented DROP counter is evidence for the negative path; a timeout alone is not proof. Root-owned host access and deliberate proxying through a trusted LAN device are outside this network restriction. Future VPN source ranges require their own reviewed allowance and verification.

## Firewall maintenance and rollback

Use `sudo systemctl reload private-vault-firewall.service` to reapply a changed installed profile without restarting Docker. Keep the firewall unit active while LAN HTTPS is published.

For rollback, first change `VAULT_LAN_IP` back to `127.0.0.1` and recreate the proxy. Then remove only our systemd drop-in and rules:

```sh
sudo rm /etc/systemd/system/docker.service.d/private-vault-firewall.conf
sudo systemctl daemon-reload
sudo systemctl disable --now private-vault-firewall.service
sudo /usr/local/sbin/private-vault-firewall remove
```

The unit deliberately has no `ExecStop`, so stopping it does not remove firewall rules. Removing its Docker requirement before stopping the unit avoids propagating a stop to Docker. Do not flush global tables or delete Docker's `DOCKER-USER` chain. Recheck source policy after firewall-management or Docker backend changes; boot ordering and packet filtering still need live Pi verification.

[Docker's documented DOCKER-USER and conntrack matching behavior](https://docs.docker.com/engine/network/firewall-iptables/)
