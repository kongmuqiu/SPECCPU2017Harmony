# HarmonyOS CPU 核心锁定机制分析文档

## 1. 背景与目标

SPECCPU2017 基准测试需要将工作进程锁定到指定 CPU 核心上运行，以消除核心迁移带来的缓存失效和性能波动，获得稳定可复现的测试结果。

HarmonyOS (鸿蒙) 系统基于 Linux 内核，但在调度器层面增加了 **hmmac (华为强制访问控制)** 安全模块和 **QoS 资源调度器**，这使得传统的 `sched_setaffinity()` 锁核方式面临额外约束。

---

## 2. 系统架构

### 2.1 涉及的内核机制

| 机制 | 作用 | 接口 |
|------|------|------|
| **sched_setaffinity** | 设置线程允许运行的 CPU 集合（per-task） | `sched_setaffinity(pid, size, mask)` |
| **cpuset cgroup** | cgroup 层面限制进程组可用的 CPU 集合 | `/dev/cpuset/top-app/cpus` |
| **QoS** | 鸿蒙 QoS 服务，影响调度优先级和 cpuset 扩展 | `OH_QoS_SetThreadQoS()` |
| **sched_setattr** | 设置调度策略和 util_clamp 参数 | `syscall(__NR_sched_setattr)` |
| **hmmac** | 鸿蒙强制访问控制，监控并限制 cpuset 越界行为 | 内核模块，无直接接口 |

### 2.2 约束关系

线程实际可运行的 CPU = `sched_setaffinity 掩码` ∩ `cpuset cgroup 允许集合`

```
┌─────────────────────────────────────────────────┐
│ 系统全部核心 (例: 0-13)                          │
│  ┌───────────────────────────────────┐           │
│  │ cpuset/top-app (例: 0-8)          │           │
│  │  ┌─────────────────────┐          │  ┌──────┐ │
│  │  │ sched_setaffinity   │          │  │ 超大核│ │
│  │  │ (用户设定的目标核心)   │          │  │12, 13│ │
│  │  └─────────────────────┘          │  └──────┘ │
│  └───────────────────────────────────┘           │
└─────────────────────────────────────────────────┘
```

### 2.3 已验证的 SOC 拓扑

**Kirin 9030P (14 核)**

| 核心编号 | 角色 | cpuset/top-app |
|----------|------|----------------|
| 0-3 | 小核 (LITTLE) | 在集合内 |
| 4-11 | 大核 (big) | 0-8 在集合内, 9-11 不确定 |
| 12-13 | 超大核 (X) | 不在集合内 |

**其他 SOC (如 Kirin 9010 等 12 核)**

| 核心编号 | 角色 | cpuset/top-app |
|----------|------|----------------|
| 0-3 | 小核 | 在集合内 |
| 4-9 | 大核 | 在集合内 |
| 10-11 | 超大核 | 不在集合内 |

---

## 3. 核心发现

### 3.1 cpuset 边界限制

系统 cpuset cgroup (`/cpuset/top-app`) 限定前台应用可使用的核心范围。在 9030P 上通常为 `{0-8}`，超大核 12/13 不在此范围内。

**关键发现**：`sched_setaffinity()` 对 cpuset 外的核心调用不会返回错误（`ret=0`），但 hmmac 会**静默报复**：

```
操作: sched_setaffinity({9})    // 核心 9 不在 cpuset{0-8} 中
返回: ret=0, errno=0            // 看似成功
实际: cpuset 从 9 核缩减到 1 核   // hmmac 惩罚性收缩！
恢复: sched_setaffinity({0-127}) // 可恢复到 {0-8}
```

### 3.2 hmmac 行为模型

```
用户调用 sched_setaffinity(target)
  │
  ├── target ∈ cpuset → 正常执行，线程锁定到 target
  │
  └── target ∉ cpuset → hmmac 介入
        │
        ├── 返回值仍为 0 (不报错!)
        ├── 实际 affinity 被设为 cpuset 中某个核心
        ├── 整个 cpuset 可能被收缩 (9核→1核)
        └── 若紧接着 "reset-to-all"(sched_setaffinity({0-127}))
            → 进一步触发级联限制，可能永久收缩
```

