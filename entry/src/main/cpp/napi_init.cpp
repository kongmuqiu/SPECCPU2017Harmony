#include "napi/native_api.h"
#include <assert.h>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <sched.h>
#include <signal.h>
#include <string>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <errno.h>
#include <fcntl.h>
#include <vector>
#include <fstream>
#include <sstream>
#include <set>
#include <map>

#include "hilog/log.h"
#include "hitrace/trace.h"
#include "qos/qos.h"
#undef LOG_TAG
#define LOG_TAG "mainTag"

// ---------- Aggressive CPU pinning via sched_setattr ----------
// sched_setattr syscall numbers (aarch64 = 274, x86_64 = 314)
#ifndef __NR_sched_setattr
#ifdef __aarch64__
#define __NR_sched_setattr 274
#else
#define __NR_sched_setattr 314
#endif
#endif

// Scheduling flags from <linux/sched.h>
#ifndef SCHED_FLAG_UTIL_CLAMP_MIN
#define SCHED_FLAG_UTIL_CLAMP_MIN 0x20
#endif
#ifndef SCHED_FLAG_UTIL_CLAMP_MAX
#define SCHED_FLAG_UTIL_CLAMP_MAX 0x40
#endif

// SCHED_NORMAL is in <linux/sched.h>, not always in POSIX <sched.h>
#ifndef SCHED_NORMAL
#define SCHED_NORMAL 0
#endif

// struct sched_attr compatible with kernel UAPI (linux/sched/types.h)
struct bench_sched_attr {
  uint32_t size;
  uint32_t sched_policy;
  uint64_t sched_flags;
  int32_t  sched_nice;
  uint32_t sched_priority;
  uint64_t sched_runtime;
  uint64_t sched_deadline;
  uint64_t sched_period;
  uint32_t sched_util_min;
  uint32_t sched_util_max;
};

// ---------- FFRT dlopen compatible types ----------
// Match structs in ffrt/type_def.h and ffrt/task.h for dlopen usage.
typedef void (*dyn_ffrt_func_t)(void*);
struct dyn_ffrt_func_header {
    dyn_ffrt_func_t exec;
    dyn_ffrt_func_t destroy;
    uint64_t reserve[2];
};

// FFRT function pointer types for dlsym
typedef int   (*pfn_ffrt_task_attr_init)(void*);
typedef void  (*pfn_ffrt_task_attr_set_qos)(void*, int);
typedef void  (*pfn_ffrt_task_attr_set_name)(void*, const char*);
typedef void  (*pfn_ffrt_task_attr_destroy)(void*);
typedef void* (*pfn_ffrt_alloc_auto_managed_function_storage_base)(int);
typedef void  (*pfn_ffrt_submit_base)(void*, const void*, const void*, const void*);
typedef void  (*pfn_ffrt_wait)(void);

extern "C" void switch_stack(int argc, const char **argv, const char **envp,
                             int (*callee)(int argc, const char **argv,
                                           const char **envp),
                             void *sp);

// ---------- Utility: read a single line from procfs/sysfs ----------
static std::string read_file_line(const std::string &path) {
  std::ifstream f(path);
  std::string line;
  if (f.is_open()) std::getline(f, line);
  // trim trailing whitespace
  while (!line.empty() && (line.back() == '\n' || line.back() == '\r' || line.back() == ' '))
    line.pop_back();
  return line;
}

// ---------- Utility: format a cpu_set_t as human-readable string ----------
static std::string cpuset_to_string(const cpu_set_t &cs) {
  std::string s;
  for (int i = 0; i < CPU_SETSIZE; i++) {
    if (CPU_ISSET(i, &cs)) {
      if (!s.empty()) s += ",";
      s += std::to_string(i);
    }
  }
  return s.empty() ? "(empty)" : s;
}

// ---------- Utility: detect if a core belongs to the top-frequency cluster ----------
// Reads cpufreq/cpuinfo_max_freq (or cpu_capacity) for all online cores,
// finds the maximum frequency group, and checks if the target core is in it.
// Returns true if the target core is in the highest-frequency cluster.
static bool is_top_freq_core(int target_core) {
  // Collect max freq for each core
  struct CoreFreq { int id; long freq; };
  std::vector<CoreFreq> cores;
  int consecutive_missing = 0;
  for (int i = 0; i < CPU_SETSIZE; i++) {
    std::string path = "/sys/devices/system/cpu/cpu" + std::to_string(i)
                     + "/cpufreq/cpuinfo_max_freq";
    std::ifstream f(path);
    long freq = -1;
    if (f.is_open()) {
      f >> freq;
    }
    if (freq <= 0) {
      // Fallback: try cpu_capacity (normalized 0-1024, higher = faster)
      std::string cap_path = "/sys/devices/system/cpu/cpu" + std::to_string(i)
                           + "/cpu_capacity";
      std::ifstream cf(cap_path);
      if (cf.is_open()) cf >> freq;
    }
    if (freq <= 0) {
      if (++consecutive_missing > 16) break;
      continue;
    }
    consecutive_missing = 0;
    cores.push_back({i, freq});
  }

  if (cores.empty()) return false;

  // Find the maximum frequency
  long max_freq = 0;
  for (auto &c : cores) {
    if (c.freq > max_freq) max_freq = c.freq;
  }

  // Collect all cores at max frequency (the top cluster)
  std::set<int> top_cluster;
  for (auto &c : cores) {
    if (c.freq == max_freq) top_cluster.insert(c.id);
  }

  bool result = top_cluster.count(target_core) > 0;
  dprintf(2, "[PIN] FREQ DETECT: target=%d max_freq=%ld top_cluster={",
          target_core, max_freq);
  bool first = true;
  for (int id : top_cluster) {
    if (!first) dprintf(2, ",");
    dprintf(2, "%d", id);
    first = false;
  }
  dprintf(2, "} is_top=%d\n", result ? 1 : 0);
  return result;
}

// ---------- Utility: resolve cpuset allowed CPUs from multiple path patterns ----------
// HongMeng Kernel returns '/cpuset/top-app' from /proc/self/cpuset, which means
// the actual filesystem path could be:
//   /dev/cpuset/cpuset/top-app/cpus          (cgroup v1 nested)
//   /dev/cpuset/top-app/cpus                 (cgroup v1 flat)
// ---------- Utility: find cpuset mount point from /proc/mounts ----------
// Returns empty if not found. Also populates all_cgroup_mounts for diagnostics.
static std::string find_cpuset_mount(std::string *all_cgroup_mounts = nullptr) {
  std::ifstream f("/proc/mounts");
  std::string line;
  std::string result;
  while (std::getline(f, line)) {
    std::istringstream iss(line);
    std::string dev, mnt, fstype, opts;
    if (iss >> dev >> mnt >> fstype >> opts) {
      // Collect all cgroup-related mounts for diagnostics
      if (fstype.find("cgroup") != std::string::npos ||
          mnt.find("cpuset") != std::string::npos) {
        if (all_cgroup_mounts) {
          *all_cgroup_mounts += "  " + line + "\n";
        }
      }
      if (fstype == "cpuset") { result = mnt; }
      else if (fstype == "cgroup" && opts.find("cpuset") != std::string::npos) { result = mnt; }
      else if (fstype == "cgroup2" && result.empty()) {
        // cgroup v2 unified — cpuset is a controller within it
        // Check if this mount has cpuset.cpus files
        if (all_cgroup_mounts) ; // just collect
      }
    }
  }
  return result;
}

// ---------- Utility: get real cpuset cgroup path from /proc/self/cgroup ----------
static std::string get_cpuset_cgroup_path() {
  std::ifstream f("/proc/self/cgroup");
  std::string line;
  while (std::getline(f, line)) {
    // format: hierarchy-ID:controller-list:cgroup-path
    // e.g. "3:cpuset:/top-app"
    size_t p1 = line.find(':');
    if (p1 == std::string::npos) continue;
    size_t p2 = line.find(':', p1 + 1);
    if (p2 == std::string::npos) continue;
    std::string controllers = line.substr(p1 + 1, p2 - p1 - 1);
    if (controllers == "cpuset") {
      return line.substr(p2 + 1);  // e.g. "/top-app"
    }
  }
  return "";
}

