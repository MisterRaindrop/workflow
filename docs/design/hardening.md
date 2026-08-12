# 稳定化方案

针对实战暴露的问题，逐条给出方案。按「会不会让它突然坏掉」排序。
后台守护（自动冻结 + 定期采样）**暂缓**，优先级不高。

> **状态（2026-08-12）：§1–§8 全部实现并通过真机验证。**
> 测试从 57 个断言扩到 107 个。详见
> [`.router/plans/feat-lxd-slot/DESIGN.md`](../../.router/plans/feat-lxd-slot/DESIGN.md) 的实施记录。

已解决的不在此列（见 [lxd-slot.md](lxd-slot.md) §11a / §4d）。

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
（`/mnt/.../umbrella` 这种形式），保留头尾这两段最有辨识度的信息。

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