### 3.3 QoS 旁路机制

`OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE)` 配合 `util_clamp=1024` 可以让调度器将线程调度到 cpuset 之外的超大核上：

- `sched_getcpu()` 可以返回 12 或 13，即使 `sched_getaffinity()` 显示 `{0-8}`
- 这是一种内核层面的调度器旁路，QoS 服务通过 IPC (Binder) 与资源调度器通信
- 此旁路仅在父线程中有效，**fork() 后子进程的 IPC 连接断开**

### 3.4 实测锁定能力总结 (9030P)

| 核心 | sched_setaffinity | QoS 软模式 | 最终方案 |
|------|-------------------|-----------|---------|
| 0-8 | 直接锁定成功 | 不需要 | **硬模式** |
| 9-11 | 直接锁定成功 (测试验证) | 不需要 | **硬模式** |
| 12-13 | 触发 hmmac 惩罚 | QoS 可引导到达 | **软模式** |

---

## 4. 动态锁核策略 (当前实现)

### 4.1 策略决策流程

```
用户选择目标核心 N
        │
        ▼
  ┌──────────────┐
  │读取 cpuset    │ sched_getaffinity()
  │(当前可用核心) │
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │读取频率信息   │ /sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_max_freq
  │判断超大核簇   │ 回退: /sys/devices/system/cpu/cpuN/cpu_capacity
  └──────┬───────┘
         │
    ┌────┴────────────────┐
    │                     │
    ▼                     ▼
 N ∈ cpuset?          N ∉ cpuset?
    │                     │
    ▼                ┌────┴────┐
 硬模式              │         │
                     ▼         ▼
               是超大核?    否(中间核)
                     │         │
                     ▼         ▼
                  软模式     硬模式
```

### 4.2 硬模式 (HARD MODE)

**适用场景**：目标核心在 cpuset 内，或虽不在 cpuset 但不是最高频率簇。

**实现**：
```
父线程:
  1. sched_setaffinity({target}) — 直接设置亲和性
  2. OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE) — 提升调度优先级
  3. sched_setattr(util_clamp=1024) — 请求最大性能
  4. 再次 sched_setaffinity({target}) — sched_setattr 后重新确认
  5. fork() 创建子进程

子进程:
  1. sched_setaffinity({target}) — 继承并重新设定
  2. 读回 affinity 验证
  3. 若失败: 重试 20 次 (递增延迟 5ms→200ms)

看门狗 (10ms SIGALRM):
  1. sched_setaffinity({target}) — 持续重申
  2. sched_setattr(util_clamp=1024) — 维持性能需求
  3. 检测漂移并记录统计
```

### 4.3 软模式 (SOFT MODE)

**适用场景**：目标核心不在 cpuset 内，且属于最高频率簇（超大核）。

**核心原则**：**绝不调用 `sched_setaffinity()`**，完全依赖 QoS + util_clamp 引导调度器。

**实现**：
```
父线程:
  1. 不调用 sched_setaffinity (避免 hmmac)
  2. OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE) — 主要锁核机制
  3. sched_setattr(util_clamp=1024) — 辅助性能信号
  4. fork() 创建子进程

子进程 (两阶段):
  阶段一: QoS cpuset 扩展等待 (5×100ms = 500ms)
    - 反复检查 sched_getaffinity() 是否包含目标核心
    - 若 QoS 扩展了 cpuset 使目标核心可达 → 升级为硬模式

  阶段二: 机会性锁定轮询 (~3.2s)
    - 10ms×20 + 50ms×20 + 100ms×20
    - 每次检查 sched_getcpu():
      a) 若目标核心已进入 cpuset → 直接 sched_setaffinity 硬锁定
      b) 若 sched_getcpu()==target (QoS 旁路到达) → 尝试确认锁定
         成功 → 转为硬模式
         失败 → 不执行 reset-to-all, 继续轮询

看门狗 (10ms SIGALRM):
  1. 只重申 sched_setattr(util_clamp=1024) — 不碰 sched_setaffinity
  2. 每 100 次 (~1s): 检查 cpuset 是否扩展, 若是 → 升级硬模式
  3. 当 sched_getcpu()==target: 尝试机会性锁定
  4. 失败时不 reset-to-all — 避免 hmmac 级联限制

保活线程 (父进程, 100ms 循环):
  1. 持续重申 QoS + util_clamp — 防止资源调度器收缩 cpuset
  2. 前 300ms: 尝试扩展 cpuset (写 cpuset.cpus, 迁移到 root cpuset)
  3. CPU 脉冲负载 (~2ms/100ms) — 维持调度器对高性能需求的判断
  4. 不调用 sched_setaffinity (软模式下)
```