//   /sys/fs/cgroup/cpuset/top-app/cpus       (cgroup v1 alt mount)
//   /sys/fs/cgroup/cpuset/top-app/cpuset.cpus.effective  (cgroup v2)
//   /sys/fs/cgroup/cpuset/top-app/cpuset.cpus            (cgroup v2)
static std::string resolve_cpuset_cpus(const std::string &cgroup_path) {
  // Build candidate paths using multiple strategies
  std::vector<std::string> candidates;

  // Strategy 0 (HIGHEST PRIORITY): HongMeng direct-mount files
  // HongMeng mounts cpuset control files as individual cgroup mounts
  candidates.push_back("/dev/cpuset/cpuset.cpus");

  if (cgroup_path.empty()) {
    for (auto &p : candidates) {
      std::string val = read_file_line(p);
      if (!val.empty()) return val + " (from " + p + ")";
    }
    return "";
  }

  // First: get real cpuset cgroup path from /proc/self/cgroup (more reliable)
  std::string real_cg = get_cpuset_cgroup_path();
  // Also: find actual cpuset mount point from /proc/mounts
  std::string mount = find_cpuset_mount();

  // Strategy 1: use discovered mount point + real cgroup path
  if (!mount.empty() && !real_cg.empty()) {
    candidates.push_back(mount + real_cg + "/cpus");
    candidates.push_back(mount + real_cg + "/cpuset.cpus.effective");
    candidates.push_back(mount + real_cg + "/cpuset.cpus");
  }

  // Strategy 2: /sys/fs/cgroup + real cgroup path (cgroup v2 unified)
  if (!real_cg.empty()) {
    candidates.push_back("/sys/fs/cgroup" + real_cg + "/cpuset.cpus.effective");
    candidates.push_back("/sys/fs/cgroup" + real_cg + "/cpuset.cpus");
    candidates.push_back("/sys/fs/cgroup" + real_cg + "/cpus");
  }

  // Strategy 3: original /proc/self/cpuset path
  candidates.push_back("/dev/cpuset" + cgroup_path + "/cpus");
  candidates.push_back("/dev/cpuset" + cgroup_path + "/cpuset.cpus");

  // Strategy 4: strip leading /cpuset prefix
  std::string stripped = cgroup_path;
  if (stripped.compare(0, 7, "/cpuset") == 0) {
    stripped = stripped.substr(7);
  }
  if (stripped != cgroup_path) {
    candidates.push_back("/dev/cpuset" + stripped + "/cpus");
    candidates.push_back("/dev/cpuset" + stripped + "/cpuset.cpus");
  }

  for (auto &p : candidates) {
    std::string val = read_file_line(p);
    if (!val.empty()) return val + " (from " + p + ")";
  }
  return "";
}

// ---------- Diagnostics: dump all pinning-related state ----------
// Uses dprintf (async-signal-safe, writes to fd) because OH_LOG_* does NOT
// work in forked child processes (hilog connection is not inherited).
static void log_pinning_diagnostics(int target_core) {
  int fd = 2; // stderr

  int cur_cpu = sched_getcpu();
  dprintf(fd, "[PIN-DIAG] target=%d actual_cpu=%d pid=%d tid=%d\n",
          target_core, cur_cpu, (int)getpid(), (int)syscall(__NR_gettid));

  cpu_set_t eff;
  CPU_ZERO(&eff);
  if (sched_getaffinity(0, sizeof(eff), &eff) == 0) {
    std::string mask = cpuset_to_string(eff);
    dprintf(fd, "[PIN-DIAG] effective_affinity={%s}\n", mask.c_str());
  } else {
    dprintf(fd, "[PIN-DIAG] sched_getaffinity failed errno=%d\n", errno);
  }

  // cpuset cgroup path
  std::string cpuset_group = read_file_line("/proc/self/cpuset");
  dprintf(fd, "[PIN-DIAG] cpuset_group='%s'\n", cpuset_group.c_str());

  // Resolve cpuset allowed CPUs via multiple path patterns
  std::string allowed = resolve_cpuset_cpus(cpuset_group);
  if (!allowed.empty())
    dprintf(fd, "[PIN-DIAG] cpuset_allowed_cpus=%s\n", allowed.c_str());
  else
    dprintf(fd, "[PIN-DIAG] could not read cpuset/cpus from any path\n");

  // Full cgroup membership (all controllers)
  {
    std::ifstream f("/proc/self/cgroup");
    std::string line;
    while (std::getline(f, line)) {
      dprintf(fd, "[PIN-DIAG] cgroup: %s\n", line.c_str());
    }
  }

  // Cpus_allowed from kernel
  {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
      if (line.compare(0, 13, "Cpus_allowed:") == 0 ||
          line.compare(0, 18, "Cpus_allowed_list:") == 0) {
        dprintf(fd, "[PIN-DIAG] %s\n", line.c_str());
      }
    }
  }

  int policy = sched_getscheduler(0);
  const char *policy_name = "UNKNOWN";
  switch (policy) {
    case SCHED_OTHER: policy_name = "SCHED_OTHER/NORMAL"; break;
    case SCHED_FIFO: policy_name = "SCHED_FIFO"; break;
    case SCHED_RR: policy_name = "SCHED_RR"; break;
#ifdef SCHED_BATCH
    case SCHED_BATCH: policy_name = "SCHED_BATCH"; break;
#endif
#ifdef SCHED_IDLE
    case SCHED_IDLE: policy_name = "SCHED_IDLE"; break;
#endif
#ifdef SCHED_DEADLINE
    case SCHED_DEADLINE: policy_name = "SCHED_DEADLINE"; break;
#endif
  }
  dprintf(fd, "[PIN-DIAG] sched_policy=%d (%s)\n", policy, policy_name);
}

// ---------- Try to expand cpuset to allow all CPUs ----------
// HongMeng mounts /dev/cpuset/cpuset.cpus as a direct file (rw).
// Writing "0-13" (or "0-127") to it should expand the allowed CPU set.
static void try_expand_cpuset() {
  // ---- Strategy 1: Write to cpuset.cpus files (all known paths) ----
  // Try both root cpuset and top-app group-specific paths.
  // HongMeng mounts individual cpuset files as separate cgroup mounts;
  // the top-app subdirectory may or may not be accessible as a directory.
  static const char *cpus_paths[] = {
    // HongMeng direct-mount files (root cpuset)
    "/dev/cpuset/cpuset.cpus",
    "/dev/cpuset/cpus",
    // HongMeng top-app group (if directory accessible)
    "/dev/cpuset/top-app/cpuset.cpus",
    "/dev/cpuset/top-app/cpus",
    // Standard cgroup v1 layout
    "/sys/fs/cgroup/cpuset/cpuset.cpus",
    "/sys/fs/cgroup/cpuset/top-app/cpuset.cpus",
    "/sys/fs/cgroup/cpuset/top-app/cpus",
    // cgroup v2 unified layout
    "/sys/fs/cgroup/top-app/cpuset.cpus",
  };
  const char *expand_val = "0-127";
  for (auto path : cpus_paths) {
    // Read current value for diagnostics
    std::string cur = read_file_line(path);
    if (!cur.empty()) {
      dprintf(2, "[PIN-DIAG] cpuset.cpus current='%s' (from %s)\n", cur.c_str(), path);
    }
    // Try raw open/write (more reliable for cgroup pseudo-files than C++ streams)
    int fd = open(path, O_WRONLY);
    if (fd >= 0) {
      ssize_t n = write(fd, expand_val, strlen(expand_val));
      close(fd);
      if (n > 0) {
        std::string after = read_file_line(path);
        dprintf(2, "[PIN-DIAG] expanded cpuset.cpus via %s (now='%s')\n", path, after.c_str());
        return;
      } else {
        dprintf(2, "[PIN-DIAG] write to %s returned %zd errno=%d\n", path, n, errno);
      }
    }
    // Fallback: try C++ stream
    if (!cur.empty() || access(path, F_OK) == 0) {
      std::ofstream f(path);
      if (f.is_open()) {
        f << expand_val;
        f.flush();
        if (f.good()) {
          std::string after = read_file_line(path);
          dprintf(2, "[PIN-DIAG] expanded cpuset.cpus via %s (stream, now='%s')\n", path, after.c_str());
          return;
        }
      }
    }
  }

  // ---- Strategy 2: cpuctl boost (may trigger scheduler to expand available cores) ----
  static const char *boost_paths[] = {
    "/dev/cpuctl/cpu.boost",
    "/dev/cpuctl/top-app/cpu.boost",
  };
  for (auto path : boost_paths) {
    int fd = open(path, O_WRONLY);
    if (fd >= 0) {
      ssize_t n = write(fd, "1", 1);
      close(fd);
      if (n > 0) {
        dprintf(2, "[PIN-DIAG] wrote cpu.boost=1 via %s\n", path);
      }
    }
  }

  // ---- Strategy 3: Migrate to root cpuset ----
  static const char *migrate_paths[] = {
    "/dev/cpuset/cgroup.procs",
    "/dev/cpuset/tasks",
  };
  char pid_buf[16];
  int pid_len = snprintf(pid_buf, sizeof(pid_buf), "%d", (int)getpid());
  for (auto path : migrate_paths) {
    int fd = open(path, O_WRONLY);
    if (fd >= 0) {
      ssize_t n = write(fd, pid_buf, pid_len);
      close(fd);
      if (n > 0) {
        dprintf(2, "[PIN-DIAG] migrated to root cpuset via %s\n", path);
        return;
      }
    }
  }

  dprintf(2, "[PIN-DIAG] cpuset expansion: all methods failed (hmmac blocks writes)\n");
}

// ---------- Signal-based affinity watchdog ----------
// SIGALRM handler re-asserts CPU affinity (and optionally sched_attr)
// periodically in the benchmark child process.
// All functions used here (sched_setaffinity, syscall, sched_getcpu) are
// async-signal-safe (pure syscalls via vDSO or libc thin wrappers).
static cpu_set_t g_watchdog_cpuset;
static struct bench_sched_attr g_watchdog_sched_attr;
static volatile bool g_watchdog_use_sched_attr = false;
// Soft mode: when target core is outside cpuset, do NOT call sched_setaffinity
// (which triggers hmmac cpuset re-check and constrains us). Instead, only
// re-assert sched_setattr with util_clamp to maintain performance demand.
static volatile bool g_watchdog_soft_mode = false;
// Drift tracking: count how many times the process was found on a wrong CPU
static volatile int g_watchdog_target_cpu = -1;
static volatile sig_atomic_t g_watchdog_drift_count = 0;
static volatile sig_atomic_t g_watchdog_fire_count = 0;

