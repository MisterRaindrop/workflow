# 稳定化方案

针对实战暴露的问题，逐条给出方案。按「会不会让它突然坏掉」排序。
后台守护（自动冻结 + 定期采样）**暂缓**，优先级不高。

> **状态（2026-08-12）：§1–§8 全部实现并通过真机验证。** 测试从 57 个断言扩到 107 个。

已解决的项不在此列。

---

## 1. 出网规则丢失 —— 已修，记录在此

**问题**：`iptables` 规则不持久，host 重启后消失；而 LXD 会自动把容器拉回 RUNNING。
原先 `ensure_running()` 只在容器 STOPPED 时补规则，容器已 RUNNING 时直接返回 ——
于是重启后所有 wk 命令都不会修复规则，构建**静默失败**。

**已复现**：手工删除规则 → 容器保持 RUNNING → `wk exec` 返回 `rc=0` → 规则未恢复 → 容器 BLOCKED。

**修复**：`ensure_egress()` 移到 `ensure_running()` 开头无条件执行。
已验证：删规则 → `wk exec` → 规则自动恢复 → 可达。

**残留窗口**：开机后到第一条 wk 命令之间仍是空的。彻底解决要靠开机时执行一次，
属后台守护范畴（暂缓）。当前可接受，因为任何一条 wk 命令都会补齐。

---

## 2. 重试只覆盖 apt

**问题**：代理会间歇性抽风（观察到两次，几分钟自愈）。`wk` 内部的 apt 已有 5 次重试，
但项目构建脚本里的 conan / Maven / curl 在 wk 管辖之外，一次抖动就能打断几十分钟的构建。

**方案 A：开工前的确定性 —— `wk doctor` 增加代理健康探测**

不只测「代理端口是否 OPEN」，而是真的取一次东西，内外网各一个目标：

```
proxy → 内网仓库        期望 200
proxy → 公网已知地址     期望 200
容器 → WK_DIRECT_HOSTS  期望 TCP 通
```

让「现在能不能开工」在开工前就有答案，而不是在构建到一半时才炸。
代价：doctor 慢几秒。

**方案 B：给长任务一个自动恢复 —— `wk exec --retry N`**

```bash
wk exec --retry 3 lxslot3 "make build-database"
```

对 make 这类**增量**构建，重试是安全的：失败后重跑会跳过已完成的部分。
实现是在 `cmd_exec` 外层加循环，失败时按退避重试。

**不做的**：不去改项目脚本给 conan/mvn 加重试 —— 那是项目的事，
而且改了也只覆盖当前这一个项目。

---

## 3. 并发保护

**问题**：两个终端同时对同一容器 `bind` / `up` / `warm`，行为未定义。
取消 slot 自动分配后竞争面小了很多，但没消失 —— 尤其 `bind` 会 remove/add device，
和正在起服务的 `up` 撞上会留下半绑定状态。

**方案：per-container 文件锁**

```bash
WK_RUN_DIR=${WK_RUN_DIR:-/run/wk}     # tmpfs：重启自动清空，不会留下死锁

lock_slot() {
    local name=$1
    mkdir -p "$WK_RUN_DIR"
    exec {WK_LOCK_FD}>"$WK_RUN_DIR/$name.lock"
    flock -w 30 "$WK_LOCK_FD" \
        || die "another wk operation is running on $name (waited 30s)"
}
```

**加锁**：`bind` `unbind` `up` `down` `warm` `auth` `new` `rm` `pause` `stop` `start`
**不加锁**：`ls` `verify` `doctor`（只读）、**`exec` / `enter`**
—— 后两者是长任务，加锁会把容器锁死几十分钟，反而制造问题。

锁放 `/run`（tmpfs）而不是 `/var`：进程被 kill 或 host 重启后不会留下需要手工清理的死锁。

---

## 4. 测试覆盖不到 lxc 交互

**问题**：单测只覆盖纯函数（54 个）。所有 `lxc` / `docker` 调用没有任何自动化验证。
实证：这两天改 wk 时引入过两个 bug（函数改名后漏改一处调用、`grep` 模式假设了
iptables 输出顺序），**都是靠在真机上跑才发现的**。对「稳定」而言这是硬伤。

**方案：注入一个假的 `lxc`**

