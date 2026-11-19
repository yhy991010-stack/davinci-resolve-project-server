# 自建达芬奇网络项目库

在 Docker 或绿联 NAS 上跑一个 [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve) 能直接连接的 PostgreSQL 项目服务器。电脑和 iPad 都可以连同一个工程库。

官方项目服务器本质就是 **PostgreSQL 13**，客户端端口写死为 **5432**，改不了。本仓库用官方 `postgres:13` 镜像，再加上绿联等 NAS 上实际踩过的网络处理，不需要再做一个定制数据库镜像。

> 这个库只存工程（时间线、调色、媒体池引用），**不含素材文件**。素材仍然走 NAS 共享（SMB / AFP 等），每台电脑都要能访问同一路径。

**不要把 5432 端口映射到公网。** 远程请走 Tailscale、WireGuard 这类组网，不要用域名或路由器端口转发把数据库暴露出去。

## 先看你属于哪一种

| 情况 | 用哪种方式 | 达芬奇里填的地址 |
| --- | --- | --- |
| 普通 Linux / 电脑，宿主机 **5432 空闲** | 方式 A `simple` | 这台机器的局域网 IP |
| 绿联 UGOS 等系统 **已经占用了 5432** | 方式 B `macvlan` | `.env` 里的 `DB_IP` |
| 还要在外面经 **Tailscale** 连（macvlan 地址常常进不去） | 方式 C `shim` | `.env` 里的 `SHIM_IP`，或 NAS 的 Tailscale 地址 |

绿联 UGOS 的典型情况是：系统自己内部也跑着数据库，占着 NAS 的 5432。这时就算在 Docker 里写了 `5432:5432`，外面连上的也不是达芬奇这一套，甚至完全连不上。所以不能把项目库直接挂在 NAS 的主机地址上，要另分一个局域网 IP。

另外，macvlan 分出去的地址，经 Tailscale 的子网路由经常到不了。需要再在 NAS 上用一个转发容器，在第二个局域网 IP（以及 Tailscale 地址）上监听 5432，转到数据库。同时还要给这两条路径加 NAT 例外，否则系统还是会把 5432 转走。

## 准备

- 已安装 Docker 和 Docker Compose 插件（绿联若只能在图形界面里建容器，也可以按同样参数手动创建，见文末）
- 在局域网里挑 **尚未占用** 的 IP（方式 B / C）
- 自己准备用户名和密码，写进 `.env`，不要提交到 Git

如果 NAS 拉不了 Docker Hub 上的镜像，可以在能联网的电脑上执行：

```bash
docker pull postgres:13
docker save postgres:13 -o postgres-13.tar
```

把 `postgres-13.tar` 拷到 NAS 后，在 Docker 里导入镜像即可。

## 部署

```bash
git clone https://github.com/yhy991010-stack/davinci-resolve-project-server.git
cd davinci-resolve-project-server
cp .env.example .env
# 编辑 .env：改密码；方式 B/C 还要改网卡名、网段和空闲 IP
```

网卡名在 NAS 上可以用 `ip -br addr` 查看，绿联上常见是 `eth0`。

然后选一种：

```bash
chmod +x scripts/deploy.sh shim/entrypoint.sh

# 方式 A
./scripts/deploy.sh simple

# 方式 B（系统占了 5432）
./scripts/deploy.sh macvlan

# 方式 C（还要 Tailscale 远程）
./scripts/deploy.sh shim
```

也可以直接调用 compose，例如方式 C：

```bash
docker compose --env-file .env -f compose.macvlan.yml up -d
docker compose --env-file .env -f compose.shim.yml up -d --build
```

数据默认写在 `./data`。绿联建议把 `DATA_DIR` 改成 Docker 共享文件夹下的路径，方便备份。

## 在达芬奇里连接