// Global child PID for cancellation support
static volatile pid_t g_benchmark_child_pid = 0;

static void affinity_signal_handler(int) {
  g_watchdog_fire_count++;

  // Periodic stats (every 10000 fires = ~100s) — atexit won't fire since
  // switch_stack uses _exit, so this is our only way to log watchdog state.
  if (g_watchdog_fire_count % 10000 == 0) {
    dprintf(2, "[PIN-DIAG] watchdog: fires=%d drift=%d cpu=%d target=%d soft=%d\n",
            (int)g_watchdog_fire_count, (int)g_watchdog_drift_count,
            sched_getcpu(), (int)g_watchdog_target_cpu, (int)g_watchdog_soft_mode);
  }

  // In soft mode: do NOT call sched_setaffinity (it triggers hmmac cpuset
  // re-check which constrains us to {4-8}). Only re-assert sched_setattr
  // with util_clamp=1024 to keep the scheduler treating us as high-priority.
  if (g_watchdog_soft_mode) {
    if (g_watchdog_use_sched_attr) {
      syscall(__NR_sched_setattr, 0, &g_watchdog_sched_attr, 0);
    }

    int cur = sched_getcpu();

    // Strategy 1: Check if cpuset has expanded to include target core.
    // On 14-core SOCs (Kirin 9030P), QoS may expand cpuset to include
    // cores 10-13 even though util_clamp=1024 steers scheduler to 12/13.
    // If target core is now in cpuset, hard-pin directly — no need to
    // wait for scheduler to "land" on it via opportunistic polling.
    // Check every 100 fires (~1s) to limit overhead in signal handler.
    if (g_watchdog_fire_count % 100 == 50) {
      cpu_set_t wd_eff;
      CPU_ZERO(&wd_eff);
      sched_getaffinity(0, sizeof(wd_eff), &wd_eff);
      if (CPU_ISSET(g_watchdog_target_cpu, &wd_eff)) {
        sched_setaffinity(0, sizeof(g_watchdog_cpuset), &g_watchdog_cpuset);
        int after = sched_getcpu();
        cpu_set_t wd_verify;
        CPU_ZERO(&wd_verify);
        sched_getaffinity(0, sizeof(wd_verify), &wd_verify);
        if (CPU_ISSET(g_watchdog_target_cpu, &wd_verify)) {
          g_watchdog_soft_mode = false;
          dprintf(2, "[PIN-DIAG] WATCHDOG UPGRADE: cpuset expanded, hard-pinned to core %d at fire %d\n",
                  (int)g_watchdog_target_cpu, (int)g_watchdog_fire_count);
          return;
        }
      }
    }

    // Strategy 2: Opportunistic hard pin when on target core.
    // Try sched_setaffinity to "confirm current position" — works when
    // scheduler placed us here via QoS bypass. CRITICAL: on failure,
    // do NOT reset-to-all (that triggers hmmac cascading restriction).
    if (cur == g_watchdog_target_cpu) {
      // First check if cpuset already includes target (best case)
      cpu_set_t wd_cs;
      CPU_ZERO(&wd_cs);
      sched_getaffinity(0, sizeof(wd_cs), &wd_cs);
      bool cs_confirmed = CPU_ISSET(g_watchdog_target_cpu, &wd_cs) != 0;

      sched_setaffinity(0, sizeof(g_watchdog_cpuset), &g_watchdog_cpuset);
      int after = sched_getcpu();
      if (after == g_watchdog_target_cpu) {
        g_watchdog_soft_mode = false;
        dprintf(2, "[PIN-DIAG] OPPORTUNISTIC LOCK: core %d at fire %d (cpuset=%s)\n",
                (int)g_watchdog_target_cpu, (int)g_watchdog_fire_count,
                cs_confirmed ? "yes" : "qos-bypass");
      }
      // On failure: do NOT reset to all — just continue soft mode
    }

    // Track drift for diagnostics
    if (g_watchdog_target_cpu >= 0) {
      if (cur != g_watchdog_target_cpu) {
        g_watchdog_drift_count++;
        if (g_watchdog_drift_count == 1 || g_watchdog_drift_count % 1000 == 0) {
          dprintf(2, "[PIN-DIAG] DRIFT(soft) #%d: on cpu %d, target %d, fires=%d\n",
                  (int)g_watchdog_drift_count, cur,
                  (int)g_watchdog_target_cpu, (int)g_watchdog_fire_count);
        }
      }
    }
    return;
  }

  // Hard mode: normal watchdog with sched_setaffinity re-assertion
  if (g_watchdog_target_cpu >= 0) {
    int cur = sched_getcpu();
    if (cur != g_watchdog_target_cpu) {
      g_watchdog_drift_count++;
      if (g_watchdog_drift_count == 1 || g_watchdog_drift_count % 100 == 0) {
        dprintf(2, "[PIN-DIAG] DRIFT #%d: on cpu %d, target %d, fires=%d\n",
                (int)g_watchdog_drift_count, cur,
                (int)g_watchdog_target_cpu, (int)g_watchdog_fire_count);
      }
    }
  }
  sched_setaffinity(0, sizeof(g_watchdog_cpuset), &g_watchdog_cpuset);
  if (g_watchdog_use_sched_attr) {
    syscall(__NR_sched_setattr, 0, &g_watchdog_sched_attr, 0);
  }
}

static std::string get_str(napi_env env, napi_value value) {
  size_t size = 0;
  assert(napi_get_value_string_utf8(env, value, NULL, 0, &size) == napi_ok);
  std::vector<char> buffer(size + 1);

  assert(napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                    &size) == napi_ok);
  std::string s(buffer.data(), size);
  return s;
}

uint64_t get_time() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000 + (uint64_t)ts.tv_nsec;
}

// forward declarations (defined after parse_siblings_list)
static cpu_set_t build_single_core_cpuset(int core);
static cpu_set_t build_physical_core_cpuset(int core);

// measure clock frequency
// parameter
// 1: core index
static napi_value Clock(napi_env env, napi_callback_info info) {
  // get args
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  // set cpu affinity (pin to physical core including SMT siblings)
  int core;
  napi_get_value_int32(env, args[0], &core);
  cpu_set_t cpuset = build_physical_core_cpuset(core);
  if (sched_setaffinity(0, sizeof(cpuset), &cpuset) != 0) {
    OH_LOG_WARN(LOG_APP, "sched_setaffinity failed for core %{public}d: %{public}s", core, strerror(errno));
  }
  OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
  OH_LOG_INFO(LOG_APP, "Pin to cpu %{public}d with QoS USER_INTERACTIVE", core);

  OH_HiTrace_StartTrace("clock_frequency_measure");
  int n = 500000;
  uint64_t before = get_time();
  // learned from lmbench lat_mem_rd
#define FIVE(X) X X X X X
#define TEN(X) FIVE(X) FIVE(X)
#define FIFTY(X) TEN(X) TEN(X) TEN(X) TEN(X) TEN(X)
#define HUNDRED(X) FIFTY(X) FIFTY(X)
#define THOUSAND(X) HUNDRED(TEN(X))

  for (int i = 0; i < n; i++) {
    asm volatile(".align 4\n" THOUSAND("add x1, x1, x1\n") : : : "x1");
  }
  uint64_t after = get_time();

  double freq = (double)n * 1000 / (double)(after - before);
  OH_HiTrace_FinishTrace();
  OH_QoS_ResetThreadQoS();
  OH_LOG_INFO(LOG_APP, "Clock frequency is %{public}f", freq);
  napi_value ret;
  napi_create_double(env, freq, &ret);
  return ret;
}

// ---------- Keepalive thread ----------
// Maintains QoS_USER_INTERACTIVE + util_clamp=1024 in a separate thread
// to prevent the resource scheduler from shrinking cpuset during benchmark.
// AGGRESSIVE: re-asserts QoS every 100ms, tries cpuset expansion + child
// migration every ~1s, and shows sustained CPU demand to the scheduler.
struct PinKeepalive {
    volatile bool running;
    int target_core;
    volatile pid_t child_pid;  // set after fork(), 0 until then
    volatile bool soft_mode;   // true = don't use sched_setaffinity (hmmac blocks it)
};