关键前提已经具备 —— 所有调用都经过 `lxc_()`，且 `WK_LXC` 可配置。
这层间接原本是为多 host 留的，正好拿来做测试注入：

```bash
# test/fake-lxc —— 按参数返回预设输出，并把调用记录下来
case "$1 $2" in
  "list --format")  echo "lxslot1,RUNNING" ;;
  "config get")     echo "${FAKE_META[$3.$4]:-}" ;;
  "config device")  ... ;;
esac
echo "$*" >> "$FAKE_LXC_CALLS"
```

```bash
WK_LXC=test/fake-lxc bash wk ls
```

**能覆盖**：命令分发、参数解析、容器名解析、device/元数据读取、状态分支、
错误路径、以及「某个函数名写错了」这类低级但致命的问题。

**覆盖不到**：真实的 LXD/Docker 行为。那仍然只能靠 host 上的 `wk doctor` + `wk smoke`。

**价值**：今天那两个 bug 里，函数名漏改会被立刻抓到；
iptables 的那个需要同时假造 `iptables`，同理可做。

---

## 5. 没有操作日志

**问题**：谁在什么时候把哪份代码绑到了哪个容器、什么时候删过东西 —— 事后无从追溯，
只能靠回忆。出问题时这正是最需要的信息。

**方案：写 journald，零维护**

```bash
audit() {
    command -v logger >/dev/null 2>&1 || return 0
    logger -t wk -- "$*"
}
# 每个写操作调用一次
audit "bind $name $dir (by ${SUDO_USER:-$USER})"
```

查询：`journalctl -t wk --since today`

选 journald 而不是自己写文件：轮转、权限、并发写全部由系统负责，wk 不需要管。
只记**写操作**（bind/unbind/new/rm/up/down/pause/stop/start/warm/auth），
只读命令不记，避免噪音。

---

## 6. 镜像缓存只增不减

**问题**：`wk warm` 的 tar 永久保留在 `WK_IMAGE_CACHE`，包括 18.3GB 的编译镜像。
加上每个容器各存一份镜像（本机约 57GB/容器），磁盘持续增长（data500 已用 51%）。

**方案：给缓存加上限 + 显式管理命令**

```bash
WK_CACHE_MAX_GB=${WK_CACHE_MAX_GB:-50}

wk cache ls       # 列出 tar：镜像名、大小、最后使用时间
wk cache prune    # 按 LRU 删到 WK_CACHE_MAX_GB 以内
```

`wk warm` 结束后自动跑一次 prune。tar 只是加速用的中间物，删了不影响已 load 的镜像，
所以回收是安全的。

**注意**：这只管 host 侧的 tar 缓存。容器内的镜像占用（每容器一份）是
「镜像不共享」这个决策的既定代价，不在此方案内 —— 那要靠 `wk rm` 回收整个容器。

---

## 7. 跨容器镜像复制

**问题**：给新容器灌镜像目前只能走 host（`docker save` → tar → push → load），
要求 host 本身有该镜像。实战中 18.3GB 编译镜像只存在于另一个容器里，
只能手工执行管道命令。

**方案：`wk warm <dst> --from <src>`**

```bash
lxc exec <src> -- docker save <image> | lxc exec <dst> -- docker load
```

管道直传，不落盘、不经网络、不要求 host 有这个镜像。已手工验证有效（18.3GB 传输成功）。

---

## 8. `wk ls` 列宽

**问题**：CODE 列固定 38 字符，长路径会把 NOTE 挤出屏幕。

**方案**：先扫一遍算出实际最大宽度再排版；超过终端宽度时中间截断
（`/mnt/.../project` 这种形式），保留头尾这两段最有辨识度的信息。

---

## 9. systemd 单元里 guest 输出全部丢失 —— 已修，记录在此

**现象**：`systemd-run --unit=x wk new lxslot2` 失败，journal 里只有 wk 自己的
`=> installing Docker in lxslot2` 和 systemd 的 exit-code，**guest 里 5 分钟的
apt 重试与最终报错一行都没有**。诊断时完全无从下手。

**根因**（实测最小复现）：journald 给单元的 stdout/stderr 是 **socket**，
而 LXD client 不把 `lxc exec` 的 guest 输出转发进 socket —— 只有退出码传出来：

