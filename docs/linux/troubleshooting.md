# Linux troubleshooting for the EMS host

Start with `scripts/linux/triage.sh`. It prints all of the sections below on one screen and changes nothing.
Then use the commands here to dig into the section that looks wrong. Work from the bottom of the stack up:
host → Docker → containers → application.

```
sudo scripts/linux/triage.sh                                   # on EC2 (nginx on :80)
scripts/linux/triage.sh --url http://127.0.0.1:8080/health     # local stack (EMS_HTTP_PORT=8080)
```

## 1. Processes and load

| Question | Command | What to look for |
|---|---|---|
| Is the box overloaded? | `uptime`, `nproc` | a 1-minute load well above the CPU count |
| Who uses the CPU? | `ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu \| head` or `top -o %CPU` | gunicorn at 100% means a slow request or a busy loop |
| Which processes belong to the app? | `docker top ems-app-1` | one gunicorn master and `GUNICORN_WORKERS` workers |
| Process tree including containers | `ps -ef --forest \| less` | containers are ordinary processes under `containerd-shim` |
| What is a process doing? | `sudo strace -p PID -f -e trace=network,read,write` | blocked in `connect()` means a network or DB wait |
| Open files and sockets | `sudo lsof -p PID` or `sudo ls -l /proc/PID/fd` | thousands of open sockets suggests a leak |

Inside a container the PIDs are different. `docker top` shows the host PIDs, and those are what `strace` needs.

## 2. Memory

| Question | Command |
|---|---|
| Free memory | `free -h`. Read the **available** column; "free" alone is misleading because of the page cache |
| Per-container usage against the limit | `docker stats --no-stream` (app 512m, db 512m, nginx 128m) |
| Was something OOM-killed? | `sudo dmesg -T \| grep -i -E 'out of memory\|oom-kill'`, `journalctl -k --since -1h \| grep -i oom` |
| Did Docker see the OOM? | `docker inspect ems-app-1 --format '{{.State.OOMKilled}} {{.RestartCount}}'` |

A worker killed by the cgroup OOM killer shows up in the app log as `Worker (pid:N) was sent SIGKILL! Perhaps out of memory?`.
gunicorn starts a new one. The `max_requests = 1000` setting recycles workers, which also limits slow leaks.

## 3. Storage

| Question | Command |
|---|---|
| Which file system is full? | `df -h` and `df -i` (inodes run out too) |
| What is big? | `sudo du -xh / --max-depth=2 2>/dev/null \| sort -h \| tail -15` |
| Docker's share | `docker system df` and `docker system df -v` |
| Deleted but still open (space not freed) | `sudo lsof +L1` |
| Old images and build cache | `docker image prune -a --filter until=168h`, `docker builder prune` |
| Container logs | `sudo du -sh /var/lib/docker/containers/*/*-json.log` |

When the disk is full, PostgreSQL stops accepting writes (`could not extend file`), and `/health` answers 503.
Free space first, then check `docker compose -p ems ps`. Backups in `/var/backups/ems` are limited by
`backup-db.sh --keep N`.

## 4. Services: the Docker engine and the Compose stack

| Question | Command |
|---|---|
| Is Docker running? | `systemctl status docker`, `journalctl -u docker --since -30min` |
| Stack status and health | `docker compose -p ems ps` (`(healthy)`, `(unhealthy)`, `Exited (1)`) |
| Why is a container unhealthy? | `docker inspect ems-app-1 --format '{{json .State.Health}}' \| jq` |
| Logs | `docker compose -p ems logs --tail 100 -f app nginx` |
| Only errors | `docker logs ems-app-1 2>&1 \| grep -E '"level": "(ERROR\|CRITICAL)"'` |
| Restart one service | `docker compose -p ems restart app` |
| Recreate after a config change | `cd /opt/ems && docker compose up -d app` |

On EC2 the stack lives in `/opt/ems`, and Ansible's `ems_stack` role manages it. A change made by hand is
overwritten by the next Ansible run, so put lasting fixes into the role.

## 5. Network (short version; see docs/networking/)

| Question | Command |
|---|---|
| What listens where? | `sudo ss -tlnp` (expect `0.0.0.0:80` docker-proxy, `:22` sshd, `127.0.0.1:9090/9093/3000/16686`) |
| Layer-by-layer check | `scripts/net/netcheck.sh --host 127.0.0.1 --port 80` |
| Can nginx reach the app? | `docker compose -p ems exec nginx wget -qO- http://app:5000/health` |
| Can the app reach the database? | `docker compose -p ems exec db pg_isready -U ems` |

## 6. Logs on the host

| Source | Command |
|---|---|
| Kernel (OOM, disk errors) | `sudo dmesg -T \| tail -50`, `journalctl -k -p warning` |
| Everything since boot, errors only | `journalctl -b -p err` |
| SSH logins | `journalctl -u ssh --since today` |
| cloud-init (first boot on EC2) | `/var/log/cloud-init-output.log` |
| Ansible changes | the `changed=` count in the play recap |

## 7. A short checklist for "the site is down"

1. `netcheck.sh`. The first FAIL from the top tells you the layer.
2. `docker compose -p ems ps`. Is any service unhealthy or exited?
3. `docker compose -p ems logs --tail 50 <service>`. What does it say?
4. `df -h`, `free -h`, `dmesg | grep -i oom`. Is a resource exhausted?
5. Fix it, then run `netcheck.sh` again and `curl /health`, and write down what happened (docs/learning-log).