static void* pin_keepalive_fn(void* arg) {
    auto* ka = (PinKeepalive*)arg;

    // Set highest QoS on this thread
    OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);

    // util_clamp=1024 to signal max performance need
    struct bench_sched_attr attr = {};
    attr.size = sizeof(attr);
    attr.sched_policy = SCHED_NORMAL;
    attr.sched_nice = -20;
    attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    attr.sched_util_min = 1024;
    attr.sched_util_max = 1024;
    syscall(__NR_sched_setattr, 0, &attr, 0);

    // Also request affinity to target core (reinforces demand signal)
    // In soft mode, skip sched_setaffinity — it triggers hmmac cpuset restriction
    cpu_set_t cs;
    CPU_ZERO(&cs);
    CPU_SET(ka->target_core, &cs);
    if (!ka->soft_mode) {
        sched_setaffinity(0, sizeof(cs), &cs);
    }

    cpu_set_t eff;
    CPU_ZERO(&eff);
    sched_getaffinity(0, sizeof(eff), &eff);
    dprintf(2, "[PIN-KEEPALIVE] started tid=%d target=%d affinity={%s}\n",
            (int)syscall(__NR_gettid), ka->target_core,
            cpuset_to_string(eff).c_str());

    int cycle = 0;
    while (ka->running) {
        // Re-assert QoS + util_clamp + affinity on EVERY cycle
        // (was every 5th cycle = every 2.5s, now every 100ms)
        OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
        syscall(__NR_sched_setattr, 0, &attr, 0);
        if (!ka->soft_mode) {
            sched_setaffinity(0, sizeof(cs), &cs);
        }

        // First 3 cycles (~300ms): try cpuset expansion. Stop after that
        // to avoid spamming logs when hmmac blocks all writes.
        if (cycle % 10 == 0 && cycle <= 30) {
            try_expand_cpuset();

            // Try migrating child process to root cpuset (less restricted)
            pid_t cpid = ka->child_pid;
            if (cpid > 0) {
                static const char *migrate_paths[] = {
                    "/dev/cpuset/cgroup.procs",
                    "/dev/cpuset/tasks",
                };
                char pid_buf[16];
                int pid_len = snprintf(pid_buf, sizeof(pid_buf), "%d", (int)cpid);
                for (auto path : migrate_paths) {
                    int fd = open(path, O_WRONLY);
                    if (fd >= 0) {
                        write(fd, pid_buf, pid_len);
                        close(fd);
                    }
                }
            }
        }

        // Heavier CPU burst to show sustained demand (~2ms every 100ms = 2% CPU)
        // Keeps the resource scheduler convinced that this is a real interactive task
        volatile int sink = 0;
        for (int j = 0; j < 500000; j++) sink = j;

        usleep(100000); // 100ms (was 500ms)
        cycle++;
    }

    OH_QoS_ResetThreadQoS();
    dprintf(2, "[PIN-KEEPALIVE] stopped after %d cycles\n", cycle);
    return nullptr;
}