```bash
systemd-run --wait lxc exec c1 -- bash -c "echo OUT; echo ERR >&2; exit 3"
# journal: 只有 systemd 的 status=3，OUT / ERR 都不见
systemd-run --wait bash -c 'lxc exec c1 -- bash -c "..." 2> >(cat >&2) | cat'
# journal: OUT / ERR 都在 —— lxc 的 stdio 是管道时转发正常
```

**修法**：wk 启动时检测自己的 stdout/stderr 是不是 socket，是就
`exec 1> >(cat)` / `exec 2> >(cat >&2)` 自我重管道 —— 子进程看到的是管道，
cat 落到 socket 的普通写不受影响。一处修复覆盖所有 `lxc exec` 调用。

配套两点：guest heredoc 里加 `trap ... ERR` 报出具体死在哪条命令；
`cmd_new` 的各安装阶段加 `|| die`，并提示 `wk new` 幂等、重跑即续。
否则 `set -e` 下失败是静默的 —— 这次排障的成本就花在「双重静默」上。

---

## 10. 一个可选工具装不上，整个容器被判废 —— 已修，记录在此

**现象**：`wk new lxslot2` 失败退出。但容器里 Docker、git、make、tmux、codex、
凭据、代理**全部正常** —— 唯一没成的是 `npm install -g @anthropic-ai/claude-code`。
一个编译环境完全可用，却因为一个 agent CLI 被扔掉。

**两层根因，缺一不可**：

1. **分层缺失**。`install_tools` 把编译必需的（git/make/curl/jq/tmux）和便利性的
   （nodejs/npm → codex/claude）放在同一条 apt 里，一起 `retry`，一起失败。
   实测：代理大面积丢 TLS 握手时，git/make/tmux 全装上了，只有 nodejs 的 20 多个
   依赖 .deb 失败 —— 但整条命令返回非零。

2. **`set -e` 把可选变成致命**。`npm install -g` 一失败，guest 脚本立刻退出，
   `install_tools` 非零，`cmd_new` 的 `|| die` 触发。

**还有第三个真因，npm 自己不说**：
```
npm WARN EBADENGINE package: '@anthropic-ai/claude-code@2.1.235',
                    required: { node: '>=22.0.0' }, current: { node: 'v18.19.1' }
```
Ubuntu 24.04 的 apt 只有 node 18，而 claude-code 要 22。npm 的日志通篇在说
`network`/`ECONNRESET`，于是人去修代理 —— 修完还是装不上。

**修法**：
- apt 分两层：必需的失败才致命，nodejs/npm 失败只报告。
- `npm install` 加重试且永不致命；claude-code 先查 node 大版本，不够就直说
  「node 18 装不了，需要 22；在 host 上装好，wk 会把 host 的包拷进去」。
- host 包探测覆盖 `npm root -g` / `/usr/lib` / `/usr/local/lib` —— 只看一处，
  等于 host 明明有却仍然去 npm。
- `verify` 分两级严重度，退出码区分：**2 = 不能编译**（docker/git/make/代理），
  **1 = 能编译但 agent 工具不全**，0 = 全绿。并且 host 自己都没有的 CLI
  不计为容器的问题 —— 那是 host 侧的事实，报错要指向对的地方。

顺带补上一个一直没查的项：`verify` 从来没检查 `make`，而它正是编译的入口。

---

## 11. 一份扁平的服务清单挡住了另一套服务 —— 已修

**问题**：`.wk.yaml` 只有一个 `services:` 列表，`wk up` 全起。而一个 checkout 里
可能有**多套互不相干**的服务栈，各自从不同的 registry 供给镜像。实测遇到的一例：

| 栈 | 容器 | 镜像来源 |
|---|---|---|
| 集成测试 | polaris / minio / hadoop / hive-metastore / hiveserver2 / spark-master / spark-worker / postgres | registry A（本机已全部具备） |
| CI fixture | mysql / hive / mysql-s3 / hive-s3 一组 | registry B（**本机一个都没有**） |

`services_up` 用 `--pull never`（镜像由 `wk warm` 供给，缺了就该立刻失败而不是偷偷
联网）。于是一份扁平清单的后果是：CI 那五个镜像不在本机 → 整批 compose 失败 →
**datalake 那套也起不来**。

**修法：分组就是一个后缀键**。`services_ci:` 与 `services:` 并列，
现有的列表解析器原样能读，不引入新语法；不带 `--group` 时行为与以前完全一致。