---

## 5. 超大核检测算法

```cpp
// 运行时检测: 读取所有核心的最大频率
for each cpu in /sys/devices/system/cpu/cpu{N}/:
    freq = read(cpufreq/cpuinfo_max_freq)
    if unavailable: freq = read(cpu_capacity)

max_freq = max(all_freqs)
top_cluster = {cpu | cpu.freq == max_freq}

// 判断目标核心是否属于超大核簇
is_top = (target ∈ top_cluster)
```

示例输出:
```
[PIN] FREQ DETECT: target=12 max_freq=3500000 top_cluster={12,13} is_top=1
[PIN] SOFT MODE: core 12 NOT in cpuset={0,1,2,3,4,5,6,7,8}, is top-freq cluster
```

```
[PIN] FREQ DETECT: target=9 max_freq=3500000 top_cluster={12,13} is_top=0
[PIN] HARD MODE: core 9 in cpuset={0,1,2,3,4,5,6,7,8,9}, direct affinity
```

---

## 6. 关键安全规则

### 6.1 绝对禁止

| 操作 | 后果 |
|------|------|
| 对 cpuset 外超大核调用 `sched_setaffinity` | hmmac 收缩 cpuset (9核→1核) |
| 锁定失败后 reset-to-all | 触发 hmmac 级联限制，可能永久收缩 |
| fork() 后在子进程中发起 QoS IPC | IPC 连接已断开，调用无效 |

### 6.2 必须遵守

| 规则 | 原因 |
|------|------|
| QoS 必须在父线程设置 | QoS 通过 Binder IPC 通信，fork 后无效 |
| 保活线程必须持续重申 QoS | 防止资源调度器在基准测试期间回收 cpuset |
| 软模式下看门狗只用 sched_setattr | 避免触发 hmmac |
| 频率检测必须在锁核前完成 | 动态策略依赖频率簇分类 |

---

## 7. 诊断系统

### 7.1 PinDiag 函数

通过 NAPI 暴露的诊断接口，报告以下信息:

- 当前 PID/TID 和运行核心
- cpuset cgroup 路径和允许的 CPU 集合
- cgroup 完整成员关系
- 内核 Cpus_allowed 掩码
- 调度策略
- `sched_setaffinity` 直接测试结果 (含 hmmac 收缩检测)
- `sched_setattr` (FIFO / util_clamp) 可用性测试
- cpuset 文件路径探测

### 7.2 运行时日志标签

| 标签 | 含义 |
|------|------|
| `[PIN] HARD MODE` | 使用直接 sched_setaffinity |
| `[PIN] SOFT MODE` | 使用 QoS + util_clamp 引导 |
| `[PIN] FREQ DETECT` | 超大核频率检测结果 |
| `[PIN] OPPORTUNISTIC LOCK` | 软模式下成功确认锁定 |
| `[PIN] OPPORTUNISTIC MISS` | 软模式下确认锁定失败 |
| `[PIN-DIAG] DRIFT` | 检测到核心漂移 |
| `[PIN-DIAG] WATCHDOG UPGRADE` | 看门狗检测到 cpuset 扩展，升级为硬模式 |
| `[PIN-KEEPALIVE]` | 保活线程状态 |

### 7.3 看门狗统计

每 10000 次触发 (~100 秒) 输出一次统计:
```
[PIN-DIAG] watchdog: fires=10000 drift=42 cpu=12 target=12 soft=0
```

- `fires`: 总触发次数
- `drift`: 漂移次数 (运行在非目标核心的次数)
- `cpu`: 当前核心
- `target`: 目标核心
- `soft`: 当前是否处于软模式 (0=已升级为硬模式)

---

## 8. 代码结构

### 文件: `entry/src/main/cpp/napi_init.cpp`