// parameters:
// 0: cwd
// 1: path to stdin
// 2: path to stdout
// 3: path to stderr
// 4: benchmark name
// 5: benchmark args
// 6: core index
// 7: stdout unbuffered
static napi_value Run(napi_env env, napi_callback_info info) {
  // get args
  size_t argc = 8;
  napi_value args[8] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  // set cpu affinity — for Run() use single-CPU pin (strictest)
  int core;
  napi_get_value_int32(env, args[6], &core);
  cpu_set_t cpuset = build_single_core_cpuset(core);

  // === PARENT: Dynamic pinning strategy ===
  // The resource scheduler reacts to QoS/scheduling changes via IPC (Binder).
  // This MUST happen in the parent thread — IPC is broken after fork().
  //
  // STRATEGY:
  //   - Read current cpuset (sched_getaffinity) to check if target core is accessible
  //   - Read cpufreq to detect if target core is in the top-frequency cluster
  //   - If target IS in cpuset → HARD MODE: direct sched_setaffinity (works for 0-11)
  //   - If target NOT in cpuset AND is top-freq cluster → SOFT MODE: QoS + util_clamp
  //     (scheduler will guide to fastest cores; sched_setaffinity would trigger hmmac)
  //   - If target NOT in cpuset AND NOT top-freq → HARD MODE anyway: direct
  //     sched_setaffinity works since these mid-tier cores are reachable
  //
  cpu_set_t cur_eff;
  CPU_ZERO(&cur_eff);
  sched_getaffinity(0, sizeof(cur_eff), &cur_eff);
  bool in_cpuset = CPU_ISSET(core, &cur_eff) != 0;
  bool is_top_cluster = is_top_freq_core(core);

  bool soft_mode;
  if (in_cpuset) {
    // Core is in cpuset — safe to use direct sched_setaffinity
    soft_mode = false;
    sched_setaffinity(0, sizeof(cpuset), &cpuset);
    dprintf(2, "[PIN] HARD MODE: core %d in cpuset={%s}, direct affinity\n",
            core, cpuset_to_string(cur_eff).c_str());
  } else if (is_top_cluster) {
    // Core is outside cpuset AND is a top-freq core (super core) —
    // DO NOT call sched_setaffinity, it triggers hmmac.
    // Rely purely on QoS + util_clamp to reach these cores.
    soft_mode = true;
    dprintf(2, "[PIN] SOFT MODE: core %d NOT in cpuset={%s}, is top-freq cluster, "
               "using QoS only\n", core, cpuset_to_string(cur_eff).c_str());
  } else {
    // Core is outside cpuset but NOT a top-freq core — use direct affinity.
    // These mid-tier cores should be reachable via sched_setaffinity.
    soft_mode = false;
    sched_setaffinity(0, sizeof(cpuset), &cpuset);
    dprintf(2, "[PIN] HARD MODE: core %d NOT in cpuset={%s}, but not top-freq, "
               "direct affinity\n", core, cpuset_to_string(cur_eff).c_str());
  }

  // Set highest QoS — signal foreground interactive demand (via IPC)
  // In soft mode this is the PRIMARY mechanism: QoS_USER_INTERACTIVE tells
  // the resource scheduler to expand cpuset for the top-app group,
  // potentially adding the super cores (12/13).
  // In hard mode, QoS still helps with scheduling priority.
  OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);

  // Set sched_setattr with util_clamp=1024 — signal max performance need
  struct bench_sched_attr pre_attr = {};
  pre_attr.size = sizeof(pre_attr);
  pre_attr.sched_policy = SCHED_NORMAL;
  pre_attr.sched_priority = 0;
  pre_attr.sched_nice = -20;
  pre_attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
  pre_attr.sched_util_min = 1024;
  pre_attr.sched_util_max = 1024;
  syscall(__NR_sched_setattr, 0, &pre_attr, 0);

  // Re-assert affinity after sched_setattr (skip in soft mode — would trigger hmmac)
  if (!soft_mode) sched_setaffinity(0, sizeof(cpuset), &cpuset);
  OH_LOG_INFO(LOG_APP, "Pin to cpu %{public}d mode=%{public}s (in_cpuset=%{public}d top_freq=%{public}d)",
              core, soft_mode ? "SOFT" : "HARD", in_cpuset ? 1 : 0, is_top_cluster ? 1 : 0);

  // change workin directory
  std::string cwd = get_str(env, args[0]);
  OH_LOG_INFO(LOG_APP, "Change cwd to %{public}s", cwd.c_str());
  chdir(cwd.c_str());

  // https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-ndk-16-V5
  // redirect stdout/stderr to file
  std::string stdin_file = get_str(env, args[1]);
  std::string stdout_file = get_str(env, args[2]);
  std::string stderr_file = get_str(env, args[3]);
  if (stdin_file.size() > 0) {
    OH_LOG_INFO(LOG_APP, "Redirect stdin to %{public}s", stdin_file.c_str());
  }
  OH_LOG_INFO(LOG_APP, "Redirect stdout to %{public}s", stdout_file.c_str());
  OH_LOG_INFO(LOG_APP, "Redirect stderr to %{public}s", stderr_file.c_str());

  // load benchmark main from library
  int (*main)(int argc, const char **argv, const char **envp);
  std::string benchmark = get_str(env, args[4]);
  OH_LOG_INFO(LOG_APP, "Load benchmark %{public}s", benchmark.c_str());
  std::string library_name = "lib";
  library_name += benchmark;
  library_name += ".so";
  void *handle = dlopen(library_name.c_str(), RTLD_NOW);
  if (!handle) {
    OH_LOG_INFO(LOG_APP, "Failed to load benchmark %{public}s",
                benchmark.c_str());
    // missing shared library
    // return -1.0
    napi_value ret;
    napi_create_double(env, -1.0, &ret);
    return ret;
  }

  main = (int (*)(int argc, const char **argv, const char **envp))dlsym(handle,
                                                                        "main");

  if (!main) {
    OH_LOG_INFO(LOG_APP, "Failed to find main symbol in %{public}s",
                benchmark.c_str());
    dlclose(handle);
    napi_value ret;
    napi_create_double(env, -1.0, &ret);
    return ret;
  }

  // construct argv
  std::vector<std::string> argv;
  argv.push_back(benchmark);
  uint32_t args_length;
  napi_get_array_length(env, args[5], &args_length);
  for (uint32_t i = 0; i < args_length; i++) {
    napi_value element;
    napi_get_element(env, args[5], i, &element);

    std::string arg = get_str(env, element);
    argv.push_back(arg);
  }

  std::vector<const char *> real_argv;
  for (auto &arg : argv) {
    real_argv.push_back(arg.c_str());
  }
  real_argv.push_back(NULL);
  const char *envp[1] = {NULL};

  // emulate ulimit -s unlimited
  // All benchmarks get 1GB heap-allocated stack (matching reference implementation).
  // Fortran VLA arrays can be very large (e.g. 503.bwaves_r: ~820MB).
  // setrlimit not working on HarmonyOS, so create stack manually.
  uint8_t *stack = NULL;
  size_t size = 0x40000000; // 1GB for all benchmarks
  posix_memalign((void **)&stack, 0x1000, size);
  uint8_t *stack_top = stack + size;
  OH_LOG_INFO(LOG_APP, "Allocated stack at %{public}p-%{public}p", (void *)stack,
              (void *)stack_top);

  OH_LOG_INFO(LOG_APP, "Start benchmark %{public}s", benchmark.c_str());
  std::string trace_name = "benchmark_" + benchmark;
  OH_HiTrace_StartTrace(trace_name.c_str());

  // io redirection
  if (stdin_file.size() > 0) {
    freopen(stdin_file.c_str(), "r", stdin);
  }
  freopen(stdout_file.c_str(), "w+", stdout);
  freopen(stderr_file.c_str(), "w+", stderr);

  // Try to expand cpuset BEFORE fork — direct file writes may be blocked by
  // hmmac, but it's worth attempting (succeeds on some devices/versions).
  try_expand_cpuset();

  // Re-assert affinity after cpuset expansion attempt (skip in soft mode)
  if (!soft_mode) sched_setaffinity(0, sizeof(cpuset), &cpuset);

  // Pre-fork diagnostic: log worker thread's cpuset and affinity (written to stderr file)
  {
    cpu_set_t pre_eff;
    CPU_ZERO(&pre_eff);
    sched_getaffinity(0, sizeof(pre_eff), &pre_eff);
    std::string pre_mask = cpuset_to_string(pre_eff);
    std::string pre_cg = read_file_line("/proc/self/cpuset");
    std::string pre_cpus = resolve_cpuset_cpus(pre_cg);
    dprintf(2, "[PIN-PRE] worker_thread: cpu=%d affinity={%s} cpuset='%s' allowed=%s\n",
            sched_getcpu(), pre_mask.c_str(), pre_cg.c_str(), pre_cpus.c_str());
  }

  // === PARENT: Start keepalive thread & fork immediately ===
  // KEY INSIGHT from 副本5: QoS + affinity + immediate fork can reach core 13.
  // The 400ms polling delay was consuming the cpuset expansion window.
  // The keepalive thread maintains QoS demand to prevent cpuset shrinkage.
  PinKeepalive keepalive = {true, core, 0, soft_mode};
  pthread_t keepalive_tid = 0;
  pthread_create(&keepalive_tid, nullptr, pin_keepalive_fn, &keepalive);

  bool unbuffered = false;
  napi_get_value_bool(env, args[7], &unbuffered);
  if (unbuffered) {
    setvbuf(stdout, NULL, _IONBF, 0);
    OH_LOG_INFO(LOG_APP, "Stdout is unbuffered");
  }

  // use fork
  // 502.gcc_r does not free memory, leading to out of memory
  // large stack required for some benchmarks
  uint64_t before = get_time();
  uint64_t after;
  double res = -1;
  double time;
  pid_t pid = fork();
  if (pid == 0) {
    // Child inherits parent's QoS-expanded cpuset.
    // DO NOT call OH_QoS_ResetThreadQoS() here — IPC is broken after fork,
    // and resetting would undo the parent's expansion signal.
    // DO NOT call try_expand_cpuset() — direct file writes are blocked by
    // hmmac; the parent already triggered expansion via QoS + util_clamp.

    // === PHASE 3: Re-apply sched_setattr in child (direct syscall, no IPC) ===
    struct bench_sched_attr attr = {};
    attr.size = sizeof(attr);
    bool sched_attr_ok = false;

    // Try 1: SCHED_FIFO (RT) + util clamp (strongest)
    attr.sched_policy = SCHED_FIFO;
    attr.sched_priority = 1;
    attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    attr.sched_util_min = 1024;
    attr.sched_util_max = 1024;
    if (syscall(__NR_sched_setattr, 0, &attr, 0) == 0) {
      sched_attr_ok = true;
      dprintf(2, "[PIN] SCHED_FIFO + util_clamp OK\n");
    } else {
      int e1 = errno;
      // Try 2: SCHED_NORMAL + util clamp
      attr.sched_policy = SCHED_NORMAL;
      attr.sched_priority = 0;
      attr.sched_nice = -20;
      attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
      if (syscall(__NR_sched_setattr, 0, &attr, 0) == 0) {
        sched_attr_ok = true;
        dprintf(2, "[PIN] SCHED_NORMAL + util_clamp OK (FIFO errno=%d)\n", e1);
      } else {
        int e2 = errno;
        // Try 3: just SCHED_FIFO without util clamp
        struct sched_param sp = {};
        sp.sched_priority = 1;
        if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0) {
          dprintf(2, "[PIN] SCHED_FIFO only OK (clamp errno=%d)\n", e2);
        } else {
          dprintf(2, "[PIN] ALL sched methods FAILED (FIFO=%d clamp=%d last=%d)\n",
                  e1, e2, errno);
        }
      }
    }

    // === PHASE 4: Pin to target core ===
    // Dynamic strategy set by parent based on CPU frequency detection:
    //
    // HARD MODE (target core in cpuset, OR not top-freq cluster):
    //   Use sched_setaffinity to strictly pin to the target core.
    //
    // SOFT MODE (target core NOT in cpuset AND is top-freq cluster):
    //   Do NOT call sched_setaffinity — it triggers hmmac to constrain
    //   effective affinity, making super cores unreachable.
    //   Instead rely on QoS_USER_INTERACTIVE + util_clamp=1024 which
    //   signals the scheduler to prefer the fastest cores.
    {
      bool pinned = false;

      if (soft_mode) {
        // SOFT MODE with opportunistic lock:
        // QoS + util_clamp will guide scheduler to super cores (12/13).
        // Poll sched_getcpu() to detect when we're on the target core,
        // then try sched_setaffinity to lock to EXACTLY that core.
        // (sched_getaffinity shows cpuset {0-8} but sched_getcpu reveals
        // the real CPU — the scheduler can place us beyond cpuset via QoS)
        dprintf(2, "[PIN] SOFT MODE: waiting for scheduler to place us on core %d\n", core);

        // === TWO-PHASE: Wait for QoS cpuset expansion, then try hard pin ===
        // On 14-core SOCs (e.g. Kirin 9030P), cores 10/11 are NOT the fastest
        // (12/13 are). util_clamp=1024 directs scheduler to 12/13, not 10/11.
        // But if QoS expansion adds 10/11 to cpuset, we can hard-pin directly.
        // This also works for 12/13 — if they enter cpuset, hard pin is better.
        for (int wait_cycle = 0; wait_cycle < 5; wait_cycle++) {
          usleep(100000); // 100ms per cycle, 500ms max total
          // Re-assert util_clamp to keep scheduler demand high
          if (sched_attr_ok) syscall(__NR_sched_setattr, 0, &attr, 0);

          cpu_set_t expanded;
          CPU_ZERO(&expanded);
          sched_getaffinity(0, sizeof(expanded), &expanded);
          bool target_in_set = CPU_ISSET(core, &expanded) != 0;
          dprintf(2, "[PIN] POST-QoS #%d: cpuset={%s} target=%d in_set=%d\n",
                  wait_cycle + 1, cpuset_to_string(expanded).c_str(),
                  core, target_in_set ? 1 : 0);

          if (target_in_set) {
            // Target core is now in cpuset — switch to hard mode
            sched_setaffinity(0, sizeof(cpuset), &cpuset);
            int verify_cpu = sched_getcpu();
            cpu_set_t verify;
            CPU_ZERO(&verify);
            sched_getaffinity(0, sizeof(verify), &verify);
            dprintf(2, "[PIN] UPGRADE soft->hard: sched_setaffinity(%d), "
                       "now on cpu %d, affinity={%s}\n",
                    core, verify_cpu, cpuset_to_string(verify).c_str());
            if (CPU_ISSET(core, &verify)) {
              pinned = true;
              soft_mode = false;
              dprintf(2, "[PIN] HARD PIN via QoS expansion: core %d locked\n", core);
            }
            break;
          }
        }

        // Fallback: original polling if two-phase didn't pin
        if (!pinned) {
          dprintf(2, "[PIN] TWO-PHASE: core %d not in expanded cpuset, "
                     "falling back to opportunistic polling\n", core);

          // Poll: 10ms×20, 50ms×20, 100ms×20 = ~3.2s total
          const int poll_delays[] = {
            10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000,
            10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000,
            50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000,
            50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000, 50000,
            100000, 100000, 100000, 100000, 100000,
            100000, 100000, 100000, 100000, 100000,
            100000, 100000, 100000, 100000, 100000,
            100000, 100000, 100000, 100000, 100000
          };
          const int poll_count = (int)(sizeof(poll_delays) / sizeof(poll_delays[0]));

          for (int attempt = 0; attempt < poll_count; attempt++) {
            usleep(poll_delays[attempt]);
            if (sched_attr_ok) syscall(__NR_sched_setattr, 0, &attr, 0);

            // Check cpuset expansion every iteration (lightweight syscall)
            cpu_set_t poll_cs;
            CPU_ZERO(&poll_cs);
            sched_getaffinity(0, sizeof(poll_cs), &poll_cs);
            bool in_cpuset = CPU_ISSET(core, &poll_cs) != 0;

            int cur = sched_getcpu();

            if (in_cpuset) {
              // Target core is confirmed in cpuset — safe to hard-pin
              sched_setaffinity(0, sizeof(cpuset), &cpuset);
              int after = sched_getcpu();
              cpu_set_t verify;
              CPU_ZERO(&verify);
              sched_getaffinity(0, sizeof(verify), &verify);
              dprintf(2, "[PIN] CPUSET CONFIRMED at poll %d: core %d in cpuset, "
                         "sched_setaffinity -> cpu %d, affinity={%s}\n",
                      attempt + 1, core, after, cpuset_to_string(verify).c_str());
              if (CPU_ISSET(core, &verify)) {
                pinned = true;
                soft_mode = false;
                break;
              }
            } else if (cur == core) {
              // On target core via QoS bypass, but NOT in cpuset.
              // Try sched_setaffinity to "confirm current position" — the kernel
              // may allow locking to a core we're already running on via QoS.
              // CRITICAL: Do NOT reset-to-all on failure. That triggers hmmac
              // cascading restriction. Just silently continue if it doesn't stick.
              sched_setaffinity(0, sizeof(cpuset), &cpuset);
              int after = sched_getcpu();
              if (after == core) {
                pinned = true;
                soft_mode = false;
                dprintf(2, "[PIN] OPPORTUNISTIC LOCK: pinned to core %d at poll %d "
                           "(QoS bypass, no cpuset confirm)\n", core, attempt + 1);
                break;
              }
              // Failed — do NOT reset to all, just keep going
              dprintf(2, "[PIN] OPPORTUNISTIC MISS at poll %d: was on %d, now on %d "
                         "(no reset, continuing)\n", attempt + 1, core, after);
            }

            if (attempt == 19 || attempt == 39 || attempt == poll_count - 1) {
              dprintf(2, "[PIN] POLL: %d/%d, cpu=%d, target=%d, in_cpuset=%d\n",
                      attempt + 1, poll_count, cur, core, in_cpuset ? 1 : 0);
            }
          }

          if (!pinned) {
            dprintf(2, "[PIN] POLL: never landed on core %d during polling\n"
                       "[PIN] Watchdog will keep trying opportunistic lock every 10ms\n", core);
          }
        }
      } else {
        // HARD MODE: normal sched_setaffinity
        sched_setaffinity(0, sizeof(cpuset), &cpuset);

        cpu_set_t readback;
        CPU_ZERO(&readback);
        sched_getaffinity(0, sizeof(readback), &readback);

        if (CPU_ISSET(core, &readback)) {
          pinned = true;
          if (CPU_COUNT(&readback) == 1) {
            dprintf(2, "[PIN] STRICT pinned to core %d\n", core);
          } else {
            dprintf(2, "[PIN] soft-pinned to core %d (cpuset shared, count=%d)\n",
                    core, CPU_COUNT(&readback));
          }
        } else {
          // Retry with increasing delays
          const int RETRIES = 20;
          const int delays_us[] = {
            5000, 5000, 10000, 10000, 20000,
            50000, 50000, 50000, 50000, 50000,
            100000, 100000, 100000, 100000, 100000,
            200000, 200000, 200000, 200000, 200000
          };
          dprintf(2, "[PIN] core %d not in cpuset {%s}, retrying\n",
                  core, cpuset_to_string(readback).c_str());

          for (int attempt = 0; attempt < RETRIES; attempt++) {
            if (sched_attr_ok) syscall(__NR_sched_setattr, 0, &attr, 0);
            usleep(delays_us[attempt]);
            sched_setaffinity(0, sizeof(cpuset), &cpuset);
            CPU_ZERO(&readback);
            sched_getaffinity(0, sizeof(readback), &readback);

            if (CPU_ISSET(core, &readback)) {
              pinned = true;
              dprintf(2, "[PIN] pinned to core %d after retry %d\n", core, attempt + 1);
              break;
            }
          }

          if (!pinned) {
            dprintf(2, "[PIN] core %d still outside cpuset {%s} after retries\n",
                    core, cpuset_to_string(readback).c_str());
          }
        }
      }

      // Machine-readable result for ArkTS parsing
      dprintf(2, "[PIN-RESULT] target=%d effective=%d pinned=%s\n",
              core, core, pinned ? "YES" : "PENDING");
    }

    // === PHASE 5: Diagnostics — log what actually took effect ===
    log_pinning_diagnostics(core);

    // === PHASE 6: Watchdog timer (10ms interval for tighter control) ===
    g_watchdog_cpuset = cpuset;
    g_watchdog_sched_attr = attr;
    g_watchdog_use_sched_attr = sched_attr_ok;
    g_watchdog_target_cpu = core;
    g_watchdog_drift_count = 0;
    g_watchdog_fire_count = 0;
    g_watchdog_soft_mode = soft_mode;

    struct sigaction sa = {};
    sa.sa_handler = affinity_signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);

    struct itimerval timer = {};
    timer.it_value.tv_usec = 10000;    // first fire after 10ms
    timer.it_interval.tv_usec = 10000; // repeat every 10ms
    setitimer(ITIMER_REAL, &timer, NULL);

    // Log final watchdog stats on exit so they appear in stderr.log
    atexit([]() {
      dprintf(2, "[PIN-DIAG] watchdog_fires=%d drift_count=%d target_cpu=%d final_cpu=%d soft=%d\n",
              (int)g_watchdog_fire_count, (int)g_watchdog_drift_count,
              (int)g_watchdog_target_cpu, sched_getcpu(), (int)g_watchdog_soft_mode);
    });

    // run main & exit on the new stack
    switch_stack(1 + args_length, real_argv.data(), envp, main, stack_top);
  } else {
    // in parent process
    assert(pid != -1);
    int wstatus;

    // Publish child PID for cancellation from JS
    g_benchmark_child_pid = pid;

    // Tell keepalive thread the child PID so it can try cgroup migration
    keepalive.child_pid = pid;

    // Active wait: instead of blocking in waitpid(), poll with WNOHANG
    // and use the idle time to re-assert QoS + util_clamp + affinity.
    // This doubles the QoS demand signal (parent main thread + keepalive thread),
    // making it much harder for the resource scheduler to shrink the cpuset.
    while (true) {
      pid_t ret = waitpid(pid, &wstatus, WNOHANG);
      if (ret == pid) break;   // child exited
      if (ret == -1 && errno != EINTR) {
        keepalive.running = false;
        if (keepalive_tid) { pthread_join(keepalive_tid, nullptr); keepalive_tid = 0; }
        res = -1;
        goto cleanup;
      }

      // Parent re-asserts QoS demand signals to keep cpuset expanded
      OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
      if (!soft_mode) sched_setaffinity(0, sizeof(cpuset), &cpuset);
      syscall(__NR_sched_setattr, 0, &pre_attr, 0);

      usleep(200000); // 200ms polling interval
    }

    // Stop keepalive thread — benchmark is done
    keepalive.running = false;
    if (keepalive_tid) { pthread_join(keepalive_tid, nullptr); keepalive_tid = 0; }
    if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 0) {
      // failed
      res = -1;
      goto cleanup;
    }
  }

  after = get_time();
  time = (double)(after - before) / 1000000000;
  OH_HiTrace_FinishTrace();
  OH_LOG_INFO(LOG_APP, "End benchmark %{public}s in %{public}fs",
              benchmark.c_str(), time);
  res = time;