1. 打开 **项目管理器**（电脑是侧边栏的库图标，iPad 是房子图标）
2. **添加项目库**
3. 第一台设备选 **创建 + 网络**；以后其他设备选 **连接**
4. 填写：
   - **名称**：例如 `MyProjects`。不要用空格和中文。
   - **位置**：上面表格里对应的 IP，不要加端口
   - **用户名 / 密码**：`.env` 里的 `POSTGRES_USER` / `POSTGRES_PASSWORD`
   - 端口保持默认 `5432`
5. 经 Tailscale 从外面连时，设备上打开 Tailscale，**Exit Node 选无**（不要把流量都从 NAS 出去）

多人同时打开同一个工程做协作剪辑，通常需要 Studio 版。只是共用一个工程库、不同时写同一个项目，免费版也可以。

## 当时还改过哪些设置

这些不是达芬奇软件里的选项，而是要把数据库真正送到 5432 上必须处理的环境问题：

1. **必须用 PostgreSQL 13**，并让客户端连到 **5432**。换端口达芬奇不认。
2. **不要用系统已经占用的 5432。** 绿联 UGOS 会在 NAS 本机占用这个口；直接做端口映射会失败，或被转到系统自带的库。正确做法是 macvlan，让数据库容器拥有自己的局域网地址，在该地址上独占 5432。
3. **容器必须接到可用网络上。** 创建时如果没选对网络，容器只能自己连自己，外面谁都进不去。
4. **macvlan 地址经 Tailscale 子网路由往往不通。** 再加一个 `host` 网络的转发容器，在第二个局域网 IP 和 NAS 的 Tailscale 地址上监听 5432，用 socat 转到数据库。
5. **给转发地址加 NAT 例外。** 否则绿联仍可能把到达这些地址的 5432 做 DNAT，转到系统库后丢掉。`shim` 启动时会尝试写入这些例外；NAS 重启后如果失效，把转发容器再启动一次即可。
6. **绿联 Docker 的限制：** 不少版本不能事后改环境变量，容器里也没有终端。改配置通常只能删掉重建（数据目录要挂在容器外面，重建才不会丢库）。
7. **不要把 5432 做到公网域名或路由器端口映射上。** 远程用 Tailscale。
8. 时区建议写成你所在地区（示例为 `Asia/Shanghai`）。`shm_size` 建议至少 `256mb`。

除此之外，没有要在达芬奇里改端口、改协议，或在 PostgreSQL 里做特殊插件。第一次在达芬奇里点「创建」网络库时，软件会自己在这个 Postgres 里建好项目库。

## 绿联图形界面手动创建（没有 compose 时）

数据库容器：

- 镜像：`postgres:13`
- 网络：macvlan，父网卡选 NAS 的局域网网卡，IP 填 `DB_IP`
- 环境变量：`POSTGRES_USER`、`POSTGRES_PASSWORD`、`TZ`、`PGTZ`、`PGDATA=/var/lib/postgresql/data/pgdata`
- 存储：把 NAS 上的数据目录映射到 `/var/lib/postgresql/data`
- 共享内存：256MB
- 重启策略：总是 / 除非手动停止
- **不要**再映射主机的 5432 端口

转发容器（需要远程或发现 `DB_IP` 经 Tailscale 不通时）：

- 用本仓库 `shim/` 构建，或先在能联网的机器构建后导入
- 网络：`host`
- 特权模式打开（要加 IP 和 NAT 例外）
- 环境变量与 `.env` 相同：`LAN_PARENT`、`LAN_SUBNET`、`DB_IP`、`SHIM_IP`、`TAILSCALE_IP`、`APPLY_NAT_EXEMPT=1`

## 备份

项目库一般只有几百 MB 级，备份数据目录或使用 `pg_dump` 都可以。例如：

```bash
docker exec -t davinci-db pg_dumpall -U "$POSTGRES_USER" > davinci-backup.sql
```

恢复前请先停容器并另行备份当前数据目录。

## 许可

MIT。欢迎直接用，也欢迎按自己的网段改。