| 函数/结构 | 行号区间 | 职责 |
|-----------|---------|------|
| `is_top_freq_core()` | 114-171 | 运行时检测超大核簇 |
| `resolve_cpuset_cpus()` | 229-283 | 多路径解析 cpuset 允许的 CPU |
| `log_pinning_diagnostics()` | 288-353 | 输出完整锁核诊断信息 |
| `try_expand_cpuset()` | 358-447 | 尝试扩展 cpuset (写文件/迁移 cgroup) |
| `affinity_signal_handler()` | 470-568 | SIGALRM 看门狗 (软/硬模式分支) |
| `PinKeepalive` / `pin_keepalive_fn()` | 639-724 | 保活线程 (维持 QoS + util_clamp) |
| `Run()` | 735-~1260 | 主入口: 策略决策 → fork → 子进程锁核 |
| `PinDiag()` | 1497-1698 | 诊断信息收集 (NAPI 接口) |
| `GetEffectiveCpuset()` | 1702-1719 | 返回当前有效 cpuset (JS 数组) |

### 执行时序

```
UI 选择核心 N → Run(core=N) 调用
  │
  ├── 1. build_single_core_cpuset(N)       构建目标 CPU 掩码
  ├── 2. sched_getaffinity() + is_top_freq_core()   策略决策
  ├── 3. [硬模式] sched_setaffinity({N}) 或 [软模式] 跳过
  ├── 4. OH_QoS_SetThreadQoS(USER_INTERACTIVE)     设置 QoS
  ├── 5. sched_setattr(util_clamp=1024)              最大性能
  ├── 6. pthread_create(pin_keepalive_fn)             启动保活
  ├── 7. fork()
  │     │
  │     ├── 子进程:
  │     │   ├── 设置 SCHED_FIFO/util_clamp
  │     │   ├── [硬模式] sched_setaffinity + 重试
  │     │   │   或 [软模式] 两阶段等待 + 机会性锁定
  │     │   ├── 启动 SIGALRM 看门狗 (10ms)
  │     │   ├── log_pinning_diagnostics()
  │     │   └── switch_stack() → 运行 benchmark
  │     │
  │     └── 父进程: waitpid() 等待子进程结束
  │
  └── 8. 清理: 停止保活线程, 重置 QoS
```

---

## 9. 已知限制

1. **QoS 引导不精确**: 软模式下 `util_clamp=1024` 引导调度器到最快核心，但无法指定具体哪个核心。例如目标是核心 12，可能被调度到核心 13。

2. **cpuset 扩展不可控**: QoS 是否会扩展 cpuset 取决于系统资源调度器的内部策略，应用层无法保证。

3. **hmmac 行为不透明**: hmmac 的收缩规则没有文档，仅通过实验观察推断。不同鸿蒙版本可能有不同行为。

4. **fork() 后 IPC 断开**: 子进程无法发起新的 QoS 请求，只能继承父进程的调度属性。

5. **频率信息依赖 sysfs**: 若 `cpufreq/cpuinfo_max_freq` 和 `cpu_capacity` 均不可读，将无法判断超大核，默认回退到硬模式。

---

## 10. 测试验证清单

| 测试项 | 方法 | 预期结果 |
|--------|------|---------|
| cpuset 内核心锁定 | 选择核心 0-8, 观察日志 | `[PIN] HARD MODE`, drift ≈ 0 |
| cpuset 边界核心锁定 | 选择核心 9-11 (9030P) | `[PIN] HARD MODE`, 直接锁定成功 |
| 超大核引导 | 选择核心 12 (9030P) | `[PIN] SOFT MODE`, QoS 引导到 12 或 13 |
| hmmac 不触发 | 软模式下观察 cpuset | cpuset 不收缩，保持 {0-8} 或更大 |
| 频率检测正确 | 观察 FREQ DETECT 日志 | top_cluster 正确匹配超大核 |
| 看门狗升级 | 软模式下等待 cpuset 扩展 | `WATCHDOG UPGRADE` 后 drift 降至 ≈0 |
| 其他 SOC 超大核 | 9010 选择核心 10/11 | `[PIN] SOFT MODE`, 不触发随机跳核 |