cleanup:
  g_benchmark_child_pid = 0;
  // Ensure keepalive thread is stopped (safety net for error paths)
  keepalive.running = false;
  if (keepalive_tid) { pthread_join(keepalive_tid, nullptr); keepalive_tid = 0; }
  OH_QoS_ResetThreadQoS();
  // Reset sched_setattr to SCHED_NORMAL (undo FIFO/util_clamp from pre-fork)
  {
    struct sched_param sp = {};
    sched_setscheduler(0, SCHED_OTHER, &sp);
    struct bench_sched_attr reset_attr = {};
    reset_attr.size = sizeof(reset_attr);
    reset_attr.sched_policy = SCHED_NORMAL;
    reset_attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    reset_attr.sched_util_min = 0;
    reset_attr.sched_util_max = 1024;
    syscall(__NR_sched_setattr, 0, &reset_attr, 0);
    // Reset affinity to allow all
    cpu_set_t all;
    CPU_ZERO(&all);
    for (int i = 0; i < 128; i++) CPU_SET(i, &all);
    sched_setaffinity(0, sizeof(all), &all);
  }
  if (handle) {
    dlclose(handle);
  }
  if (stack) {
    free(stack);
  }

  napi_value ret;
  napi_create_double(env, res, &ret);
  return ret;
}

