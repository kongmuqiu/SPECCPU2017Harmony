export const run: (cwd: string, stdin: string, stdout: string, stderr: string, benchmark: string, args: string[], core: number, stdoutUnbuffered: boolean) => number;
export const clock: (core: number) => number;
export const info: () => string;
export const cpuInfo: () => string;

// 拓扑接口（必须与 Index.ets 中的同名接口和 napi_init.cpp::CpuTopology() 保持一致）
export interface TopologyCore {
  logicalId: number;
  coreId: number;
  packageId: number;
  siblings: number[];
}

export interface CpuTopologyInfo {
  numLogicalCores: number;
  numPhysicalCores: number;
  hasSmt: boolean;
  cores: TopologyCore[];
}

export const cpuTopology: () => CpuTopologyInfo;

// 锁核诊断：返回详细的 CPU 锁核状态信息（cpuset cgroup、affinity、调度策略等）
export const pinDiag: (core: number) => string;

// 获取当前线程的有效 cpuset（受 cgroup 限制后的可用核心列表）
export const getEffectiveCpuset: () => number[];

// 终止当前运行的 benchmark 子进程（SIGKILL），立即停止测试
export const cancelBenchmark: () => boolean;

// 获取内核版本和开机时长
export interface KernelInfoResult {
  kernel?: string;        // 内核版本（uname）
  uptimeSeconds?: number; // 开机时长（秒）
}
export const kernelInfo: () => KernelInfoResult;
