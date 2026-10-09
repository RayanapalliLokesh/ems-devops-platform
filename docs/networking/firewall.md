# Firewalls: AWS security groups and ufw

Two firewalls appear in this project, at two different places:

```
internet ──► [ security group "alb" ] ──► ALB ──► [ security group "host" ] ──► EC2 NIC ──► [ ufw / iptables ] ──► process
               AWS, outside the VM                  AWS, outside the VM                       inside the VM (Phase 13)
```

| | Security group (Phase 14/15, Terraform since Phase 20) | ufw (Phase 13) |
|---|---|---|
| Where it runs | in the AWS network, before packets reach the instance | in the Linux kernel of the host (an iptables/nftables front end) |
| Default | deny all inbound, allow all outbound | what you configure (`ufw default deny incoming`) |
| Rules | allow only; no deny rules | allow and deny, in order |
| State | stateful (replies are allowed automatically) | stateful (conntrack) |
| Source can be | a CIDR **or another security group** (`host`: 80 from SG `alb`) | an IP or CIDR only |
| Survives a compromised host | yes; root on the VM cannot change it | no; root can run `ufw disable` |
| Sees Docker-published ports | yes, it filters before the VM | **no**, see below |
| Managed by | Terraform `modules/network` (earlier `network.sh` / `alb.sh`) | Ansible role `common` (earlier `install.sh`) |

## The rules in this project

**Security group `alb`:** inbound TCP 80 from `0.0.0.0/0`. Outbound only to SG `host` on port 80.

**Security group `host`:** inbound TCP 80 from **SG `alb`** (a group reference, not a CIDR, so it keeps
working when ALB nodes change IP), and TCP 22 from your `/32`. Nothing else. 5000 and 5432 have no rule. The
monitoring ports are bound to 127.0.0.1, so you reach them through an SSH tunnel and they need no rule either.

**ufw (Phase 13, host services):**
```
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw enable
sudo ufw status verbose
```
In Phase 13, gunicorn (127.0.0.1:5000) and PostgreSQL (127.0.0.1:5432) were bound to loopback anyway. ufw
added a second layer: a mistaken `bind = 0.0.0.0:5000` was still unreachable from outside.

## Why ufw does not protect Docker-published ports

Docker writes its own iptables rules. A published port (`ports: ["5000:5000"]`) is DNAT-ed in the
`nat PREROUTING` chain and accepted in the `FORWARD` chain (`DOCKER`, `DOCKER-USER`). ufw filters the `INPUT`
chain, which these packets never pass through. So `ufw deny 5000` would **not** block a published container
port. Lessons:

1. Do not publish what must stay private. `app` and `db` have no `ports:` in docker-compose.yml.
2. When a UI must be published, bind it to loopback: `127.0.0.1:9090:9090`.
3. Rely on the security group as the real perimeter. It sits outside the VM and filters Docker traffic too.
4. If you need host-level filtering of container traffic, put the rules in the `DOCKER-USER` chain. Docker
   does not overwrite that chain.

The ufw rules can stay enabled for 22/80 on the host after Phase 17, but the exposure guarantee comes from
"not published" plus the security group. `netcheck.sh` checks the result (layer 5). Run it from outside too,
for example from your laptop against the EC2 public IP: 5000 and 5432 must not answer, and with the `host`
group, port 80 must not answer either. Only the ALB DNS name should work.

## Checking

```
sudo iptables -t nat -L DOCKER -n           # what Docker publishes
sudo iptables -L DOCKER-USER -n             # your own rules for container traffic
sudo ufw status numbered
aws ec2 describe-security-groups --group-ids <sg-host> --query 'SecurityGroups[].IpPermissions'
scripts/net/netcheck.sh --host <ec2-public-ip> --port 80   # expected: tcp FAIL (only the ALB may connect)
scripts/net/netcheck.sh --host <alb-dns-name> --port 80    # expected: all PASS
```