#define S(x) #x
#define STRINGIFY(x) S(x)
static napi_value Info(napi_env env, napi_callback_info info) {
  napi_value ret;
  std::string res;

  res += "C/C++ Compiler Version: ";
  res += STRINGIFY(CXX_COMPILER_VERSION);
  res += "\n";

  res += "Fortran Compiler Version: ";
  res += STRINGIFY(FORTRAN_COMPILER_VERSION);
  res += "\n";

  struct utsname tmp;
  assert(uname(&tmp) == 0);
  res += "Uname: ";
  res += tmp.sysname;
  res += " ";
  res += tmp.nodename;
  res += " ";
  res += tmp.release;
  res += " ";
  res += tmp.version;
  res += " ";
  res += tmp.machine;

  napi_create_string_utf8(env, res.c_str(), res.length(), &ret);
  return ret;
}

static napi_value CpuInfo(napi_env env, napi_callback_info info) {
  napi_value ret;
  // https://stackoverflow.com/questions/2602013/read-whole-ascii-file-into-c-stdstring
  std::ifstream t("/proc/cpuinfo");
  std::string res((std::istreambuf_iterator<char>(t)),
                  std::istreambuf_iterator<char>());

  napi_create_string_utf8(env, res.c_str(), res.length(), &ret);
  return ret;
}

// read an integer from a sysfs file, return -1 on failure
static int read_sysfs_int(const std::string &path) {
  std::ifstream f(path);
  int val = -1;
  if (f.is_open()) f >> val;
  return val;
}

// parse a siblings list like "0,14" or "0-3,8-11"
static std::vector<int> parse_siblings_list(const std::string &path) {
  std::ifstream f(path);
  std::string line;
  std::vector<int> result;
  if (!std::getline(f, line)) return result;

  size_t pos = 0;
  while (pos < line.size()) {
    size_t comma = line.find(',', pos);
    std::string token = (comma == std::string::npos)
        ? line.substr(pos) : line.substr(pos, comma - pos);
    try {
      size_t dash = token.find('-');
      if (dash != std::string::npos) {
        int start = std::stoi(token.substr(0, dash));
        int end = std::stoi(token.substr(dash + 1));
        for (int i = start; i <= end; i++) result.push_back(i);
      } else if (!token.empty()) {
        result.push_back(std::stoi(token));
      }
    } catch (const std::exception &) {
      // skip malformed token
    }
    pos = (comma == std::string::npos) ? line.size() : comma + 1;
  }
  return result;
}

// Build a cpu_set_t for the target core.
// For benchmarking, pin to EXACTLY one logical CPU for maximum stability.
// The sibling-inclusive approach (which includes all SMT siblings) was found
// to still allow the scheduler to bounce between siblings.
static cpu_set_t build_single_core_cpuset(int core) {
  cpu_set_t cpuset;
  CPU_ZERO(&cpuset);
  CPU_SET(core, &cpuset);
  return cpuset;
}

// Build a cpu_set_t that includes the target core AND all its SMT siblings.
// Used by Clock() for frequency measurement where slight migration is OK.
static cpu_set_t build_physical_core_cpuset(int core) {
  cpu_set_t cpuset;
  CPU_ZERO(&cpuset);
  CPU_SET(core, &cpuset);

  // read SMT siblings from sysfs
  std::string path = "/sys/devices/system/cpu/cpu" + std::to_string(core) +
                     "/topology/thread_siblings_list";
  std::vector<int> siblings = parse_siblings_list(path);
  if (!siblings.empty()) {
    for (int s : siblings) {
      CPU_SET(s, &cpuset);
    }
    OH_LOG_INFO(LOG_APP, "Core %{public}d has %{public}d SMT siblings, pinning to physical core",
                core, (int)siblings.size());
  }
  return cpuset;
}

// detect CPU topology via sysfs and return as NAPI object:
// { numLogicalCores, numPhysicalCores, hasSmt, cores: [{ logicalId, coreId, packageId, siblings }] }
static napi_value CpuTopology(napi_env env, napi_callback_info info) {
  struct LogicalCore {
    int logical_id;
    int core_id;
    int package_id;
    std::vector<int> siblings;
  };

  std::vector<LogicalCore> cores;
  int consecutive_missing = 0;
  for (int i = 0; i < CPU_SETSIZE; i++) {
    std::string base = "/sys/devices/system/cpu/cpu" + std::to_string(i) + "/topology/";
    int core_id = read_sysfs_int(base + "core_id");
    if (core_id < 0) {
      if (++consecutive_missing > 16) break;
      continue;
    }
    consecutive_missing = 0;

    LogicalCore lc;
    lc.logical_id = i;
    lc.core_id = core_id;
    lc.package_id = read_sysfs_int(base + "physical_package_id");
    if (lc.package_id < 0) lc.package_id = 0;
    lc.siblings = parse_siblings_list(base + "thread_siblings_list");
    if (lc.siblings.empty()) lc.siblings.push_back(i);
    cores.push_back(lc);
  }

  // count physical cores using (package_id, core_id) pairs
  std::set<std::pair<int,int>> phys_set;
  for (auto &c : cores) {
    phys_set.insert({c.package_id, c.core_id});
  }
  int num_logical = (int)cores.size();
  int num_physical = (int)phys_set.size();
  bool has_smt = (num_logical > num_physical);

  OH_LOG_INFO(LOG_APP, "CPU topology: %{public}d logical, %{public}d physical, SMT=%{public}d",
              num_logical, num_physical, has_smt ? 1 : 0);

  // build NAPI return object
  napi_value result;
  napi_create_object(env, &result);

  napi_value val;
  napi_create_int32(env, num_logical, &val);
  napi_set_named_property(env, result, "numLogicalCores", val);

  napi_create_int32(env, num_physical, &val);
  napi_set_named_property(env, result, "numPhysicalCores", val);

  napi_get_boolean(env, has_smt, &val);
  napi_set_named_property(env, result, "hasSmt", val);

  // cores array
  napi_value cores_arr;
  napi_create_array_with_length(env, cores.size(), &cores_arr);
  for (size_t i = 0; i < cores.size(); i++) {
    napi_value core_obj;
    napi_create_object(env, &core_obj);

    napi_create_int32(env, cores[i].logical_id, &val);
    napi_set_named_property(env, core_obj, "logicalId", val);

    napi_create_int32(env, cores[i].core_id, &val);
    napi_set_named_property(env, core_obj, "coreId", val);

    napi_create_int32(env, cores[i].package_id, &val);
    napi_set_named_property(env, core_obj, "packageId", val);

    napi_value siblings_arr;
    napi_create_array_with_length(env, cores[i].siblings.size(), &siblings_arr);
    for (size_t j = 0; j < cores[i].siblings.size(); j++) {
      napi_value sval;
      napi_create_int32(env, cores[i].siblings[j], &sval);
      napi_set_element(env, siblings_arr, j, sval);
    }
    napi_set_named_property(env, core_obj, "siblings", siblings_arr);

    napi_set_element(env, cores_arr, i, core_obj);
  }
  napi_set_named_property(env, result, "cores", cores_arr);

  return result;
}