```bash
wk up lxslot2            # 默认组：datalake
wk up -g ci lxslot2      # CI 那套
wk smoke -g ci lxslot2
```

两套的容器名与端口实测不冲突（CI 只暴露 3306，datalake 用 5432/9000/8181/9083/…），
所以同一个 slot 里共存没问题 —— 分组是为了**按需启动**和**互不牵连**，不是为了避冲突。

---

## 12. 注入的代理拦掉了容器间通信 —— 已修，这是本轮最严重的一个

**现象**：datalake 那套 10 个容器全部起来了，`docker ps` 一片 Up，`minio-init`
还是 `Exited (0)`。但 minio 的两个桶（`warehouse` / `data`）**一个都没建成**，
`/data` 里只有 `.minio.sys`。

**因果链**（每一步都实测过）：

1. `install_docker` 写 `/root/.docker/config.json`，其中
   `proxies.default.noProxy` 只有 `localhost,127.0.0.1,::1`。
   这是刻意的：编译容器要下公网依赖，而项目的 Makefile 不传代理，只能靠
   Docker CLI 注入。
2. Docker CLI 把代理注入**它创建的每一个容器** —— 包括 compose 起的服务。实测
   `docker exec minio env` 里就有 `HTTP_PROXY=...`，`NO_PROXY` 只有那三项。
3. `minio-init` 执行 `mc alias set local http://minio:9000 ...`。mc 是 Go 写的，
   尊重 `HTTP_PROXY`；主机名 `minio` 不在 noProxy 里，于是请求发给代理。
4. 代理从没听说过 `minio` 这台主机 → **502 Bad Gateway**。
5. mc 把 502 当成「凭据/别名不对」，**回落到默认的 localhost:9000**：
   `Put "http://localhost:9000/warehouse/": dial tcp [::1]:9000: connect: connection refused`
6. entrypoint 末尾有一句 `exit 0`，于是容器**以 0 退出**。整个栈的状态里
   没有任何一处显示出错。

一个「全绿」的环境，S3 上什么都没有。后面 polaris 建 catalog 必然失败，而报错会
指向 polaris 或 iceberg，离真因隔着五层。

**修法**：起服务之前，把这一组的服务名加进 noProxy。服务名恰好就是网络内使用的
主机名，而 compose 自己能列出来：

```bash
docker compose -f <每个文件> config --services   # → hadoop,hive-metastore,minio,polaris,…
jq '.proxies.default.noProxy = $np' /root/.docker/config.json
```

只有这些名字绕过代理，其余照旧走代理 —— 编译容器下载公网依赖不受影响。

实测修复后：`Bucket created successfully local/data`，`/data` 下 `data` 与
`warehouse` 都在。

**留给项目侧的两点**（工具层不该替它改）：

- `minio-init` 的 entrypoint 以 `exit 0` 收尾，任何失败都被吞掉。去掉它，
  或者显式检查每一步。
- `hiveserver2` 的 healthcheck 写成
  `test: ["CMD", "bash -c '...' || exit 1"]`。`CMD` 形式下数组每项是一个 argv，
  于是 docker 去 exec 一个名字叫 `bash -c '...' || exit 1` 的文件，
  报 `OCI runtime exec failed`，ExitCode 恒为 `-1`，探针**从未成功过一次** ——
  而端口 10000 一直是开的。应为 `CMD-SHELL`。
  wk 现在把这种情况单独归为 `broken-probe`，明确说是 compose 的定义问题，
  不再报成服务故障（否则读的人会去查 hive，而真因在 yaml 里）。

---

## 实施顺序建议

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | **§4 fake-lxc 测试** | 先有回归保护，后面几项改起来才安全 |
| 2 | §3 并发锁 | 防止半绑定这类难查的坏状态 |
| 3 | §5 操作日志 | 成本极低，出问题时价值最大 |
| 4 | §2 doctor 探测 + exec 重试 | 直接减少被代理打断的挫败感 |
| 5 | §6 缓存回收、§7 跨容器复制、§8 列宽 | 体验与容量，不紧急 |

先做 §4 是因为：这两天所有 wk 的 bug 都是在真机上才发现的，
没有回归保护的情况下继续改代码，等于每次都在赌。
