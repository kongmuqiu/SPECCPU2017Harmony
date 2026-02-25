import { hilog } from '@kit.PerformanceAnalysisKit';
import { zlib } from '@kit.BasicServicesKit';
import testNapi from 'libentry.so';
import fs from '@ohos.file.fs';
import { taskpool } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { isEqual, readWholeFile, CompareOptions } from './utils.ets';
import { promptAction } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { thermal } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { batteryInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { sensor } from '@kit.SensorServiceKit';
import { storageStatistics } from '@kit.CoreFileKit';

// ============================================================
// 数据接口
// ============================================================

interface ValidateConfig {
  type: "STDOUT" | "FILE" | "COMMAND";
  file?: string;
  compareOption?: CompareOptions;
  command?: string;
}

interface BenchmarkConfig {
  args: string;
  validates: ValidateConfig[];
}

type Benchmark = string | BenchmarkConfig;

interface BenchmarkResult {
  benchmark: string;
  totalTime: number;
  ratio: number;
  passed: boolean;
  avgPowerW: number;    // 平均功率（瓦特）
  energyJ: number;      // 总能耗（焦耳）
}

interface TestRecord {
  id: number;             // 时间戳作为唯一 ID
  timestamp: string;      // 可读时间
  device: string;         // 设备名称
  core: number;           // 使用的核心
  suiteLabel: string;     // int / fp / int_fp
  specRateScore: number;  // SPECrate 得分（总分）
  specIntScore: number;   // SPECrate INT 得分
  specFpScore: number;    // SPECrate FP 得分
  totalEnergyJ: number;   // 总能耗（焦耳）
  results: BenchmarkResult[];
}

interface PowerStats {
  avgPowerW: number;
  energyJ: number;
}

interface SensorItem {
  name: string;
  vendor: string;
  power: string;
}

// 拓扑接口定义（必须与 entry/src/main/cpp/types/libentry/Index.d.ts 和
// napi_init.cpp::CpuTopology() 的返回结构保持一致）
interface TopologyCore {
  logicalId: number;
  coreId: number;
  packageId: number;
  siblings: number[];
}

interface CpuTopologyInfo {
  numLogicalCores: number;
  numPhysicalCores: number;
  hasSmt: boolean;
  cores: TopologyCore[];
}

// ============================================================
// Concurrent 工作函数 (不可修改签名)
// ============================================================

@Concurrent
function findCoreFreq(cores: number): number[] {
  let freqs: number[] = [];
  for (let i = 0; i < cores; i++) {
    try {
      let freq: number = testNapi.clock(i);
      freqs.push(freq);
    } catch (e) {
      freqs.push(0);
    }
  }
  return freqs;
}

@Concurrent
function worker(inputDir: string, outputDir: string, stdinFile: string, benchmark: string, args: string[], core: number,
  validates: ValidateConfig[]): number {
  hilog.info(0x0000, 'mainTag',
    'Enter worker: %{public}s, %{public}s, %{public}s, %{public}s, %{public}s, %{public}d, %{public}s', inputDir,
    outputDir, stdinFile, benchmark, JSON.stringify(args), core, JSON.stringify(validates));
  let ret: number = -1;
  try {
    let stdoutFile: string = inputDir + "/stdout.log";
    let stderrFile: string = inputDir + "/stderr.log";
    hilog.info(0x0000, 'mainTag',
      'Run command: %{public}s, %{public}s, %{public}s, %{public}s, %{public}s, %{public}s, %{public}d',
      inputDir, stdinFile, stdoutFile, stderrFile, benchmark, JSON.stringify(args), core);
    ret = testNapi.run(inputDir, stdinFile, stdoutFile, stderrFile, benchmark, args, core, false);
    hilog.info(0x0000, 'mainTag', 'Got stdout: %{public}s', fs.readTextSync(stdoutFile));
    hilog.info(0x0000, 'mainTag', 'Got stderr: %{public}s', fs.readTextSync(stderrFile));

    if (ret < 0) {
      return ret;
    }

    for (let validate of validates) {
      if (validate.type === "STDOUT" || validate.type === "FILE") {
        let expectedFile: string = outputDir + "/" + validate.file!;
        let actualFile: string = (validate.type === "STDOUT") ? stdoutFile : (inputDir + "/" + validate.file!);
        hilog.info(0x0000, 'mainTag', 'Validate %{public}s against %{public}s', actualFile, expectedFile);
        let actual: ArrayBuffer = readWholeFile(actualFile);
        let expected: ArrayBuffer = readWholeFile(expectedFile);
        if (isEqual(actual, expected, validate.compareOption)) {
          hilog.info(0x0000, 'mainTag', 'Validation passed: %{public}d bytes', actual.byteLength);
        } else {
          hilog.info(0x0000, 'mainTag', 'Validation failed');
          ret = -1;
          break;
        }
      } else if (validate.type === "COMMAND") {
        let parts = validate.command!.split(" ");
        let validator = parts[0];
        let validator_args = parts.slice(1);
        let stdoutFile: string = inputDir + "/validate-stdout.log";
        let stderrFile: string = inputDir + "/validate-stderr.log";
        hilog.info(0x0000, 'mainTag',
          'Run command: %{public}s, %{public}s, %{public}s, %{public}s, %{public}s, %{public}s, %{public}d',
          inputDir, "", stdoutFile, stderrFile, validator, JSON.stringify(validator_args), core);
        if (testNapi.run(inputDir, "", stdoutFile, stderrFile, validator, validator_args, core, true) < 0) {
          hilog.info(0x0000, 'mainTag', 'Failed to run validation command %{public}s', validate.command!);
          ret = -1;
          break;
        }
        hilog.info(0x0000, 'mainTag', 'Got stdout: %{public}s', fs.readTextSync(stdoutFile));
        hilog.info(0x0000, 'mainTag', 'Got stderr: %{public}s', fs.readTextSync(stderrFile));
        let actualFile: string = stdoutFile;
        let expectedFile: string = outputDir + "/" + validate.file;
        hilog.info(0x0000, 'mainTag', 'Validate %{public}s against %{public}s', actualFile, expectedFile);
        let actual: ArrayBuffer = readWholeFile(actualFile);
        let expected: ArrayBuffer = readWholeFile(expectedFile);
        if (isEqual(actual, expected, validate.compareOption)) {
          hilog.info(0x0000, 'mainTag', 'Validation passed: %{public}d bytes', actual.byteLength);
        } else {
          hilog.info(0x0000, 'mainTag', 'Validation failed');
          ret = -1;
          break;
        }
      }
    }
  } catch (err) {
    let errorMsg = 'Unknown error';
    if (err instanceof Error) {
      errorMsg = `${err.name}: ${err.message}${err.stack ? '\nStack: ' + err.stack : ''}`;
    } else if (typeof err === 'object' && err !== null) {
      errorMsg = `Error object: ${JSON.stringify(err, Object.getOwnPropertyNames(err))}`;
    } else {
      errorMsg = String(err);
    }
    hilog.info(0x0000, 'mainTag', 'Got error in worker: %{public}s', errorMsg);
    ret = -1;
  }
  return ret;
}

// ============================================================
// 基准测试列表
// ============================================================

let int_rate: string[] = [
  "500.perlbench_r",
  "502.gcc_r",
  "505.mcf_r",
  "520.omnetpp_r",
  "523.xalancbmk_r",
  "525.x264_r",
  "531.deepsjeng_r",
  "541.leela_r",
  "548.exchange2_r",
  "557.xz_r",
];

let fp_rate: string[] = [
  "503.bwaves_r",
  "507.cactuBSSN_r",
  "508.namd_r",
  "510.parest_r",
  "511.povray_r",
  "519.lbm_r",
  "521.wrf_r",
  "526.blender_r",
  "527.cam4_r",
  "538.imagick_r",
  "544.nab_r",
  "549.fotonik3d_r",
  "554.roms_r",
];

// 中文显示名
let benchmarkNames: Map<string, string> = new Map();
benchmarkNames.set("500.perlbench_r", "Perl 解释器");
benchmarkNames.set("502.gcc_r", "GCC 编译器");
benchmarkNames.set("505.mcf_r", "路线规划");
benchmarkNames.set("520.omnetpp_r", "离散事件模拟");
benchmarkNames.set("523.xalancbmk_r", "XML 转换");
benchmarkNames.set("525.x264_r", "H.264 视频编码");
benchmarkNames.set("531.deepsjeng_r", "AI 象棋引擎");
benchmarkNames.set("541.leela_r", "AI 围棋引擎");
benchmarkNames.set("548.exchange2_r", "数独求解器");
benchmarkNames.set("557.xz_r", "数据压缩");
benchmarkNames.set("503.bwaves_r", "爆炸波模拟");
benchmarkNames.set("507.cactuBSSN_r", "广义相对论");
benchmarkNames.set("508.namd_r", "分子动力学");
benchmarkNames.set("510.parest_r", "生物医学成像");
benchmarkNames.set("511.povray_r", "光线追踪");
benchmarkNames.set("519.lbm_r", "流体力学");
benchmarkNames.set("521.wrf_r", "天气预报模型");
benchmarkNames.set("526.blender_r", "3D 渲染");
benchmarkNames.set("527.cam4_r", "大气建模");
benchmarkNames.set("538.imagick_r", "图像处理");
benchmarkNames.set("544.nab_r", "分子建模");
benchmarkNames.set("549.fotonik3d_r", "计算电磁学");
benchmarkNames.set("554.roms_r", "海洋环流模型");

// 参考时间
let reftime: Map<string, number> = new Map();
reftime.set("500.perlbench_r", 1592);
reftime.set("502.gcc_r", 1416);
reftime.set("505.mcf_r", 1616);
reftime.set("520.omnetpp_r", 1312);
reftime.set("523.xalancbmk_r", 1056);
reftime.set("525.x264_r", 1751);
reftime.set("531.deepsjeng_r", 1146);
reftime.set("541.leela_r", 1656);
reftime.set("548.exchange2_r", 2620);
reftime.set("557.xz_r", 1080);
reftime.set("503.bwaves_r", 10028);
reftime.set("507.cactuBSSN_r", 1266);
reftime.set("508.namd_r", 950);
reftime.set("510.parest_r", 2616);
reftime.set("511.povray_r", 2335);
reftime.set("519.lbm_r", 1054);
reftime.set("521.wrf_r", 2240);
reftime.set("526.blender_r", 1523);
reftime.set("527.cam4_r", 1749);
reftime.set("538.imagick_r", 2487);
reftime.set("544.nab_r", 1683);
reftime.set("549.fotonik3d_r", 3897);
reftime.set("554.roms_r", 1589);

// 温度等级
let thermalLevels: string[] = ["散热良好", "正常", "温热", "较热", "过热", "高温警告", "紧急", "极限"];
let thermalColors: string[] = ["#4CAF50", "#4CAF50", "#FF9800", "#FF5722", "#F44336", "#F44336", "#B71C1C", "#B71C1C"];

// ============================================================
// 辅助函数
// ============================================================

function formatTime(seconds: number): string {
  let h = Math.floor(seconds / 3600);
  let m = Math.floor((seconds % 3600) / 60);
  let s = seconds % 60;
  if (h > 0) return h + "时" + m + "分" + s + "秒";
  if (m > 0) return m + "分" + s + "秒";
  return s + "秒";
}

function getBenchmarkConfigs(): Map<string, Benchmark[]> {
  let benchmarks: Map<string, Benchmark[]> = new Map();
  benchmarks.set("500.perlbench_r", [
    {
      args: "-I./lib checkspam.pl 2500 5 25 11 150 1 1 1 1",
      validates: [{ type: "STDOUT", file: "checkspam.2500.5.25.11.150.1.1.1.1.out" }],
    } as BenchmarkConfig,
    {
      args: "-I./lib diffmail.pl 4 800 10 17 19 300",
      validates: [{ type: "STDOUT", file: "diffmail.4.800.10.17.19.300.out" }],
    } as BenchmarkConfig,
    {
      args: "-I./lib splitmail.pl 6400 12 26 16 100 0",
      validates: [{ type: "STDOUT", file: "splitmail.6400.12.26.16.100.0.out" }],
    } as BenchmarkConfig,
  ]);
  benchmarks.set("502.gcc_r", [
    {
      args: "gcc-pp.c -O3 -finline-limit=0 -fif-conversion -fif-conversion2 -o gcc-pp.opts-O3_-finline-limit_0_-fif-conversion_-fif-conversion2.s",
      validates: [{ type: "FILE", file: "gcc-pp.opts-O3_-finline-limit_0_-fif-conversion_-fif-conversion2.s" }],
    } as BenchmarkConfig,
    {
      args: "gcc-pp.c -O2 -finline-limit=36000 -fpic -o gcc-pp.opts-O2_-finline-limit_36000_-fpic.s",
      validates: [{ type: "FILE", file: "gcc-pp.opts-O2_-finline-limit_36000_-fpic.s" }],
    } as BenchmarkConfig,
    {
      args: "gcc-smaller.c -O3 -fipa-pta -o gcc-smaller.opts-O3_-fipa-pta.s",
      validates: [{ type: "FILE", file: "gcc-smaller.opts-O3_-fipa-pta.s" }],
    } as BenchmarkConfig,
    {
      args: "ref32.c -O5 -o ref32.opts-O5.s",
      validates: [{ type: "FILE", file: "ref32.opts-O5.s" }],
    } as BenchmarkConfig,
    {
      args: "ref32.c -O3 -fselective-scheduling -fselective-scheduling2 -o ref32.opts-O3_-fselective-scheduling_-fselective-scheduling2.s",
      validates: [{ type: "FILE", file: "ref32.opts-O3_-fselective-scheduling_-fselective-scheduling2.s" }],
    } as BenchmarkConfig,
  ]);
  benchmarks.set("505.mcf_r", [
    { args: "inp.in", validates: [{ type: "STDOUT", file: "inp.out" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("520.omnetpp_r", [
    { args: "-c General -r 0", validates: [{ type: "FILE", file: "General-0.sca" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("523.xalancbmk_r", [
    { args: "-v t5.xml xalanc.xsl", validates: [{ type: "STDOUT", file: "ref-t5.out" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("525.x264_r", [
    "--pass 1 --stats x264_stats.log --bitrate 1000 --frames 1000 -o BuckBunny_New.264 BuckBunny.yuv 1280x720",
    "--pass 2 --stats x264_stats.log --bitrate 1000 --dumpyuv 200 --frames 1000 -o BuckBunny_New.264 BuckBunny.yuv 1280x720",
    {
      args: "--seek 500 --dumpyuv 200 --frames 1250 -o BuckBunny_New.264 BuckBunny.yuv 1280x720",
      validates: [200, 400, 600, 700, 800, 900, 999, 1100, 1249].map((frame) => {
        return {
          type: "COMMAND",
          command: "imagevalidate_525 -avg -threshold 0.5 -maxthreshold 20 frame_" + frame +
            ".yuv ../compare/frame_" + frame + ".org.tga",
          file: "imagevalidate_frame_" + frame + ".out",
          compareOption: { relativeTolerance: 0.085 } as CompareOptions,
        } as ValidateConfig;
      }),
    }
  ]);
  benchmarks.set("531.deepsjeng_r", [
    { args: "ref.txt", validates: [{ type: "STDOUT", file: "ref.out" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("541.leela_r", [
    { args: "ref.sgf", validates: [{ type: "STDOUT", file: "ref.out" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("548.exchange2_r", [
    { args: "6", validates: [{ type: "FILE", file: "s.txt" }] } as BenchmarkConfig,
  ]);
  benchmarks.set("557.xz_r", [
    {
      args: "cld.tar.xz 160 19cf30ae51eddcbefda78dd06014b4b96281456e078ca7c13e1c0c9e6aaea8dff3efb4ad6b0456697718cede6bd5454852652806a657bb56e07d61128434b474 59796407 61004416 6",
      validates: [{ type: "STDOUT", file: "cld.tar-160-6.out" }],
    } as BenchmarkConfig,
    {
      args: "cpu2006docs.tar.xz 250 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 23047774 23513385 6e",
      validates: [{ type: "STDOUT", file: "cpu2006docs.tar-250-6e.out" }],
    } as BenchmarkConfig,
    {
      args: "input.combined.xz 250 a841f68f38572a49d86226b7ff5baeb31bd19dc637a922a972b2e6d1257a890f6a544ecab967c313e370478c74f760eb229d4eef8a8d2836d233d3e9dd1430bf 40401484 41217675 7",
      validates: [{ type: "STDOUT", file: "input.combined-250-7.out" }],
    } as BenchmarkConfig,
  ]);
  // fp rate
  benchmarks.set("503.bwaves_r", [1, 2, 3, 4].map((i) => {
    return {
      args: "bwaves_" + i + " < bwaves_" + i + ".in",
      validates: [{
        type: "STDOUT", file: "bwaves_" + i + ".out",
        compareOption: { absoluteTolerance: 1e-16, relativeTolerance: 0.015 }
      }],
    } as BenchmarkConfig;
  }));
  benchmarks.set("507.cactuBSSN_r", [{
    args: "spec_ref.par",
    validates: [
      { type: "STDOUT", file: "spec_ref.out" },
      { type: "FILE", file: "gxx.xl", compareOption: { absoluteTolerance: 5e-13 } },
      { type: "FILE", file: "gxy.xl", compareOption: { absoluteTolerance: 5e-13 } },
    ],
  } as BenchmarkConfig]);
  benchmarks.set("508.namd_r", [{
    args: "--input apoa1.input --output apoa1.ref.output --iterations 65",
    validates: [{ type: "FILE", file: "apoa1.ref.output", compareOption: { absoluteTolerance: 5e-05 } }],
  } as BenchmarkConfig]);
  benchmarks.set("510.parest_r", [{
    args: "ref.prm",
    validates: [
      { type: "FILE", file: "001-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "002-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "003-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "004-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "005-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "006-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "007-m00.vtk", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "log", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "me.prm", compareOption: { absoluteTolerance: 0.001 } },
      { type: "FILE", file: "statistics", compareOption: { absoluteTolerance: 0.004 } },
    ],
  } as BenchmarkConfig]);
  benchmarks.set("511.povray_r", [{
    args: "SPEC-benchmark-ref.ini",
    validates: [{
      type: "COMMAND",
      command: "imagevalidate_511 SPEC-benchmark.tga ../compare/SPEC-benchmark.org.tga",
      file: "imagevalidate_SPEC-benchmark.tga.out",
      compareOption: { relativeTolerance: 0.06 },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("519.lbm_r", [{
    args: "3000 reference.dat 0 0 100_100_130_ldc.of",
    validates: [{ type: "STDOUT", file: "lbm.out", compareOption: { absoluteTolerance: 1e-07 } }],
  } as BenchmarkConfig]);
  benchmarks.set("521.wrf_r", [{
    args: "",
    validates: [{
      type: "COMMAND",
      command: "diffwrf_521 wrfout_d01_2000-01-24_20_00_00 ../compare/wrf_reference_01",
      file: "diffwrf_output_01.txt",
      compareOption: { collapseWhitespace: true },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("526.blender_r", [{
    args: "sh3_no_char.blend --render-output sh3_no_char_ --threads 1 -b -F RAWTGA -s 849 -e 849 -a",
    validates: [{
      type: "COMMAND",
      command: "imagevalidate_526 -avg -threshold 0.75 -maxthreshold 0.01 sh3_no_char_0849.tga ../compare/sh3_no_char_0849.org.tga",
      file: "imagevalidate_sh3_no_char_0849.out",
      compareOption: { relativeTolerance: 0.05 },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("527.cam4_r", [{
    args: "",
    validates: [{
      type: "COMMAND",
      command: "cam4_validate_527 10 0.0035 ../compare/h0_ctrl.nc h0.nc",
      file: "cam4_validate.txt",
      compareOption: { collapseWhitespace: true },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("538.imagick_r", [{
    args: "-limit disk 0 refrate_input.tga -edge 41 -resample 181% -emboss 31 -colorspace YUV -mean-shift 19x19+15% -resize 30% refrate_output.tga",
    validates: [{
      type: "COMMAND",
      command: "imagevalidate_538 -avg -threshold 0.95 -maxthreshold 0.001 refrate_output.tga ../compare/refrate_expected.tga",
      file: "refrate_validate.out",
      compareOption: { relativeTolerance: 0.01 },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("544.nab_r", [{
    args: "1am0 1122214447 122",
    validates: [{ type: "STDOUT", file: "1am0.out", compareOption: { relativeTolerance: 0.01, skipRelativeTolerance: 2 } }],
  } as BenchmarkConfig]);
  benchmarks.set("549.fotonik3d_r", [{
    args: "",
    validates: [{
      type: "FILE", file: "pscyee.out",
      compareOption: { absoluteTolerance: 1e-27, relativeTolerance: 1e-10 },
    }],
  } as BenchmarkConfig]);
  benchmarks.set("554.roms_r", [{
    args: "< ocean_benchmark2.in.x",
    validates: [{
      type: "STDOUT", file: "ocean_benchmark2.log",
      compareOption: { absoluteTolerance: 1e-07, relativeTolerance: 1e-07, collapseWhitespace: true },
    }],
  } as BenchmarkConfig]);
  return benchmarks;
}

// ============================================================
// 主界面
// ============================================================

@Entry
@ComponentV2
struct Index {
  // Tab 状态
  @Local currentTabIndex: number = 0;

  // 核心选择
  @Local core: number = 0;
  @Local numCores: number = 0;
  @Local partIds: string[] = [];
  @Local coreFreqs: number[] = [];
  @Local findingCore: boolean = false;

  // CPU 拓扑（SMT 感知）
  @Local hasSmt: boolean = false;
  @Local numPhysicalCores: number = 0;
  @Local coreTopology: TopologyCore[] = [];
  @Local pinDiagResult: string = '';
  @Local effectiveCpuset: number[] = [];  // cpuset 限制后可用的核心列表

  // 基准选择
  @Local selectedInt: boolean[] = new Array(10).fill(true) as boolean[];
  @Local selectedFp: boolean[] = new Array(13).fill(true) as boolean[];
  @Local selectAllInt: boolean = true;
  @Local selectAllFp: boolean = true;

  // 运行状态
  @Local running: boolean = false;
  @Local stopRequested: boolean = false;
  @Local currentBenchIndex: number = 0;
  @Local totalBenchCount: number = 0;
  @Local currentBenchName: string = '';
  @Local currentSubIndex: number = 0;
  @Local currentSubTotal: number = 0;
  @Local elapsedTime: number = 0;
  @Local thermalText: string = '正常';
  @Local thermalColor: string = '#4CAF50';

  // 结果
  @Local results: BenchmarkResult[] = [];
  @Local specRateScore: number = 0;
  @Local specIntScore: number = 0;
  @Local specFpScore: number = 0;
  @Local suiteLabel: string = '';

  // 日志
  @Local log: string = '';
  @Local logExpanded: boolean = false;

  // 安全区域（传统回调方式，兼容 API 9+）
  @Local topSafeHeight: number = 0;
  @Local bottomSafeHeight: number = 0;

  // 实时频率
  @Local liveFreqs: number[] = [];

  // ---- 信息页数据 ----
  @Local infoLoaded: boolean = false;
  // 系统
  @Local sysOsVersion: string = '';
  @Local sysApiLevel: string = '';
  @Local sysBuildTime: string = '';
  @Local sysKernel: string = '';
  @Local sysKernelBuild: string = '';
  @Local sysUptime: string = '';
  @Local sysLanguage: string = '';
  @Local sysTimezone: string = '';
  @Local sysSecurityPatch: string = '';
  @Local sysBuildType: string = '';
  @Local sysVersionId: string = '';
  // 存储
  @Local ramTotal: string = '';
  @Local ramUsed: string = '';
  @Local ramPercent: number = 0;
  @Local swapTotal: string = '';
  @Local swapUsed: string = '';
  @Local swapPercent: number = 0;
  @Local storageTotal: string = '';
  @Local storageUsed: string = '';
  @Local storagePercent: number = 0;
  // 电池
  @Local battLevel: number = 0;
  @Local battVoltage: string = '';
  @Local battTemp: string = '';
  @Local battStatus: string = '';
  @Local battHealth: string = '';
  @Local battTech: string = '';
  @Local battPlugType: string = '';
  // 屏幕
  @Local screenWidth: number = 0;
  @Local screenHeight: number = 0;
  @Local screenDensity: number = 0;
  @Local screenXDpi: number = 0;
  @Local screenYDpi: number = 0;
  @Local screenRefreshRate: number = 0;
  @Local screenRefreshRates: string = '';
  @Local screenHdr: string = '';
  @Local screenColorSpaces: string = '';
  @Local screenRotation: number = 0;
  @Local screenPhysSize: string = '';
  // 传感器
  @Local sensorList: SensorItem[] = [];

  // 测试记录存档
  @Local testRecords: TestRecord[] = [];
  @Local showHistory: boolean = false;

  // 非响应式
  private currentThermalLevel: thermal.ThermalLevel = thermal.ThermalLevel.COOL;
  private startTimestamp: number = 0;
  private timerHandle: number = -1;
  private freqTimerHandle: number = -1;
  private freqPolling: boolean = false; // 是否正在进行一次频率采样
  private pageVisible: boolean = false; // 页面是否可见
  private initialized: boolean = false;
  private powerSamples: number[] = [];  // 瞬时功率样本（瓦特）
  private powerSampleTimer: number = -1;
  private mainWindow: window.Window | null = null;

  onPageShow() {
    // 首次进入时初始化，避免切后台回来重复执行
    if (!this.initialized) {
      this.initialized = true;

      // 初始化安全区域（传统回调，兼容 API 9+）
      this.initAvoidArea();

      // 加载上次保存的配置
      this.loadConfig();

      // 加载测试记录存档
      this.loadTestRecords();

      // 加载设备信息（在初始化阶段完成，确保 @Local 在渲染前赋值）
      this.loadDeviceInfo();

      thermal.registerThermalLevelCallback((level: thermal.ThermalLevel) => {
        this.currentThermalLevel = level;
        this.thermalText = thermalLevels[level];
        this.thermalColor = thermalColors[level];
        this.log += "温度等级: " + thermalLevels[level] + "\n";
      });
      this.log += "设备: " + deviceInfo.marketName + "\n";

      let cpuinfo: string = testNapi.cpuInfo();
      this.log += cpuinfo + "\n";
      let lines: string[] = cpuinfo.split("\n");
      this.partIds = [];
      for (let line of lines) {
        if (line.startsWith("CPU part")) {
          let parts = line.split(":");
          let part = parts[1].trim();
          this.partIds.push(part);
        }
      }

      // 获取 CPU 拓扑信息（sysfs，跨架构）
      let topo: CpuTopologyInfo = testNapi.cpuTopology() as CpuTopologyInfo;
      this.hasSmt = topo.hasSmt;
      this.numPhysicalCores = topo.numPhysicalCores;
      this.coreTopology = topo.cores;

      // 使用 sysfs 拓扑检测到的核心数（x86 兼容）
      if (topo.numLogicalCores > 0) {
        this.numCores = topo.numLogicalCores;
      } else {
        this.numCores = this.partIds.length;
      }

      this.log += "检测到 " + this.numCores + " 个逻辑核心";
      if (this.hasSmt) {
        this.log += " (" + this.numPhysicalCores + " 物理核心, SMT)";
      }
      this.log += "\n";
      let c = 0;
      for (let partId of this.partIds) {
        this.log += "核心 " + c + ": Part ID " + partId + "\n";
        c += 1;
      }

      // 锁核诊断
      try {
        this.pinDiagResult = testNapi.pinDiag(this.core) as string;
        this.log += "\n--- 锁核诊断 ---\n" + this.pinDiagResult + "\n";
      } catch (e) {
        this.log += "锁核诊断失败\n";
      }

      // 获取有效 cpuset（cgroup 限制后可用的核心）
      try {
        this.effectiveCpuset = testNapi.getEffectiveCpuset() as number[];
        if (this.effectiveCpuset.length > 0 && this.effectiveCpuset.length < this.numCores) {
          this.log += "cpuset 可用核心: " + this.effectiveCpuset.join(", ") +
            " (" + this.effectiveCpuset.length + "/" + this.numCores + ")\n";
        }
      } catch (e) {
        this.log += "获取 cpuset 失败\n";
      }
      if (this.hasSmt) {
        // 输出 SMT 拓扑映射
        let physMap = new Map<string, number[]>();
        for (let tc of this.coreTopology) {
          let key = tc.packageId + "_" + tc.coreId;
          let arr = physMap.get(key);
          if (arr === undefined) {
            physMap.set(key, [tc.logicalId]);
          } else {
            arr.push(tc.logicalId);
          }
        }
        physMap.forEach((logicals: number[], key: string) => {
          if (logicals.length > 1) {
            this.log += "物理核心 " + key + " → 逻辑核心 " + logicals.join(", ") + "\n";
          }
        });
      }
    }

    // 恢复频率轮询（首次进入或从后台回来）
    this.pageVisible = true;
    if (this.freqTimerHandle < 0) {
      // 首次启动延迟 3 秒，等待 taskpool worker VM 完成初始化；
      // 从后台恢复时无需延迟
      let delay = this.numCores > 0 && this.liveFreqs.length > 0 ? 0 : 3000;
      this.freqTimerHandle = setTimeout(() => {
        this.scheduleNextPoll();
      }, delay);
    }
  }

  onPageHide() {
    // 标记页面不可见，阻止后续 taskpool 调用
    this.pageVisible = false;
    // 停止频率轮询，避免后台 native 调用崩溃
    if (this.freqTimerHandle >= 0) {
      clearTimeout(this.freqTimerHandle);
      this.freqTimerHandle = -1;
    }
    // 注意：不要清除 timerHandle（基准计时器），后台运行时仍需计时
  }

  // 安全区域初始化（传统回调方式，兼容 API 9+，替代 @Env API 23）
  private async initAvoidArea(): Promise<void> {
    try {
      let mainWin = await window.getLastWindow(getContext(this));
      this.mainWindow = mainWin;
      let statusArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let navArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.topSafeHeight = px2vp(statusArea.topRect.height);
      this.bottomSafeHeight = px2vp(navArea.bottomRect.height);
      mainWin.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          this.topSafeHeight = px2vp(data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          this.bottomSafeHeight = px2vp(data.area.bottomRect.height);
        }
      });
    } catch (err) {
      hilog.error(0x0000, 'mainTag', 'Avoid area init failed: %{public}s', JSON.stringify(err));
    }
  }

  // ============================================================
  // 配置持久化
  // ============================================================
  async saveConfig(): Promise<void> {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: 'benchmark_config' });
      pref.putSync('selectedInt', JSON.stringify(this.selectedInt));
      pref.putSync('selectedFp', JSON.stringify(this.selectedFp));
      pref.putSync('core', this.core);
      await pref.flush();
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'saveConfig failed: %{public}s', String(err));
    }
  }

  loadConfig(): void {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: 'benchmark_config' });
      let intStr = pref.getSync('selectedInt', '') as string;
      let fpStr = pref.getSync('selectedFp', '') as string;
      if (intStr.length > 0) {
        let arr = JSON.parse(intStr) as boolean[];
        if (arr.length === int_rate.length) {
          this.selectedInt = arr;
          this.selectAllInt = arr.every((v: boolean): boolean => v);
        }
      }
      if (fpStr.length > 0) {
        let arr = JSON.parse(fpStr) as boolean[];
        if (arr.length === fp_rate.length) {
          this.selectedFp = arr;
          this.selectAllFp = arr.every((v: boolean): boolean => v);
        }
      }
      let savedCore = pref.getSync('core', -1) as number;
      if (savedCore >= 0) {
        this.core = savedCore;
      }
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'loadConfig failed: %{public}s', String(err));
    }
  }

  // ============================================================
  // 测试记录存档
  // ============================================================
  async saveTestRecord(): Promise<void> {
    let now = new Date();
    let ts = now.getFullYear() + '-' +
      String(now.getMonth() + 1).padStart(2, '0') + '-' +
      String(now.getDate()).padStart(2, '0') + ' ' +
      String(now.getHours()).padStart(2, '0') + ':' +
      String(now.getMinutes()).padStart(2, '0') + ':' +
      String(now.getSeconds()).padStart(2, '0');
    let totalEnergy = 0;
    for (let r of this.results) {
      if (r.energyJ > 0) totalEnergy += r.energyJ;
    }
    let record: TestRecord = {
      id: Date.now(),
      timestamp: ts,
      device: deviceInfo.marketName,
      core: this.core,
      suiteLabel: this.suiteLabel,
      specRateScore: this.specRateScore,
      specIntScore: this.specIntScore,
      specFpScore: this.specFpScore,
      totalEnergyJ: totalEnergy,
      results: this.results,
    };
    this.testRecords = [record, ...this.testRecords];
    // 只保留最近 50 条记录
    if (this.testRecords.length > 50) {
      this.testRecords = this.testRecords.slice(0, 50);
    }
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: 'benchmark_config' });
      pref.putSync('testRecords', JSON.stringify(this.testRecords));
      await pref.flush();
      hilog.info(0x0000, 'mainTag', 'Test record saved, total %{public}d records', this.testRecords.length);
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'saveTestRecord failed: %{public}s', String(err));
    }
  }

  loadTestRecords(): void {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: 'benchmark_config' });
      let recordsStr = pref.getSync('testRecords', '') as string;
      if (recordsStr.length > 0) {
        this.testRecords = JSON.parse(recordsStr) as TestRecord[];
      }
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'loadTestRecords failed: %{public}s', String(err));
    }
  }

  async deleteTestRecord(id: number): Promise<void> {
    this.testRecords = this.testRecords.filter((r: TestRecord) => r.id !== id);
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: 'benchmark_config' });
      pref.putSync('testRecords', JSON.stringify(this.testRecords));
      await pref.flush();
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'deleteTestRecord failed: %{public}s', String(err));
    }
  }

  // ============================================================
  // 手动终止测试
  // ============================================================
  stopBenchmarks(): void {
    if (!this.running) return;
    this.stopRequested = true;
    this.log += "用户请求终止测试...\n";
    hilog.info(0x0000, 'mainTag', 'User requested benchmark stop');
    // 立即杀死正在运行的 benchmark 子进程
    try {
      let killed: boolean = testNapi.cancelBenchmark();
      if (killed) {
        this.log += "已发送终止信号\n";
        hilog.info(0x0000, 'mainTag', 'Benchmark child process killed');
      }
    } catch (e) {
      hilog.warn(0x0000, 'mainTag', 'cancelBenchmark failed: %{public}s', String(e));
    }
  }

  // ============================================================
  // 信息页数据加载
  // ============================================================
  loadDeviceInfo(): void {
    if (this.infoLoaded) return;
    this.infoLoaded = true;

    // ---- 系统信息 ----
    try {
      let osName: string = deviceInfo.osFullName;
      this.sysOsVersion = osName ? osName : '未知';
      hilog.info(0x0000, 'mainTag', 'deviceInfo.osFullName=%{public}s', osName);
    } catch (e) {
      this.sysOsVersion = '未知';
      hilog.warn(0x0000, 'mainTag', 'osFullName error: %{public}s', String(e));
    }

    try {
      let api: number = deviceInfo.sdkApiVersion;
      this.sysApiLevel = api > 0 ? api.toString() : '未知';
    } catch (e) { this.sysApiLevel = '未知'; }

    try {
      let bt: string = deviceInfo.buildTime;
      if (bt && bt.length > 0) {
        let ts = Number(bt);
        if (!isNaN(ts) && ts > 0) {
          let d = new Date(ts);
          this.sysBuildTime = d.getFullYear() + '-' +
            String(d.getMonth() + 1).padStart(2, '0') + '-' +
            String(d.getDate()).padStart(2, '0') + ' ' +
            String(d.getHours()).padStart(2, '0') + ':' +
            String(d.getMinutes()).padStart(2, '0') + ':' +
            String(d.getSeconds()).padStart(2, '0');
        } else {
          this.sysBuildTime = bt;
        }
      } else {
        this.sysBuildTime = '未知';
      }
    } catch (e) { this.sysBuildTime = '未知'; }

    try {
      let btype: string = deviceInfo.buildType;
      this.sysBuildType = btype ? btype : '未知';
    } catch (e) { this.sysBuildType = '未知'; }

    try {
      let vid: string = deviceInfo.versionId;
      this.sysVersionId = vid ? vid : '未知';
    } catch (e) { this.sysVersionId = '未知'; }

    try {
      let sp: string = deviceInfo.securityPatchTag;
      this.sysSecurityPatch = sp ? sp : '未知';
    } catch (e) { this.sysSecurityPatch = '未知'; }

    // 内核版本 + 开机时长 - 优先使用 native uname/clock_gettime
    try {
      let ki = testNapi.kernelInfo() as Record<string, Object>;
      if (ki['kernel']) {
        let kernelStr = ki['kernel'] as string;
        let hashIdx = kernelStr.indexOf('#');
        if (hashIdx >= 0) {
          this.sysKernel = kernelStr.substring(0, hashIdx).trim();
          this.sysKernelBuild = kernelStr.substring(hashIdx);
        } else {
          this.sysKernel = kernelStr;
        }
      }
      if (ki['uptimeSeconds']) {
        let secs = Math.floor(ki['uptimeSeconds'] as number);
        let d = Math.floor(secs / 86400);
        let h = Math.floor((secs % 86400) / 3600);
        let m = Math.floor((secs % 3600) / 60);
        let s = secs % 60;
        if (d > 0) {
          this.sysUptime = d + '天 ' + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        } else {
          this.sysUptime = h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        }
      }
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'kernelInfo native failed: %{public}s', String(err));
    }

    // 回退：从 /proc 读取（如果 native 未获取到）
    if (this.sysKernel.length === 0 || this.sysKernel === '未知') {
      try {
        let f = fs.openSync('/proc/version', fs.OpenMode.READ_ONLY);
        let buf = new ArrayBuffer(512);
        let len = fs.readSync(f.fd, buf);
        fs.closeSync(f);
        let raw = String.fromCharCode(...new Uint8Array(buf.slice(0, len)));
        let firstLine = raw.split('\n')[0];
        let hashIdx = firstLine.indexOf('#');
        if (hashIdx >= 0) {
          this.sysKernel = firstLine.substring(0, hashIdx).trim();
          this.sysKernelBuild = firstLine.substring(hashIdx);
        } else {
          this.sysKernel = firstLine;
        }
      } catch (err) {
        if (this.sysKernel.length === 0) this.sysKernel = '未知';
      }
    }

    if (this.sysUptime.length === 0 || this.sysUptime === '未知') {
      try {
        let f = fs.openSync('/proc/uptime', fs.OpenMode.READ_ONLY);
        let buf = new ArrayBuffer(128);
        let len = fs.readSync(f.fd, buf);
        fs.closeSync(f);
        let raw = String.fromCharCode(...new Uint8Array(buf.slice(0, len)));
        let secs = Math.floor(parseFloat(raw.split(' ')[0]));
        let d = Math.floor(secs / 86400);
        let h = Math.floor((secs % 86400) / 3600);
        let m = Math.floor((secs % 3600) / 60);
        let s = secs % 60;
        if (d > 0) {
          this.sysUptime = d + '天 ' + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        } else {
          this.sysUptime = h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        }
      } catch (err) {
        if (this.sysUptime.length === 0) this.sysUptime = '未知';
      }
    }

    // ---- 存储信息 ----
    // RAM 从 /proc/meminfo
    try {
      let f = fs.openSync('/proc/meminfo', fs.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(4096);
      let len = fs.readSync(f.fd, buf);
      fs.closeSync(f);
      let raw = String.fromCharCode(...new Uint8Array(buf.slice(0, len)));
      let lines = raw.split('\n');
      let memMap: Map<string, number> = new Map();
      for (let line of lines) {
        let parts = line.split(':');
        if (parts.length >= 2) {
          let key = parts[0].trim();
          let valStr = parts[1].trim().split(' ')[0];
          memMap.set(key, parseInt(valStr) || 0);
        }
      }
      let totalKB = memMap.get('MemTotal') || 0;
      let freeKB = memMap.get('MemAvailable') || memMap.get('MemFree') || 0;
      let usedKB = totalKB - freeKB;
      this.ramTotal = (totalKB / 1024 / 1024).toFixed(2) + ' GB';
      this.ramUsed = (usedKB / 1024 / 1024).toFixed(2) + ' GB';
      this.ramPercent = totalKB > 0 ? Math.round(usedKB * 100 / totalKB) : 0;

      let swapTotalKB = memMap.get('SwapTotal') || 0;
      let swapFreeKB = memMap.get('SwapFree') || 0;
      let swapUsedKB = swapTotalKB - swapFreeKB;
      this.swapTotal = (swapTotalKB / 1024 / 1024).toFixed(2) + ' GB';
      this.swapUsed = (swapUsedKB / 1024 / 1024).toFixed(2) + ' GB';
      this.swapPercent = swapTotalKB > 0 ? Math.round(swapUsedKB * 100 / swapTotalKB) : 0;
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'Failed to read meminfo: %{public}s', String(err));
    }

    // 内置存储
    try {
      let total = storageStatistics.getTotalSizeSync();
      let free = storageStatistics.getFreeSizeSync();
      let used = total - free;
      this.storageTotal = (total / 1024 / 1024 / 1024).toFixed(2) + ' GB';
      this.storageUsed = (used / 1024 / 1024 / 1024).toFixed(2) + ' GB';
      this.storagePercent = total > 0 ? Math.round(Number(used) * 100 / Number(total)) : 0;
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'Failed to get storage stats: %{public}s', String(err));
    }

    // ---- 电池信息 ----
    try {
      this.battLevel = batteryInfo.batterySOC;
    } catch (e) { this.battLevel = 0; }

    try {
      let v: number = batteryInfo.voltage;
      hilog.info(0x0000, 'mainTag', 'batteryInfo.voltage=%{public}d chargingStatus=%{public}d healthStatus=%{public}d pluggedType=%{public}d temp=%{public}d tech=%{public}s',
        v, batteryInfo.chargingStatus, batteryInfo.healthStatus, batteryInfo.pluggedType, batteryInfo.batteryTemperature, batteryInfo.technology);
      this.battVoltage = v > 0 ? (v / 1000000).toFixed(2) + ' V' : '未知';
    } catch (e) {
      this.battVoltage = '未知';
      hilog.warn(0x0000, 'mainTag', 'batteryInfo.voltage error: %{public}s', String(e));
    }

    try {
      let t: number = batteryInfo.batteryTemperature;
      this.battTemp = (t / 10).toFixed(1) + ' \u2103';
    } catch (e) { this.battTemp = '未知'; }

    try {
      let tech: string = batteryInfo.technology;
      this.battTech = tech ? tech : '未知';
    } catch (e) { this.battTech = '未知'; }

    try {
      let cs: batteryInfo.BatteryChargeState = batteryInfo.chargingStatus;
      if (cs === batteryInfo.BatteryChargeState.ENABLE) {
        this.battStatus = '充电中';
      } else if (cs === batteryInfo.BatteryChargeState.DISABLE) {
        this.battStatus = '放电中';
      } else if (cs === batteryInfo.BatteryChargeState.FULL) {
        this.battStatus = '已充满';
      } else {
        this.battStatus = '未知';
      }
    } catch (e) { this.battStatus = '未知'; }

    try {
      let hs: batteryInfo.BatteryHealthState = batteryInfo.healthStatus;
      if (hs === batteryInfo.BatteryHealthState.GOOD) {
        this.battHealth = '良好';
      } else if (hs === batteryInfo.BatteryHealthState.OVERHEAT) {
        this.battHealth = '过热';
      } else if (hs === batteryInfo.BatteryHealthState.OVERVOLTAGE) {
        this.battHealth = '过压';
      } else if (hs === batteryInfo.BatteryHealthState.COLD) {
        this.battHealth = '低温';
      } else if (hs === batteryInfo.BatteryHealthState.DEAD) {
        this.battHealth = '损坏';
      } else {
        this.battHealth = '未知';
      }
    } catch (e) { this.battHealth = '未知'; }

    try {
      let pt: batteryInfo.BatteryPluggedType = batteryInfo.pluggedType;
      if (pt === batteryInfo.BatteryPluggedType.AC) {
        this.battPlugType = 'AC';
      } else if (pt === batteryInfo.BatteryPluggedType.USB) {
        this.battPlugType = 'USB';
      } else if (pt === batteryInfo.BatteryPluggedType.WIRELESS) {
        this.battPlugType = '无线';
      } else {
        this.battPlugType = '无';
      }
    } catch (e) { this.battPlugType = '未知'; }

    // ---- 屏幕信息 ----
    try {
      let d: display.Display = display.getDefaultDisplaySync();

      hilog.info(0x0000, 'mainTag', 'Display: id=%{public}d w=%{public}d h=%{public}d dpi=%{public}d xdpi=%{public}f ydpi=%{public}f refresh=%{public}f rotation=%{public}d',
        d.id, d.width, d.height, d.densityDPI, d.xDPI, d.yDPI, d.refreshRate, d.rotation);

      this.screenWidth = d.width;
      this.screenHeight = d.height;
      this.screenDensity = d.densityDPI;
      this.screenXDpi = Math.round(d.xDPI);
      this.screenYDpi = Math.round(d.yDPI);
      this.screenRefreshRate = Math.round(d.refreshRate);
      this.screenRotation = d.rotation;

      // 如果默认屏幕返回 0，尝试异步获取物理分辨率
      if (d.width === 0) {
        display.getAllDisplayPhysicalResolution().then((res: display.DisplayPhysicalResolution[]) => {
          if (res.length > 0) {
            this.screenWidth = res[0].physicalWidth;
            this.screenHeight = res[0].physicalHeight;
            hilog.info(0x0000, 'mainTag', 'Physical display: w=%{public}d h=%{public}d', res[0].physicalWidth, res[0].physicalHeight);
          }
        }).catch((err: Error): void => {
          hilog.warn(0x0000, 'mainTag', 'getAllDisplayPhysicalResolution failed: %{public}s', String(err));
        });
      }

      // 支持的刷新率
      try {
        if (d.supportedRefreshRates && d.supportedRefreshRates.length > 0) {
          this.screenRefreshRates = d.supportedRefreshRates.map((r: number): string => Math.round(r) + ' Hz').join(', ');
        }
      } catch (e) {
        hilog.warn(0x0000, 'mainTag', 'supportedRefreshRates failed: %{public}s', String(e));
      }

      // HDR格式
      try {
        if (d.hdrFormats && d.hdrFormats.length > 0) {
          this.screenHdr = d.hdrFormats.map((f: number): string => String(f)).join(', ');
        }
      } catch (e) {
        hilog.warn(0x0000, 'mainTag', 'hdrFormats failed: %{public}s', String(e));
      }

      // 色域
      try {
        if (d.colorSpaces && d.colorSpaces.length > 0) {
          this.screenColorSpaces = d.colorSpaces.map((c: number): string => String(c)).join(', ');
        }
      } catch (e) {
        hilog.warn(0x0000, 'mainTag', 'colorSpaces failed: %{public}s', String(e));
      }

      // 物理尺寸
      if (d.xDPI > 0 && d.yDPI > 0) {
        let wInch: number = d.width / d.xDPI;
        let hInch: number = d.height / d.yDPI;
        let diag: number = Math.sqrt(wInch * wInch + hInch * hInch);
        this.screenPhysSize = diag.toFixed(2) + ' 英寸';
      }
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'Failed to get display info: %{public}s', String(err));
    }

    // ---- 传感器列表 ----
    try {
      let list = sensor.getSensorListSync();
      let items: SensorItem[] = [];
      for (let s of list) {
        items.push({
          name: s.sensorName || '未知',
          vendor: s.vendorName || '未知',
          power: (s.power || 0).toFixed(2)
        });
      }
      this.sensorList = items;
    } catch (err) {
      hilog.warn(0x0000, 'mainTag', 'Failed to get sensor list: %{public}s', String(err));
    }
  }

  // 调度下一次频率采样（setTimeout 链式调用，确保上一次完成后再发起下一次）
  scheduleNextPoll() {
    // 页面不可见时停止链式调用
    if (!this.pageVisible) return;
    this.pollFrequencies();
  }

  // 完成一次采样后的清理与调度
  private pollDone() {
    this.freqPolling = false;
    if (this.pageVisible) {
      this.freqTimerHandle = setTimeout((): void => this.scheduleNextPoll(), 1000);
    }
  }

  // 执行一次频率采样，完成后调度下一次
  pollFrequencies() {
    if (this.numCores <= 0 || !this.pageVisible) {
      this.freqTimerHandle = setTimeout((): void => this.scheduleNextPoll(), 1000);
      return;
    }
    // 运行测试时不读取频率，避免与 benchmark worker 竞争
    if (this.running) {
      this.freqTimerHandle = setTimeout((): void => this.scheduleNextPoll(), 1000);
      return;
    }
    // 防止重入（上一次尚未完成）
    if (this.freqPolling) {
      this.freqTimerHandle = setTimeout((): void => this.scheduleNextPoll(), 1000);
      return;
    }

    this.freqPolling = true;
    let task: taskpool.Task = new taskpool.Task(findCoreFreq, this.numCores);
    taskpool.execute(task).then((result: Object) => {
      if (this.pageVisible) {
        this.liveFreqs = result as number[];
      }
      this.pollDone();
    }).catch((err: Error) => {
      hilog.warn(0x0000, 'mainTag', 'pollFrequencies failed: %{public}s', String(err));
      this.pollDone();
    });
  }

  // 判断逻辑核心是否为其物理核心组的主线程（最小编号）
  isSmtPrimary(coreIdx: number): boolean {
    if (!this.hasSmt) return true;
    let tc = this.coreTopology.find((c: TopologyCore) => c.logicalId === coreIdx);
    if (tc === undefined) return true;
    for (let s of tc.siblings) {
      if (s < coreIdx) return false;
    }
    return true;
  }

  // 获取逻辑核心的 SMT 兄弟列表（不含自身）
  getSmtSiblings(coreIdx: number): number[] {
    let tc = this.coreTopology.find((c: TopologyCore) => c.logicalId === coreIdx);
    if (tc === undefined) return [];
    return tc.siblings.filter((s: number) => s !== coreIdx);
  }

  // 获取逻辑核心所属的物理核心 ID
  getPhysicalCoreId(coreIdx: number): number {
    let tc = this.coreTopology.find((c: TopologyCore) => c.logicalId === coreIdx);
    if (tc === undefined) return coreIdx;
    return tc.coreId;
  }

  // 获取核心类型 [名称, 进度条颜色, 徽章背景色, 徽章文字色]
  getCoreType(coreIdx: number): string[] {
    // SMT 兄弟标记
    if (this.hasSmt && !this.isSmtPrimary(coreIdx)) {
      return ['HT', '#7B1FA2', '#F3E5F5', '#7B1FA2'];
    }
    // ARM big.LITTLE 分类
    if (this.partIds.length > 0 && coreIdx < this.partIds.length) {
      let uniqueIds: string[] = [];
      for (let id of this.partIds) {
        if (!uniqueIds.includes(id)) uniqueIds.push(id);
      }
      let partId = this.partIds[coreIdx];
      let groupIdx = uniqueIds.indexOf(partId);

      if (uniqueIds.length >= 3) {
        if (groupIdx === 0) return ['小核', '#9E9E9E', '#F0F0F0', '#757575'];
        if (groupIdx === uniqueIds.length - 1) return ['超大核', '#F44336', '#FFEBEE', '#F44336'];
        return ['大核', '#FF9800', '#FFF3E0', '#FF9800'];
      }
      if (uniqueIds.length === 2) {
        return groupIdx === 0
          ? ['小核', '#9E9E9E', '#F0F0F0', '#757575']
          : ['大核', '#FF9800', '#FFF3E0', '#FF9800'];
      }
    }
    return ['核心', '#9E9E9E', '#F0F0F0', '#757575'];
  }

  getFreqMHz(coreIdx: number): number {
    if (this.liveFreqs.length <= coreIdx) return 0;
    return Math.round(this.liveFreqs[coreIdx] * 1000);
  }

  // 判断核心是否在 cpuset 可用范围内
  isCoreInCpuset(coreIdx: number): boolean {
    if (this.effectiveCpuset.length === 0) return true; // 未检测到限制
    return this.effectiveCpuset.includes(coreIdx);
  }

  getTotalEnergyJ(): number {
    let total = 0;
    for (let r of this.results) {
      if (r.energyJ > 0) total += r.energyJ;
    }
    return total;
  }

  startPowerSampling(): void {
    this.powerSamples = [];
    this.powerSampleTimer = setInterval(() => {
      try {
        let voltage: number = batteryInfo.voltage;       // 微伏 μV
        let current: number = batteryInfo.nowCurrent;     // 毫安 mA
        // 放电时 current 通常为负值，取绝对值
        // P(W) = V(μV) × I(mA) / 10^9
        let powerW: number = Math.abs(voltage * current) / 1e9;
        if (powerW > 0 && powerW < 100) {  // 过滤异常值（合理范围 0~100W）
          this.powerSamples.push(powerW);
        }
      } catch (_e) { /* ignore */ }
    }, 1000);  // 每秒采样一次
  }

  stopPowerSampling(): number[] {
    if (this.powerSampleTimer >= 0) {
      clearInterval(this.powerSampleTimer);
      this.powerSampleTimer = -1;
    }
    let samples = this.powerSamples;
    this.powerSamples = [];
    return samples;
  }

  calcPowerStats(samples: number[]): PowerStats {
    if (samples.length === 0) {
      let empty: PowerStats = { avgPowerW: 0, energyJ: 0 };
      return empty;
    }
    let sum = 0;
    for (let p of samples) {
      sum += p;
    }
    let avgW = sum / samples.length;
    // 每个样本间隔1秒，功率(W) × 1秒 = 焦耳(J)，总能耗 = sum
    let stats: PowerStats = { avgPowerW: avgW, energyJ: sum };
    return stats;
  }

  getFreqRatio(coreIdx: number): number {
    if (this.liveFreqs.length <= coreIdx) return 0;
    let maxFreq: number = 4.0;
    for (let f of this.liveFreqs) {
      if (f > maxFreq) maxFreq = f;
    }
    return this.liveFreqs[coreIdx] / maxFreq * 100;
  }

  // 构建选中的基准列表
  getSelectedFilter(): string[] {
    let filter: string[] = [];
    for (let i = 0; i < int_rate.length; i++) {
      if (this.selectedInt[i]) filter.push(int_rate[i]);
    }
    for (let i = 0; i < fp_rate.length; i++) {
      if (this.selectedFp[i]) filter.push(fp_rate[i]);
    }
    return filter;
  }

  // 格式化结果用于复制
  formatResultsText(): string {
    let lines: string[] = [];
    lines.push("SPEC CPU 2017 基准测试结果");
    lines.push("设备: " + deviceInfo.marketName);
    // 拓扑信息
    let coreLabel = "逻辑核心 " + this.core;
    if (this.coreTopology.length > 0) {
      coreLabel += " (物理核心 " + this.getPhysicalCoreId(this.core) + ")";
    }
    if (this.partIds.length > this.core) {
      coreLabel += " Part ID: " + this.partIds[this.core];
    }
    lines.push("核心: " + coreLabel);
    if (this.hasSmt) {
      lines.push("超线程: 是 (" + this.numPhysicalCores + " 物理 / " + this.numCores + " 逻辑)");
      let siblings = this.getSmtSiblings(this.core);
      if (siblings.length > 0) {
        lines.push("SMT 兄弟: " + siblings.join(", "));
      }
    } else {
      lines.push("超线程: 否 (" + this.numCores + " 核)");
    }
    if (this.coreFreqs.length > this.core) {
      lines.push("频率: " + this.coreFreqs[this.core].toFixed(2) + " GHz");
    }
    lines.push(testNapi.info());
    lines.push("=".repeat(70));
    for (let r of this.results) {
      let timeStr = r.totalTime >= 1000 ? Math.round(r.totalTime).toString() : r.totalTime.toPrecision(3);
      let powerStr = r.avgPowerW > 0 ? (" " + r.avgPowerW.toFixed(2) + "W " + r.energyJ.toFixed(1) + "J") : "";
      lines.push(r.benchmark + " 1 " + timeStr + " " + r.ratio.toPrecision(3) + " " + (r.passed ? "*" : "X") + powerStr);
    }
    lines.push("=".repeat(70));
    let passedCount = this.results.filter(r => r.passed).length;
    lines.push("Est. SPECrate(R)2017_" + this.suiteLabel + "_base " + this.specRateScore.toPrecision(3));
    if (this.specIntScore > 0) {
      lines.push("Est. SPECrate(R)2017_int_base " + this.specIntScore.toPrecision(3));
    }
    if (this.specFpScore > 0) {
      lines.push("Est. SPECrate(R)2017_fp_base " + this.specFpScore.toPrecision(3));
    }
    lines.push("通过: " + passedCount + "/" + this.results.length);
    return lines.join("\n");
  }

  async runBenchmarks(filter: string[]) {
    if (this.running) {
      promptAction.showToast({ message: '测试正在运行中', duration: 2000 });
      return;
    }
    if (filter.length === 0) {
      promptAction.showToast({ message: '请至少选择一项测试', duration: 2000 });
      return;
    }
    this.running = true;
    this.stopRequested = false;
    this.results = [];
    this.totalBenchCount = filter.length;
    this.currentBenchIndex = 0;
    this.specRateScore = 0;
    this.specIntScore = 0;
    this.specFpScore = 0;
    this.elapsedTime = 0;
    this.startTimestamp = Date.now();
    this.currentTabIndex = 1;

    // 确定套件标签
    let hasInt = filter.some(b => int_rate.includes(b));
    let hasFp = filter.some(b => fp_rate.includes(b));
    this.suiteLabel = (hasInt && hasFp) ? "int_fp" : hasInt ? "int" : "fp";

    // 计时器
    this.timerHandle = setInterval(() => {
      this.elapsedTime = Math.floor((Date.now() - this.startTimestamp) / 1000);
    }, 1000);

    // 申请后台长时任务，防止切后台被杀
    try {
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'je.jia.speccpu2017harmony',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      let agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(getContext(this),
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      hilog.info(0x0000, 'mainTag', 'Background running started successfully');
    } catch (bgErr) {
      hilog.error(0x0000, 'mainTag', 'Failed to start background running: %{public}s',
        JSON.stringify(bgErr) ?? '');
    }

    try {
      this.log += testNapi.info() + "\n";
      let context = getContext(this);
      let benchmarks = getBenchmarkConfigs();

      let core = this.core;
      let coreInfo = "使用逻辑核心 " + core;
      if (this.coreTopology.length > 0) {
        coreInfo += " (物理核心 " + this.getPhysicalCoreId(core) + ")";
      }
      if (this.partIds.length > core) {
        coreInfo += " Part ID: " + this.partIds[core];
      }
      this.log += coreInfo + "\n";
      if (this.hasSmt) {
        let siblings = this.getSmtSiblings(core);
        this.log += "SMT 拓扑: " + this.numPhysicalCores + " 物理 / " + this.numCores + " 逻辑\n";
        if (siblings.length > 0) {
          this.log += "SMT 兄弟核心: " + siblings.join(", ") + "\n";
        }
        if (!this.isSmtPrimary(core)) {
          this.log += "警告: 当前选择的是 SMT 兄弟线程，建议选择物理核心主线程以获得更稳定的结果\n";
        }
      }

      let failed: boolean = false;
      let benchIndex: number = 0;
      for (let benchmark of filter) {
        // 大项间隔 1 分钟（第二项起）
        if (benchIndex > 0 && !this.stopRequested) {
          this.log += "等待 60 秒冷却...\n";
          this.currentBenchName = "冷却中...";
          for (let wait = 0; wait < 60; wait++) {
            if (this.stopRequested) break;
            await new Promise<void>((resolve) => setTimeout(resolve, 1000));
          }
          if (this.stopRequested) {
            this.log += "用户终止测试\n";
            break;
          }
          this.log += "冷却完成\n";
        }
        benchIndex++;

        // 启动功率采样
        this.startPowerSampling();

        // 检查用户是否请求终止
        if (this.stopRequested) {
          this.log += "用户终止测试\n";
          break;
        }
        this.currentBenchName = benchmark;
        this.currentSubIndex = 0;
        this.currentSubTotal = benchmarks.get(benchmark)!.length;

        this.log += "运行 " + benchmark + "\n";
        hilog.info(0x0000, 'mainTag', 'Extracting files for %{public}s', benchmark);
        let filesDir = context.filesDir + "/" + benchmark;
        if (!await fs.access(filesDir)) {
          await fs.mkdir(filesDir);
        }

        // 缓存解压
        let extractedMarker = filesDir + "/.extracted";
        if (await fs.access(extractedMarker)) {
          this.log += "使用缓存数据: " + benchmark + "\n";
          hilog.info(0x0000, 'mainTag', 'Using cached data for %{public}s', benchmark);
        } else {
          let value = await context.resourceManager.getRawFileContent(benchmark + ".zip");
          let filePath = filesDir + "/" + benchmark + ".zip";
          let file = await fs.open(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          await fs.write(file.fd, value.buffer);
          await fs.close(file);
          let options: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
          await zlib.decompressFile(filePath, filesDir, options);
          let marker = await fs.open(extractedMarker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
          await fs.close(marker);
        }

        let inputDir = filesDir + "/input";
        let outputDir = filesDir + "/output";

        if (benchmark === "525.x264_r") {
          hilog.info(0x0000, 'mainTag', 'Generating BuckBunny.yuv');
          this.log += '生成 BuckBunny.yuv (525.x264_r)\n';
          let task: taskpool.Task =
            new taskpool.Task(worker, inputDir, outputDir, "", "ldecod_r", "-i BuckBunny.264 -o BuckBunny.yuv".split(" "),
              core, []);
          await taskpool.execute(task);
        }

        hilog.info(0x0000, 'mainTag', 'Got files under benchmark folder: %{public}s',
          JSON.stringify(fs.listFileSync(filesDir)));
        hilog.info(0x0000, 'mainTag', 'Got files under input folder: %{public}s',
          JSON.stringify(fs.listFileSync(inputDir)));
        hilog.info(0x0000, 'mainTag', 'Got files under output folder: %{public}s',
          JSON.stringify(fs.listFileSync(outputDir)));

        let totalTime: number = 0;
        let index: number = 0;
        for (let b of benchmarks.get(benchmark)!) {
          index += 1;
          this.currentSubIndex = index;
          let arg: string;
          let validates: ValidateConfig[] = [];
          if (typeof b === "string") {
            arg = b;
          } else {
            arg = (b as BenchmarkConfig).args;
            validates = (b as BenchmarkConfig).validates;
          }

          this.log += benchmark + " #" + index + " 参数: " + arg + "\n";
          hilog.info(0x0000, 'mainTag', 'Run benchmark %{public}s #%{public}d with %{public}s', benchmark, index, arg);
          let args = arg.split(" ");
          let stdinFile = "";
          if (args.length >= 2 && args[args.length-2] === "<") {
            stdinFile = args.pop()!;
            args.pop();
          }

          let task: taskpool.Task =
            new taskpool.Task(worker, inputDir, outputDir, stdinFile, benchmark, args, core, validates);
          task.onEnqueued(() => {
            hilog.info(0x0000, 'mainTag', 'Task enqueued: %{public}s #%{public}d', benchmark, index);
          });
          task.onStartExecution(() => {
            hilog.info(0x0000, 'mainTag', 'Task started: %{public}s #%{public}d', benchmark, index);
          });
          task.onExecutionFailed(() => {
            hilog.info(0x0000, 'mainTag', 'Task failed: %{public}s #%{public}d', benchmark, index);
          });
          task.onExecutionSucceeded(() => {
            hilog.info(0x0000, 'mainTag', 'Task succeeded: %{public}s #%{public}d', benchmark, index);
          });
          let time: number = await taskpool.execute(task) as number;

          // 提取子进程的 [PIN] / [PIN-DIAG] 诊断信息（首个子任务时显示）
          if (index === 1) {
            try {
              let stderrPath: string = inputDir + "/stderr.log";
              let stderrContent: string = fs.readTextSync(stderrPath);
              let pinLines: string[] = [];
              let fallbackMsg: string = "";
              for (let line of stderrContent.split('\n')) {
                if (line.startsWith('[PIN]') || line.startsWith('[PIN-DIAG]') || line.startsWith('[PIN-PRE]') || line.startsWith('[PIN-RESULT]') || line.startsWith('[PIN-PARENT]') || line.startsWith('[PIN-FFRT]') || line.startsWith('[PIN-KEEPALIVE]')) {
                  pinLines.push(line);
                }
                // Parse [PIN-RESULT] for fallback detection
                if (line.startsWith('[PIN-RESULT]')) {
                  let targetMatch = line.match(/target=(\d+)/);
                  let effectiveMatch = line.match(/effective=(\d+)/);
                  let pinnedMatch = line.match(/pinned=(\w+)/);
                  if (targetMatch !== null && effectiveMatch !== null) {
                    let target = parseInt(targetMatch[1]);
                    let effective = parseInt(effectiveMatch[1]);
                    let pinStatus = pinnedMatch !== null ? pinnedMatch[1] : 'NO';
                    if (pinStatus === 'YES') {
                      fallbackMsg = "[OK] 已锁定核心 " + effective + "\n";
                    } else if (pinStatus === 'PENDING') {
                      fallbackMsg = "[..] 核心 " + target + " 尚未进入 cpuset，看门狗持续重试中\n" +
                        "当前 cpuset 限制: {" + this.effectiveCpuset.join(",") + "}\n";
                    } else if (target !== effective) {
                      fallbackMsg = "[!!] 核心 " + target + " 不在 cpuset 范围内，已回退到核心 " + effective + "\n" +
                        "当前 cpuset 限制: {" + this.effectiveCpuset.join(",") + "}\n";
                    }
                  }
                }
              }
              if (fallbackMsg.length > 0) {
                this.log += fallbackMsg;
              }
              if (pinLines.length > 0) {
                this.log += "--- 子进程锁核状态 ---\n" + pinLines.join('\n') + "\n---\n";
              } else {
                this.log += "（stderr.log 中无 [PIN] 诊断输出）\n";
              }
            } catch (_e) {
              // stderr.log 可能不存在或读取失败，忽略
            }
          }

          if (time < 0) {
            hilog.info(0x0000, 'mainTag', 'Failed benchmark %{public}s with args %{public}s', benchmark, arg);
            this.log += benchmark + " #" + index + " 失败\n";
            failed = true;
            break;
          }

          hilog.info(0x0000, 'mainTag', 'Finished benchmark %{public}s with args %{public}s in %{public}ss', benchmark,
            arg, time.toString());
          this.log += benchmark + " #" + index + " 完成，耗时 " + time.toFixed(1) + "s\n";

          if (validates.length > 0) {
            this.log += benchmark + " #" + index + " 校验通过\n";
          }
          totalTime += time;

          // 子任务完成后检查终止请求
          if (this.stopRequested) break;
        }

        if (this.stopRequested) break;

        // 停止功率采样，计算功耗
        let samples = this.stopPowerSampling();
        let powerStats = this.calcPowerStats(samples);
        if (powerStats.avgPowerW > 0) {
          this.log += benchmark + " 功耗: 平均 " + powerStats.avgPowerW.toFixed(2) + "W, 能耗 " +
            powerStats.energyJ.toFixed(1) + "J (" + (powerStats.energyJ / 3.6).toFixed(1) + "mWh), " +
            samples.length + " 个采样点\n";
        }

        if (failed) {
          // 记录失败结果
          let newResult: BenchmarkResult = {
            benchmark: benchmark, totalTime: totalTime, ratio: 0, passed: false,
            avgPowerW: powerStats.avgPowerW, energyJ: powerStats.energyJ
          };
          this.results = [...this.results, newResult];
          break;
        }

        let ratio: number = reftime.get(benchmark)! / totalTime;
        this.log += benchmark + " 完成，总耗时 " + totalTime.toFixed(1) + "s，比率 " + ratio.toFixed(3) + "\n";
        hilog.info(0x0000, 'mainTag', 'Finished whole benchmark %{public}s in %{public}ss, ratio is %{public}s',
          benchmark, totalTime.toString(), ratio.toString());

        let newResult: BenchmarkResult = {
          benchmark: benchmark, totalTime: totalTime, ratio: ratio, passed: true,
          avgPowerW: powerStats.avgPowerW, energyJ: powerStats.energyJ
        };
        this.results = [...this.results, newResult];
        this.currentBenchIndex += 1;
      }

      // 计算 SPECrate 几何均值（总分 + INT/FP 分开计算）
      let passedResults = this.results.filter(r => r.passed);
      if (passedResults.length > 0) {
        let geomean = 1.0;
        for (let r of passedResults) {
          geomean *= r.ratio;
        }
        this.specRateScore = Math.pow(geomean, 1.0 / passedResults.length);
      }

      // INT 子分数
      let intResults = passedResults.filter(r => int_rate.includes(r.benchmark));
      if (intResults.length > 0) {
        let geomeanInt = 1.0;
        for (let r of intResults) {
          geomeanInt *= r.ratio;
        }
        this.specIntScore = Math.pow(geomeanInt, 1.0 / intResults.length);
      }

      // FP 子分数
      let fpResults = passedResults.filter(r => fp_rate.includes(r.benchmark));
      if (fpResults.length > 0) {
        let geomeanFp = 1.0;
        for (let r of fpResults) {
          geomeanFp *= r.ratio;
        }
        this.specFpScore = Math.pow(geomeanFp, 1.0 / fpResults.length);
      }

      if (this.stopRequested) {
        this.log += "测试已终止\n";
      } else if (failed) {
        this.log += "因错误中止\n";
      } else {
        // 兼容旧格式日志
        this.log += "测试摘要:\n";
        this.log += "=".repeat(70) + "\n";
        for (let r of this.results) {
          let timeStr = r.totalTime >= 1000 ? Math.round(r.totalTime).toString() : r.totalTime.toPrecision(3);
          let powerStr = r.avgPowerW > 0 ? (" " + r.avgPowerW.toFixed(2) + "W") : "";
          this.log += r.benchmark + " 1 " + timeStr + " " + r.ratio.toPrecision(3) + " *" + powerStr + "\n";
        }
        this.log += "Est. SPECrate(R)2017_" + this.suiteLabel + "_base " + this.specRateScore.toPrecision(3) + "\n";
        if (this.specIntScore > 0) {
          this.log += "Est. SPECrate(R)2017_int_base " + this.specIntScore.toPrecision(3) + "\n";
        }
        if (this.specFpScore > 0) {
          this.log += "Est. SPECrate(R)2017_fp_base " + this.specFpScore.toPrecision(3) + "\n";
        }
        let totalEnergy = 0;
        for (let r of this.results) {
          if (r.energyJ > 0) totalEnergy += r.energyJ;
        }
        if (totalEnergy > 0) {
          let totalTime = 0;
          for (let r of this.results) totalTime += r.totalTime;
          let avgPower = totalTime > 0 ? totalEnergy / totalTime : 0;
          this.log += "总能耗: " + totalEnergy.toFixed(1) + "J (" + (totalEnergy / 3.6).toFixed(1) + "mWh), 平均功率: " + avgPower.toFixed(2) + "W\n";
        }
      }

      // 保存测试记录存档（有结果时都保存，包括部分完成）
      if (this.results.length > 0) {
        await this.saveTestRecord();
      }

      // 自动跳转到结果页
      this.currentTabIndex = 2;

    } catch (err) {
      let errorMsg = 'Unknown error';
      if (err instanceof Error) {
        errorMsg = `${err.name}: ${err.message}${err.stack ? '\nStack: ' + err.stack : ''}`;
      } else if (typeof err === 'object' && err !== null) {
        errorMsg = `Error object: ${JSON.stringify(err, Object.getOwnPropertyNames(err))}`;
      } else {
        errorMsg = String(err);
      }
      hilog.info(0x0000, 'mainTag', 'Got error in runBenchmarks: %{public}s', errorMsg);
      this.log += "异常: " + errorMsg + "\n";
    }
    clearInterval(this.timerHandle);
    this.timerHandle = -1;
    this.running = false;
    this.stopRequested = false;

    // 停止后台长时任务
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
      hilog.info(0x0000, 'mainTag', 'Background running stopped successfully');
    } catch (bgErr) {
      hilog.error(0x0000, 'mainTag', 'Failed to stop background running: %{public}s',
        JSON.stringify(bgErr) ?? '');
    }
  }

  // ============================================================
  // 配置页
  // ============================================================
  @Builder
  ConfigTab() {
    Scroll() {
      Column({ space: 16 }) {
        // ---- 处理器核心卡片 ----
        Column({ space: 12 }) {
          Row() {
            Text("处理器核心")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Blank()
            Text(this.hasSmt
              ? ("已选: 核心 " + this.core + " (物理 " + this.numPhysicalCores + " / 逻辑 " + this.numCores + ")")
              : ("已选: 核心 " + this.core))
              .fontSize(12)
              .fontColor('#1976D2')
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')

          if (this.hasSmt) {
            Row() {
              Text("检测到超线程 (SMT)，标记 HT 的为兄弟线程，建议选择非 HT 核心")
                .fontSize(11)
                .fontColor('#F57C00')
            }
            .width('100%')
            .padding({ left: 4, right: 4 })
          }

          Button(this.findingCore ? "检测中..." : "自动选择最快核心")
            .width('100%')
            .height(36)
            .fontSize(14)
            .type(ButtonType.Capsule)
            .backgroundColor(this.findingCore ? '#BDBDBD' : '#1976D2')
            .fontColor(Color.White)
            .enabled(!this.findingCore && !this.running)
            .onClick(async () => {
              this.findingCore = true;
              this.log += "正在检测各核心频率...\n";
              let task: taskpool.Task = new taskpool.Task(findCoreFreq, this.numCores);
              let freqs: number[] = await taskpool.execute(task) as number[];
              this.coreFreqs = freqs;
              let best = 0;
              let maxFreq = 0;
              // SMT 感知：只从物理核心主线程中选择最快的
              let seenPhys = new Set<string>();
              for (let i = 0; i < this.numCores; i++) {
                let label = "核心 " + i + " 频率: " + freqs[i].toFixed(2) + " GHz";
                if (this.hasSmt && !this.isSmtPrimary(i)) {
                  label += " (HT)";
                }
                this.log += label + "\n";
                // 跳过 SMT 兄弟线程
                if (this.hasSmt) {
                  let tc = this.coreTopology.find((c: TopologyCore) => c.logicalId === i);
                  if (tc !== undefined) {
                    let physKey = tc.packageId + "_" + tc.coreId;
                    if (seenPhys.has(physKey)) continue;
                    seenPhys.add(physKey);
                  }
                }
                if (freqs[i] > maxFreq) {
                  maxFreq = freqs[i];
                  best = i;
                }
              }
              hilog.info(0x0000, 'mainTag', 'Fastest core is %{public}d', best);
              this.log += "最快核心: " + best + " (" + maxFreq.toFixed(2) + " GHz)\n";
              this.core = best;
              this.findingCore = false;
              this.saveConfig();
            })

          // 核心列表
          List({ space: 2 }) {
            ForEach(
              Array.from({ length: this.numCores }, (x: object, i: number) => i),
              (coreIdx: number) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Radio({ value: coreIdx.toString(), group: 'coreGroup' })
                      .checked(this.core === coreIdx)
                      .width(18)
                      .height(18)
                      .onChange((isChecked: boolean) => {
                        if (isChecked) {
                          this.core = coreIdx;
                          this.saveConfig();
                        }
                      })
                    Text("核心 " + coreIdx)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .width(52)
                    if (this.hasSmt) {
                      Text(this.isSmtPrimary(coreIdx) ? "P" + this.getPhysicalCoreId(coreIdx) : "HT")
                        .fontSize(10)
                        .fontColor(this.isSmtPrimary(coreIdx) ? '#1976D2' : '#7B1FA2')
                        .backgroundColor(this.isSmtPrimary(coreIdx) ? '#E3F2FD' : '#F3E5F5')
                        .borderRadius(4)
                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    }
                    Text(this.partIds[coreIdx] ?? "")
                      .fontSize(11)
                      .fontColor('#757575')
                      .layoutWeight(1)
                    if (this.coreFreqs.length > coreIdx) {
                      Text(this.coreFreqs[coreIdx].toFixed(2) + " GHz")
                        .fontSize(11)
                        .fontColor('#1976D2')
                        .fontWeight(FontWeight.Medium)
                    }
                  }
                  .width('100%')
                  .height(40)
                  .padding({ left: 8, right: 8 })
                  .backgroundColor(this.core === coreIdx ? '#E3F2FD' :
                    (this.hasSmt && !this.isSmtPrimary(coreIdx) ? '#FAFAFA' : '#F8F8F8'))
                  .borderRadius(8)
                  .opacity(this.hasSmt && !this.isSmtPrimary(coreIdx) ? 0.7 : 1.0)
                }
              },
              (coreIdx: number) => coreIdx.toString()
            )
          }
          .width('100%')
          .constraintSize({ maxHeight: 280 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 整数测试卡片 ----
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Checkbox({ name: 'intAll' })
              .select(this.selectAllInt)
              .selectedColor('#1976D2')
              .width(20)
              .height(20)
              .onChange((val: boolean) => {
                this.selectAllInt = val;
                this.selectedInt = new Array(10).fill(val) as boolean[];
                this.saveConfig();
              })
            Text("整数测试")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Text("SPECrate2017_int")
              .fontSize(11)
              .fontColor('#9E9E9E')
              .margin({ left: 4 })
            Blank()
            Text(this.selectedInt.filter(v => v).length + "/" + int_rate.length)
              .fontSize(12)
              .fontColor('#1976D2')
          }
          .width('100%')

          ForEach(int_rate, (item: string, index?: number) => {
            Row({ space: 8 }) {
              Checkbox({ name: item })
                .select(this.selectedInt[index!])
                .selectedColor('#1976D2')
                .width(18)
                .height(18)
                .onChange((val: boolean) => {
                  let newArr = [...this.selectedInt];
                  newArr[index!] = val;
                  this.selectedInt = newArr;
                  this.selectAllInt = newArr.every(v => v);
                  this.saveConfig();
                })
              Text(item)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
              Text(benchmarkNames.get(item) ?? "")
                .fontSize(11)
                .fontColor('#757575')
            }
            .width('100%')
            .height(36)
            .padding({ left: 8, right: 4 })
          }, (item: string) => item)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 浮点测试卡片 ----
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Checkbox({ name: 'fpAll' })
              .select(this.selectAllFp)
              .selectedColor('#FF5722')
              .width(20)
              .height(20)
              .onChange((val: boolean) => {
                this.selectAllFp = val;
                this.selectedFp = new Array(13).fill(val) as boolean[];
                this.saveConfig();
              })
            Text("浮点测试")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Text("SPECrate2017_fp")
              .fontSize(11)
              .fontColor('#9E9E9E')
              .margin({ left: 4 })
            Blank()
            Text(this.selectedFp.filter(v => v).length + "/" + fp_rate.length)
              .fontSize(12)
              .fontColor('#FF5722')
          }
          .width('100%')

          ForEach(fp_rate, (item: string, index?: number) => {
            Row({ space: 8 }) {
              Checkbox({ name: item })
                .select(this.selectedFp[index!])
                .selectedColor('#FF5722')
                .width(18)
                .height(18)
                .onChange((val: boolean) => {
                  let newArr = [...this.selectedFp];
                  newArr[index!] = val;
                  this.selectedFp = newArr;
                  this.selectAllFp = newArr.every(v => v);
                  this.saveConfig();
                })
              Text(item)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
              Text(benchmarkNames.get(item) ?? "")
                .fontSize(11)
                .fontColor('#757575')
            }
            .width('100%')
            .height(36)
            .padding({ left: 8, right: 4 })
          }, (item: string) => item)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 100 })
    }
    .backgroundColor('#F2F3F5')
  }

  // ============================================================
  // 运行页
  // ============================================================
  @Builder
  RunTab() {
    Scroll() {
      Column({ space: 16 }) {
        // 开始按钮
        Button(this.running ? "测试运行中..." : "开始测试")
          .width('80%')
          .height(52)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .type(ButtonType.Capsule)
          .backgroundColor(this.running ? '#BDBDBD' : '#1976D2')
          .fontColor(Color.White)
          .enabled(!this.running)
          .margin({ top: 12 })
          .onClick(() => {
            let filter = this.getSelectedFilter();
            this.runBenchmarks(filter);
          })

        // 终止按钮（仅运行中显示）
        if (this.running) {
          Button(this.stopRequested ? "正在终止..." : "终止测试")
            .width('60%')
            .height(40)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .type(ButtonType.Capsule)
            .backgroundColor(this.stopRequested ? '#BDBDBD' : '#F44336')
            .fontColor(Color.White)
            .enabled(!this.stopRequested)
            .onClick((): void => {
              this.stopBenchmarks();
            })
        }

        // 进度区域
        if (this.totalBenchCount > 0) {
          Column({ space: 12 }) {
            // 总进度
            Row({ space: 8 }) {
              Text("总进度")
                .fontSize(14)
                .fontColor('#1A1A1A')
              Blank()
              Text(this.currentBenchIndex + " / " + this.totalBenchCount)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1976D2')
            }
            .width('100%')

            Progress({ value: this.currentBenchIndex, total: Math.max(this.totalBenchCount, 1), type: ProgressType.Linear })
              .width('100%')
              .color('#1976D2')
              .backgroundColor('#E0E0E0')

            // 当前基准
            if (this.running && this.currentBenchName.length > 0) {
              Column({ space: 6 }) {
                Text("当前: " + this.currentBenchName)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#1A1A1A')
                  .width('100%')
                Text(benchmarkNames.get(this.currentBenchName) ?? "")
                  .fontSize(11)
                  .fontColor('#757575')
                  .width('100%')
                Row({ space: 8 }) {
                  Text("子任务")
                    .fontSize(12)
                    .fontColor('#757575')
                  Blank()
                  Text(this.currentSubIndex + " / " + this.currentSubTotal)
                    .fontSize(12)
                    .fontColor('#FF9800')
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')

                Progress({ value: this.currentSubIndex, total: Math.max(this.currentSubTotal, 1), type: ProgressType.Linear })
                  .width('100%')
                  .color('#FF9800')
                  .backgroundColor('#E0E0E0')
              }
              .padding({ top: 4 })
            }

            // 温度 + 时间
            Row() {
              Row({ space: 6 }) {
                Text("温度:")
                  .fontSize(12)
                  .fontColor('#757575')
                Text(this.thermalText)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.thermalColor)
              }
              Blank()
              Text(formatTime(this.elapsedTime))
                .fontSize(12)
                .fontColor('#757575')
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

          // 实时结果列表（已完成的）
          if (this.results.length > 0) {
            Column({ space: 8 }) {
              Text("已完成 (" + this.results.length + ")")
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
                .width('100%')

              ForEach(this.results, (item: BenchmarkResult) => {
                Row({ space: 8 }) {
                  Text(item.passed ? "✓" : "✗")
                    .fontSize(12)
                    .fontColor(item.passed ? '#4CAF50' : '#F44336')
                    .fontWeight(FontWeight.Bold)
                    .width(16)
                  Text(item.benchmark)
                    .fontSize(12)
                    .layoutWeight(1)
                  Text(item.totalTime.toFixed(1) + "s")
                    .fontSize(11)
                    .fontColor('#757575')
                    .width(56)
                  Text(item.passed ? item.ratio.toFixed(2) : "失败")
                    .fontSize(11)
                    .fontColor(item.passed ? '#1976D2' : '#F44336')
                    .fontWeight(FontWeight.Bold)
                    .width(48)
                    .textAlign(TextAlign.End)
                  if (item.avgPowerW > 0) {
                    Text(item.avgPowerW.toFixed(1) + "W")
                      .fontSize(10)
                      .fontColor('#FF5722')
                      .width(40)
                      .textAlign(TextAlign.End)
                  }
                }
                .width('100%')
                .height(32)
              }, (item: BenchmarkResult) => item.benchmark)
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(16)
            .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
          }
        }

        // 日志区域
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text("运行日志")
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1A1A1A')
            Blank()
            Button("复制")
              .fontSize(12)
              .height(28)
              .backgroundColor('#E3F2FD')
              .fontColor('#1976D2')
              .onClick(() => {
                let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.log);
                let sysBoard = pasteboard.getSystemPasteboard();
                sysBoard.setData(pasteData);
                promptAction.showToast({ message: '已复制到剪贴板' });
              })
            Toggle({ type: ToggleType.Switch, isOn: this.logExpanded })
              .width(44)
              .height(24)
              .onChange((isOn: boolean) => {
                this.logExpanded = isOn;
              })
          }
          .width('100%')

          if (this.logExpanded) {
            Scroll() {
              Text(this.log)
                .fontSize(9)
                .fontFamily('monospace')
                .fontColor('#424242')
                .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 360 })
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .padding(8)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 100 })
    }
    .backgroundColor('#F2F3F5')
  }

  // ============================================================
  // 结果页
  // ============================================================
  @Builder
  ResultsTab() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.results.length === 0) {
          // 空状态
          Column({ space: 12 }) {
            Text("暂无结果")
              .fontSize(20)
              .fontColor('#BDBDBD')
            Text("请在配置页选择测试项目后开始测试")
              .fontSize(14)
              .fontColor('#9E9E9E')
          }
          .width('100%')
          .height(300)
          .justifyContent(FlexAlign.Center)
        } else {
          // SPECrate 得分卡片
          Column({ space: 8 }) {
            Gauge({ value: Math.min(this.specRateScore, 30), min: 0, max: 30 })
              .width(180)
              .height(180)
              .colors([[0x4CAF50, 0.33], [0xFF9800, 0.67], [0xF44336, 1.0]])
              .strokeWidth(16)

            Text(this.specRateScore.toFixed(2))
              .fontSize(36)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1976D2')

            Text("SPECrate(R)2017_" + this.suiteLabel + "_base")
              .fontSize(12)
              .fontColor('#9E9E9E')

            // INT / FP 分项得分
            if (this.specIntScore > 0 || this.specFpScore > 0) {
              Row({ space: 24 }) {
                if (this.specIntScore > 0) {
                  Column({ space: 2 }) {
                    Text(this.specIntScore.toFixed(2))
                      .fontSize(20)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#1565C0')
                    Text("INT")
                      .fontSize(11)
                      .fontColor('#9E9E9E')
                  }
                  .alignItems(HorizontalAlign.Center)
                }
                if (this.specFpScore > 0) {
                  Column({ space: 2 }) {
                    Text(this.specFpScore.toFixed(2))
                      .fontSize(20)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#00838F')
                    Text("FP")
                      .fontSize(11)
                      .fontColor('#9E9E9E')
                  }
                  .alignItems(HorizontalAlign.Center)
                }
              }
              .margin({ top: 4 })
            }

            // 统计栏
            Row({ space: 16 }) {
              Column({ space: 2 }) {
                Text(this.results.length.toString())
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                Text("总计")
                  .fontSize(11)
                  .fontColor('#9E9E9E')
              }
              .alignItems(HorizontalAlign.Center)

              Column({ space: 2 }) {
                Text(this.results.filter(r => r.passed).length.toString())
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#4CAF50')
                Text("通过")
                  .fontSize(11)
                  .fontColor('#9E9E9E')
              }
              .alignItems(HorizontalAlign.Center)

              if (this.results.filter(r => !r.passed).length > 0) {
                Column({ space: 2 }) {
                  Text(this.results.filter(r => !r.passed).length.toString())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#F44336')
                  Text("失败")
                    .fontSize(11)
                    .fontColor('#9E9E9E')
                }
                .alignItems(HorizontalAlign.Center)
              }

              // 总能耗
              Column({ space: 2 }) {
                Text(this.getTotalEnergyJ() > 0 ? (this.getTotalEnergyJ().toFixed(0) + "J") : "-")
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FF5722')
                Text("能耗")
                  .fontSize(11)
                  .fontColor('#9E9E9E')
              }
              .alignItems(HorizontalAlign.Center)
            }
            .margin({ top: 8 })
          }
          .width('100%')
          .padding({ top: 20, bottom: 16 })
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
          .alignItems(HorizontalAlign.Center)

          // 各项结果
          Column({ space: 8 }) {
            Text("各项测试结果")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
              .width('100%')

            ForEach(this.results, (item: BenchmarkResult) => {
              Column({ space: 6 }) {
                // 第一行：名称 + 状态
                Row() {
                  Column({ space: 2 }) {
                    Text(item.benchmark)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#1A1A1A')
                    Text(benchmarkNames.get(item.benchmark) ?? "")
                      .fontSize(11)
                      .fontColor('#9E9E9E')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Column({ space: 2 }) {
                    Text(item.passed ? "通过" : "失败")
                      .fontSize(12)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(item.passed ? '#4CAF50' : '#F44336')
                    if (item.passed) {
                      Text(item.ratio.toFixed(3))
                        .fontSize(14)
                        .fontColor('#1976D2')
                        .fontWeight(FontWeight.Bold)
                    }
                  }
                  .alignItems(HorizontalAlign.End)
                }
                .width('100%')

                // 比率可视化 + 时间
                Row({ space: 8 }) {
                  if (item.passed) {
                    Progress({
                      value: Math.min(item.ratio * 100, 2000),
                      total: 2000,
                      type: ProgressType.Linear
                    })
                      .layoutWeight(1)
                      .color(item.ratio >= 5 ? '#4CAF50' : item.ratio >= 2 ? '#FF9800' : '#F44336')
                      .backgroundColor('#EEEEEE')
                  } else {
                    Blank().layoutWeight(1)
                  }
                  Text(item.totalTime.toFixed(1) + "s")
                    .fontSize(11)
                    .fontColor('#757575')
                    .width(52)
                    .textAlign(TextAlign.End)
                }
                .width('100%')

                // 功耗信息
                if (item.avgPowerW > 0) {
                  Row({ space: 4 }) {
                    Text(item.avgPowerW.toFixed(2) + "W | " + item.energyJ.toFixed(1) + "J")
                      .fontSize(10)
                      .fontColor('#FF5722')
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                }
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#F8F8F8')
              .borderRadius(8)
            }, (item: BenchmarkResult) => item.benchmark)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

          // 复制按钮
          Button("复制结果")
            .width('60%')
            .height(44)
            .fontSize(16)
            .type(ButtonType.Capsule)
            .backgroundColor('#1976D2')
            .fontColor(Color.White)
            .margin({ bottom: 8 })
            .onClick(async () => {
              let text = this.formatResultsText();
              let pasteData: pasteboard.PasteData =
                pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
              let systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
              try {
                await systemPasteboard.setData(pasteData);
                promptAction.showToast({ message: '已复制到剪贴板', duration: 2000 });
              } catch (err) {
                hilog.info(0x0000, 'mainTag', 'Failed to set pasteboard: %{public}s', JSON.stringify(err));
              }
            })
        }

        // ---- 历史记录 ----
        Column({ space: 8 }) {
          Row() {
            Text("测试记录存档 (" + this.testRecords.length + ")")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.showHistory })
              .width(44)
              .height(24)
              .onChange((isOn: boolean) => {
                this.showHistory = isOn;
              })
          }
          .width('100%')

          if (this.showHistory) {
            if (this.testRecords.length === 0) {
              Text("暂无历史记录")
                .fontSize(13)
                .fontColor('#9E9E9E')
                .padding(12)
            } else {
              ForEach(this.testRecords, (record: TestRecord) => {
                Column({ space: 6 }) {
                  // 标题行：时间 + 删除
                  Row() {
                    Column({ space: 2 }) {
                      Text(record.timestamp)
                        .fontSize(12)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#1A1A1A')
                      Text(record.device + " | 核心 " + record.core + " | " + record.suiteLabel)
                        .fontSize(10)
                        .fontColor('#757575')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Column({ space: 2 }) {
                      Text(record.specRateScore.toFixed(2))
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#1976D2')
                      if ((record.specIntScore ?? 0) > 0 || (record.specFpScore ?? 0) > 0) {
                        Row({ space: 6 }) {
                          if ((record.specIntScore ?? 0) > 0) {
                            Text("I:" + record.specIntScore.toFixed(2))
                              .fontSize(10)
                              .fontColor('#1565C0')
                          }
                          if ((record.specFpScore ?? 0) > 0) {
                            Text("F:" + record.specFpScore.toFixed(2))
                              .fontSize(10)
                              .fontColor('#00838F')
                          }
                        }
                      }
                      if (record.totalEnergyJ > 0) {
                        Text(record.totalEnergyJ.toFixed(0) + "J")
                          .fontSize(10)
                          .fontColor('#FF5722')
                      }
                    }
                    .alignItems(HorizontalAlign.End)

                    Text("X")
                      .fontSize(14)
                      .fontColor('#F44336')
                      .fontWeight(FontWeight.Bold)
                      .padding({ left: 12 })
                      .onClick(() => {
                        this.deleteTestRecord(record.id);
                      })
                  }
                  .width('100%')

                  // 各项结果列表
                  ForEach(record.results, (r: BenchmarkResult) => {
                    Row({ space: 4 }) {
                      Text(r.passed ? "✓" : "✗")
                        .fontSize(10)
                        .fontColor(r.passed ? '#4CAF50' : '#F44336')
                        .width(12)
                      Text(r.benchmark)
                        .fontSize(10)
                        .fontColor('#424242')
                        .layoutWeight(1)
                      Text(r.totalTime.toFixed(1) + "s")
                        .fontSize(10)
                        .fontColor('#757575')
                        .width(48)
                      Text(r.passed ? r.ratio.toFixed(2) : "失败")
                        .fontSize(10)
                        .fontColor(r.passed ? '#1976D2' : '#F44336')
                        .width(40)
                        .textAlign(TextAlign.End)
                      if (r.avgPowerW > 0) {
                        Text(r.avgPowerW.toFixed(1) + "W")
                          .fontSize(10)
                          .fontColor('#FF5722')
                          .width(36)
                          .textAlign(TextAlign.End)
                      }
                    }
                    .width('100%')
                    .height(22)
                  }, (r: BenchmarkResult) => r.benchmark)
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#F8F8F8')
                .borderRadius(8)
              }, (record: TestRecord) => record.id.toString())
            }
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 100 })
    }
    .backgroundColor('#F2F3F5')
  }

  // ============================================================
  // 设备参数页
  // ============================================================
  @Builder
  DeviceTab() {
    Scroll() {
      Column({ space: 16 }) {
        // ---- 设备信息卡片 ----
        Column({ space: 10 }) {
          Text(deviceInfo.marketName)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text("处理器核心")
                .fontSize(11)
                .fontColor('#9E9E9E')
              Text(this.hasSmt
                ? (this.numPhysicalCores + "P / " + this.numCores + "L")
                : (this.numCores.toString() + " 核"))
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
              if (this.hasSmt) {
                Text("SMT")
                  .fontSize(9)
                  .fontColor('#7B1FA2')
                  .backgroundColor('#F3E5F5')
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              }
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)

            Column({ space: 2 }) {
              Text("已选核心")
                .fontSize(11)
                .fontColor('#9E9E9E')
              Text("核心 " + this.core)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1976D2')
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)

            Column({ space: 2 }) {
              Text("温度状态")
                .fontSize(11)
                .fontColor('#9E9E9E')
              Text(this.thermalText)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.thermalColor)
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 实时核心频率卡片 ----
        if (this.numCores > 0) {
          Column({ space: 12 }) {
            Row() {
              Text("核心频率")
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
              Blank()
              Text("实时")
                .fontSize(11)
                .fontColor('#4CAF50')
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(
                Array.from({ length: this.numCores }, (x: object, i: number) => i),
                (coreIdx: number) => {
                  Column({ space: 6 }) {
                    Row() {
                      Text(this.getCoreType(coreIdx)[0])
                        .fontSize(10)
                        .fontColor(this.getCoreType(coreIdx)[3])
                        .backgroundColor(this.getCoreType(coreIdx)[2])
                        .borderRadius(4)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      Blank()
                      Text("核心 " + coreIdx)
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#1A1A1A')
                    }
                    .width('100%')

                    Progress({ value: this.getFreqRatio(coreIdx), total: 100, type: ProgressType.Linear })
                      .width('100%')
                      .color(this.getCoreType(coreIdx)[1])
                      .backgroundColor('#EEEEEE')

                    Row() {
                      Blank()
                      Text(this.getFreqMHz(coreIdx).toString())
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#1A1A1A')
                      Text(" MHz")
                        .fontSize(11)
                        .fontColor('#9E9E9E')
                        .margin({ bottom: 2 })
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Bottom)
                  }
                  .width('48%')
                  .padding(10)
                  .backgroundColor(this.hasSmt && !this.isSmtPrimary(coreIdx) ? '#F5F5F5' : '#F8F8F8')
                  .borderRadius(12)
                  .margin({ bottom: 8 })
                  .opacity(this.hasSmt && !this.isSmtPrimary(coreIdx) ? 0.7 : 1.0)
                },
                (coreIdx: number) => 'freq_' + coreIdx
              )
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 100 })
    }
    .backgroundColor('#F2F3F5')
  }

  // ============================================================
  // 信息页 - 系统/存储/电池/屏幕/传感器
  // ============================================================
  @Builder
  InfoTab() {
    Scroll() {
      Column({ space: 16 }) {

        // ---- 系统信息卡片 ----
        Column({ space: 4 }) {
          Text("系统信息")
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')
            .margin({ bottom: 4 })

          this.kvRow("OS 版本", this.sysOsVersion)
          this.kvRow("API 级别", this.sysApiLevel)
          this.kvRow("版本 ID", this.sysVersionId)
          this.kvRow("构建类型", this.sysBuildType)
          this.kvRow("构建时间", this.sysBuildTime)
          this.kvRow("安全补丁", this.sysSecurityPatch)
          this.kvRow("内核", this.sysKernel)
          if (this.sysKernelBuild.length > 0) {
            Row() {
              Text("构建信息")
                .fontSize(13)
                .fontColor('#757575')
                .flexShrink(0)
                .constraintSize({ minWidth: 70 })
                .margin({ right: 8 })
              Text(this.sysKernelBuild)
                .fontSize(13)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
                .textAlign(TextAlign.End)
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .alignItems(VerticalAlign.Top)
          }
          this.kvRow("已开机", this.sysUptime)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 存储信息卡片 ----
        Column({ space: 12 }) {
          Text("存储")
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')

          // RAM
          Column({ space: 6 }) {
            Row() {
              Text("RAM")
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
              Blank()
              Text(this.ramPercent + '%')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1976D2')
            }
            .width('100%')

            Progress({ value: this.ramPercent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .color('#4CAF50')
              .backgroundColor('#EEEEEE')

            Text(this.ramUsed + ' / ' + this.ramTotal)
              .fontSize(12)
              .fontColor('#757575')
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#F8F8F8')
          .borderRadius(12)

          // Swap
          Column({ space: 6 }) {
            Row() {
              Text("Swap")
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
              Blank()
              Text(this.swapPercent + '%')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FF9800')
            }
            .width('100%')

            Progress({ value: this.swapPercent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .color('#FF9800')
              .backgroundColor('#EEEEEE')

            Text(this.swapUsed + ' / ' + this.swapTotal)
              .fontSize(12)
              .fontColor('#757575')
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#F8F8F8')
          .borderRadius(12)

          // 内置存储
          Column({ space: 6 }) {
            Row() {
              Text("内置存储")
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
              Blank()
              Text(this.storagePercent + '%')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.storagePercent > 80 ? '#F44336' : '#1976D2')
            }
            .width('100%')

            Progress({ value: this.storagePercent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .color(this.storagePercent > 80 ? '#F44336' : '#1976D2')
              .backgroundColor('#EEEEEE')

            Text(this.storageUsed + ' / ' + this.storageTotal)
              .fontSize(12)
              .fontColor('#757575')
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#F8F8F8')
          .borderRadius(12)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 电池信息卡片 ----
        Column({ space: 8 }) {
          Row() {
            Text("电池")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Blank()
            Text(this.battLevel + '%')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.battLevel > 20 ? '#4CAF50' : '#F44336')
          }
          .width('100%')

          Progress({ value: this.battLevel, total: 100, type: ProgressType.Linear })
            .width('100%')
            .color(this.battLevel > 50 ? '#4CAF50' : this.battLevel > 20 ? '#FF9800' : '#F44336')
            .backgroundColor('#EEEEEE')

          this.kvRow("状态", this.battStatus)
          this.kvRow("电压", this.battVoltage)
          this.kvRow("温度", this.battTemp)
          this.kvRow("健康", this.battHealth)
          this.kvRow("充电类型", this.battPlugType)
          this.kvRow("电池技术", this.battTech)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 屏幕信息卡片 ----
        Column({ space: 4 }) {
          Text("屏幕")
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')
            .margin({ bottom: 4 })

          this.kvRow("分辨率", this.screenWidth + ' x ' + this.screenHeight)
          this.kvRow("物理尺寸", this.screenPhysSize)
          this.kvRow("密度 (DPI)", this.screenDensity.toString())
          this.kvRow("xDPI", this.screenXDpi.toString())
          this.kvRow("yDPI", this.screenYDpi.toString())
          this.kvRow("当前刷新率", this.screenRefreshRate + ' Hz')
          if (this.screenRefreshRates.length > 0) {
            this.kvRow("支持刷新率", this.screenRefreshRates)
          }
          if (this.screenHdr.length > 0) {
            this.kvRow("HDR", this.screenHdr)
          }
          if (this.screenColorSpaces.length > 0) {
            this.kvRow("色域", this.screenColorSpaces)
          }
          this.kvRow("旋转角度", (this.screenRotation * 90) + '\u00B0')
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })

        // ---- 传感器列表卡片 ----
        Column({ space: 8 }) {
          Row() {
            Text("传感器")
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
            Blank()
            Text(this.sensorList.length + ' 个')
              .fontSize(13)
              .fontColor('#757575')
          }
          .width('100%')

          ForEach(this.sensorList, (item: SensorItem) => {
            Row() {
              Column({ space: 2 }) {
                Text(item.name)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#1A1A1A')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('供应商: ' + item.vendor + '  功率: ' + item.power)
                  .fontSize(11)
                  .fontColor('#9E9E9E')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .borderWidth({ bottom: 0.5 })
            .borderColor('#F0F0F0')
          }, (item: SensorItem, index: number) => 'sensor_' + index)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetX: 0, offsetY: 2 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 100 })
    }
    .backgroundColor('#F2F3F5')
    .onAppear((): void => {
      this.loadDeviceInfo();
    })
  }

  // 信息行子组件 - 使用 @Local 引用表达式内联，避免按值传参丢失响应式
  @Builder
  kvRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#757575')
        .flexShrink(0)
        .constraintSize({ minWidth: 70 })
        .margin({ right: 8 })
      Text(value)
        .fontSize(13)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Top)
  }

  // ============================================================
  // 主布局
  // ============================================================
  build() {
    Column() {
      // 标题栏（沉浸式 - 全局光效，延伸到状态栏区域）
      Column() {
        Row() {
          Text("SPEC CPU 2017")
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Blank()
          if (this.running) {
            Text(formatTime(this.elapsedTime))
              .fontSize(12)
              .fontColor('#1976D2')
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10, top: this.topSafeHeight + 8 })
      }
      .width('100%')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK, {
        colorMode: ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        policy: BlurStyleActivePolicy.ALWAYS_ACTIVE,
      }, { disableSystemAdaptation: true })
      .linearGradient({
        angle: 135,
        colors: [['#B3E3F2FD', 0], ['#99E8F0FA', 0.5], ['#80F2F3F5', 1]]
      })
      .shadow({ radius: 16, color: '#1A3399FF', offsetX: 0, offsetY: 4 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // 内容区 + HdsTabs 悬浮式高透明毛玻璃底部栏（hdsMaterial IMMERSIVE）
      Tabs({ barPosition: BarPosition.End, index: this.currentTabIndex }) {
        TabContent() {
          this.ConfigTab()
        }.tabBar(SubTabBarStyle.of("配置")
          .indicator({ color: '#1976D2', height: 2, borderRadius: 1 })
          .labelStyle({
            selectedColor: '#1976D2',
            unselectedColor: '#99182431',
            font: { size: 14, weight: FontWeight.Medium }
          }))

        TabContent() {
          this.RunTab()
        }.tabBar(SubTabBarStyle.of("运行")
          .indicator({ color: '#1976D2', height: 2, borderRadius: 1 })
          .labelStyle({
            selectedColor: '#1976D2',
            unselectedColor: '#99182431',
            font: { size: 14, weight: FontWeight.Medium }
          }))

        TabContent() {
          this.ResultsTab()
        }.tabBar(SubTabBarStyle.of("结果")
          .indicator({ color: '#1976D2', height: 2, borderRadius: 1 })
          .labelStyle({
            selectedColor: '#1976D2',
            unselectedColor: '#99182431',
            font: { size: 14, weight: FontWeight.Medium }
          }))

        TabContent() {
          this.DeviceTab()
        }.tabBar(SubTabBarStyle.of("设备")
          .indicator({ color: '#1976D2', height: 2, borderRadius: 1 })
          .labelStyle({
            selectedColor: '#1976D2',
            unselectedColor: '#99182431',
            font: { size: 14, weight: FontWeight.Medium }
          }))

        TabContent() {
          this.InfoTab()
        }.tabBar(SubTabBarStyle.of("信息")
          .indicator({ color: '#1976D2', height: 2, borderRadius: 1 })
          .labelStyle({
            selectedColor: '#1976D2',
            unselectedColor: '#99182431',
            font: { size: 14, weight: FontWeight.Medium }
          }))
      }
      .barOverlap(true)
      .barBackgroundEffect({
        radius: 60,
        saturation: 1.4,
        brightness: 1.08,
        color: '#15FFFFFF',
        adaptiveColor: AdaptiveColor.DEFAULT,
        policy: BlurStyleActivePolicy.ALWAYS_ACTIVE,
      })
      .onChange((index: number) => {
        this.currentTabIndex = index;
      })
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