// ---------- Pinning diagnostics NAPI function ----------
// Returns a string with all pinning-related system information.
// Call from UI to understand why pinning may not be working.
// Parameter: core index to test
static napi_value PinDiag(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  int core = 0;
  if (argc >= 1) napi_get_value_int32(env, args[0], &core);

  std::ostringstream out;
  out << "=== CPU Pinning Diagnostics (target=" << core << ") ===\n";
  out << "PID: " << getpid() << "\n";
  out << "Current CPU: " << sched_getcpu() << "\n";

  // cpuset mount point discovery (also collect all cgroup mounts)
  std::string all_cgroup_mounts;
  std::string mount = find_cpuset_mount(&all_cgroup_mounts);
  out << "cpuset mount: '" << mount << "'\n";

  // cpuset cgroup (two sources)
  std::string cg = read_file_line("/proc/self/cpuset");
  out << "cpuset (/proc/self/cpuset): '" << cg << "'\n";
  std::string real_cg = get_cpuset_cgroup_path();
  out << "cpuset (/proc/self/cgroup): '" << real_cg << "'\n";

  // Use unified resolver for cpuset allowed CPUs
  std::string resolved_cpus = resolve_cpuset_cpus(cg);
  out << "cpuset allowed CPUs: " << (resolved_cpus.empty() ? "(not found)" : resolved_cpus) << "\n";

  // All cgroup-related mounts from /proc/mounts
  out << "\ncgroup mounts:\n";
  if (all_cgroup_mounts.empty()) out << "  (none found)\n";
  else out << all_cgroup_mounts;

  // Full cgroup membership
  out << "\n/proc/self/cgroup:\n";
  {
    std::ifstream f("/proc/self/cgroup");
    std::string line;
    while (std::getline(f, line)) {
      out << "  " << line << "\n";
    }
  }

  // Cpus_allowed from kernel
  {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
      if (line.compare(0, 13, "Cpus_allowed:") == 0 ||
          line.compare(0, 18, "Cpus_allowed_list:") == 0) {
        out << line << "\n";
      }
    }
  }

  // current scheduler policy
  int policy = sched_getscheduler(0);
  out << "Scheduler policy: " << policy;
  switch (policy) {
    case 0: out << " (NORMAL)"; break;
    case 1: out << " (FIFO)"; break;
    case 2: out << " (RR)"; break;
    case 3: out << " (BATCH)"; break;
    case 5: out << " (IDLE)"; break;
    case 6: out << " (DEADLINE)"; break;
  }
  out << "\n";

  // Test: set affinity to single core, read back
  cpu_set_t test_set;
  CPU_ZERO(&test_set);
  CPU_SET(core, &test_set);
  cpu_set_t pre_eff;
  CPU_ZERO(&pre_eff);
  sched_getaffinity(0, sizeof(pre_eff), &pre_eff);
  bool core_in_cpuset = CPU_ISSET(core, &pre_eff) != 0;
  out << "Target core " << core << " in cpuset: " << (core_in_cpuset ? "YES" : "NO")
      << " (cpuset={" << cpuset_to_string(pre_eff) << "})\n";

  // Always test sched_setaffinity — even for out-of-cpuset cores.
  // Record cpuset before and after to detect hmmac restriction changes.
  out << "\n--- sched_setaffinity DIRECT TEST (core " << core << ") ---\n";
  int ret = sched_setaffinity(0, sizeof(test_set), &test_set);
  int err = errno;
  out << "sched_setaffinity({" << core << "}): " << (ret == 0 ? "OK" : "FAILED")
      << " ret=" << ret << " errno=" << err << "\n";

  cpu_set_t post_eff;
  CPU_ZERO(&post_eff);
  sched_getaffinity(0, sizeof(post_eff), &post_eff);
  out << "Affinity BEFORE: {" << cpuset_to_string(pre_eff) << "}\n";
  out << "Affinity AFTER:  {" << cpuset_to_string(post_eff) << "}\n";
  out << "Actual CPU after: " << sched_getcpu() << "\n";

  // Check: did cpuset shrink? (hmmac side effect detection)
  int pre_count = CPU_COUNT(&pre_eff);
  int post_count = CPU_COUNT(&post_eff);
  if (post_count < pre_count) {
    out << "WARNING: cpuset SHRUNK from " << pre_count << " to " << post_count
        << " cores — hmmac restriction triggered!\n";
  } else if (post_count == pre_count && !core_in_cpuset) {
    out << "cpuset unchanged (no hmmac restriction)\n";
  }

  // Restore: reset affinity to all available
  cpu_set_t restore;
  CPU_ZERO(&restore);
  for (int i = 0; i < 128; i++) CPU_SET(i, &restore);
  sched_setaffinity(0, sizeof(restore), &restore);
  cpu_set_t restored;
  CPU_ZERO(&restored);
  sched_getaffinity(0, sizeof(restored), &restored);
  out << "After restore-all: {" << cpuset_to_string(restored) << "}\n";
  if (CPU_COUNT(&restored) < pre_count) {
    out << "WARNING: restore-all also shrunk! " << pre_count << " -> "
        << CPU_COUNT(&restored) << " — hmmac damage is permanent!\n";
  }

  // test sched_setattr
  struct bench_sched_attr attr = {};
  attr.size = sizeof(attr);
  // test SCHED_FIFO
  attr.sched_policy = SCHED_FIFO;
  attr.sched_priority = 1;
  attr.sched_flags = 0;
  int sa_ret = syscall(__NR_sched_setattr, 0, &attr, 0);
  out << "sched_setattr(FIFO): " << (sa_ret == 0 ? "OK" : "FAILED") << " errno=" << errno << "\n";
  if (sa_ret == 0) {
    // reset back to normal
    struct sched_param sp = {};
    sched_setscheduler(0, SCHED_OTHER, &sp);
  }

  // test util clamp
  attr.sched_policy = SCHED_NORMAL;
  attr.sched_priority = 0;
  attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
  attr.sched_util_min = 1024;
  attr.sched_util_max = 1024;
  sa_ret = syscall(__NR_sched_setattr, 0, &attr, 0);
  out << "sched_setattr(util_clamp): " << (sa_ret == 0 ? "OK" : "FAILED") << " errno=" << errno << "\n";
  if (sa_ret == 0) {
    // reset
    attr.sched_flags = SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    attr.sched_util_min = 0;
    attr.sched_util_max = 1024;
    syscall(__NR_sched_setattr, 0, &attr, 0);
  }

  // Exhaustive cpuset file probing — read value from every candidate path
  // HongMeng mounts individual cpuset files as separate cgroup mounts:
  //   /dev/cpuset/cpuset.cpus (NOT /dev/cpuset/cpus or /dev/cpuset/top-app/cpus)
  static const char *probe_paths[] = {
    // HongMeng direct mounts (discovered from /proc/mounts)
    "/dev/cpuset/cpuset.cpus",
    "/dev/cpuset/cpuset.cpus.effective",
    "/dev/cpuset/cpuset.mems",
    "/dev/cpuset/tasks",
    "/dev/cpuset/cgroup.procs",
    // Standard cgroup v1
    "/dev/cpuset/cpus",
    "/dev/cpuset/top-app/cpus",
    // cgroup v2
    "/sys/fs/cgroup/cpuset.cpus",
    "/sys/fs/cgroup/cpuset.cpus.effective",
    "/sys/fs/cgroup/top-app/cpuset.cpus",
  };
  out << "\nfile probing (value | writable):\n";
  for (auto p : probe_paths) {
    std::string val = read_file_line(p);
    bool writable = (access(p, W_OK) == 0);
    bool exists = (access(p, F_OK) == 0);
    if (!val.empty() || writable || exists) {
      out << "  " << p << " = '" << val << "' w=" << writable << "\n";
    }
  }

  // Also probe: what files exist under /sys/fs/cgroup/top-app/ ?
  // Try reading known cgroup control files
  static const char *cg_top_app_files[] = {
    "/sys/fs/cgroup/top-app/cgroup.type",
    "/sys/fs/cgroup/top-app/cgroup.controllers",
    "/sys/fs/cgroup/top-app/cgroup.subtree_control",
    "/sys/fs/cgroup/top-app/cpu.max",
  };
  out << "\n/sys/fs/cgroup/top-app/ probing:\n";
  for (auto p : cg_top_app_files) {
    std::string val = read_file_line(p);
    if (!val.empty()) out << "  " << p << " = '" << val << "'\n";
  }

  // Reset affinity to allow all
  cpu_set_t all;
  CPU_ZERO(&all);
  for (int i = 0; i < 128; i++) CPU_SET(i, &all);
  sched_setaffinity(0, sizeof(all), &all);

  std::string result = out.str();
  napi_value ret_val;
  napi_create_string_utf8(env, result.c_str(), result.length(), &ret_val);
  return ret_val;
}

// Return the effective cpuset (cores available to this thread after cpuset restriction)
// as a JS array of core indices, e.g. [4, 5, 6, 7, 8].
static napi_value GetEffectiveCpuset(napi_env env, napi_callback_info /*info*/) {
  cpu_set_t cs;
  CPU_ZERO(&cs);
  sched_getaffinity(0, sizeof(cs), &cs);

  napi_value result;
  napi_create_array(env, &result);

  uint32_t idx = 0;
  for (int i = 0; i < CPU_SETSIZE; i++) {
    if (CPU_ISSET(i, &cs)) {
      napi_value val;
      napi_create_int32(env, i, &val);
      napi_set_element(env, result, idx++, val);
    }
  }
  return result;
}

// Kill the running benchmark child process for immediate cancellation
static napi_value CancelBenchmark(napi_env env, napi_callback_info info) {
  pid_t pid = g_benchmark_child_pid;
  bool killed = false;
  if (pid > 0) {
    OH_LOG_INFO(LOG_APP, "CancelBenchmark: killing child pid %{public}d", (int)pid);
    kill(pid, SIGKILL);
    killed = true;
  } else {
    OH_LOG_INFO(LOG_APP, "CancelBenchmark: no child process running");
  }
  napi_value ret;
  napi_get_boolean(env, killed, &ret);
  return ret;
}

// Return kernel version (uname) and uptime (clock_gettime BOOTTIME) as a JS object
static napi_value KernelInfo(napi_env env, napi_callback_info info) {
  napi_value result;
  napi_create_object(env, &result);

  // Kernel version from uname
  struct utsname uts;
  if (uname(&uts) == 0) {
    std::string kernel = std::string(uts.sysname) + " " + uts.release + " " + uts.version;
    napi_value val;
    napi_create_string_utf8(env, kernel.c_str(), kernel.length(), &val);
    napi_set_named_property(env, result, "kernel", val);
  }

  // Uptime from clock_gettime(CLOCK_BOOTTIME)
  struct timespec ts;
  if (clock_gettime(CLOCK_BOOTTIME, &ts) == 0) {
    napi_value val;
    napi_create_double(env, (double)ts.tv_sec + (double)ts.tv_nsec / 1e9, &val);
    napi_set_named_property(env, result, "uptimeSeconds", val);
  }

  return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"clock", nullptr, Clock, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"info", nullptr, Info, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cpuInfo", nullptr, CpuInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cpuTopology", nullptr, CpuTopology, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"pinDiag", nullptr, PinDiag, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getEffectiveCpuset", nullptr, GetEffectiveCpuset, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cancelBenchmark", nullptr, CancelBenchmark, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"kernelInfo", nullptr, KernelInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
  napi_module_register(&demoModule);
}
