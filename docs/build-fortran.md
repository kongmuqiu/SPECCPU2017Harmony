# Fortran 基准测试交叉编译指南

本文档说明如何在 Linux (WSL) 上为 OpenHarmony 交叉编译 Fortran 基准测试。

## 前提条件

1. **OpenHarmony SDK** — 安装 DevEco Studio 后自动下载，或手动配置
2. **LLVM 20 工具链** — 安装 `flang-new-20`、`lld-20`、`clang-20`
3. **llvm-project 源码** — 用于编译 Fortran 运行时库

### 安装 LLVM 20

```bash
# Ubuntu/Debian (https://apt.llvm.org/)
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 20
```

### 克隆 llvm-project

```bash
cd $HOME
git clone https://github.com/llvm/llvm-project.git
cd llvm-project
git checkout main
# 可选: 切换到与 flang-new-20 --version 匹配的 commit
```

## 环境变量配置

所有构建脚本通过环境变量定位 SDK 和工具链，不硬编码路径。

```bash
# 必须设置: OpenHarmony SDK native 目录
export OHOS_SDK_NATIVE=/path/to/OpenHarmony/Sdk/12/native

# 可选: llvm-project 路径 (默认: $HOME/llvm-project)
export LLVM_PROJECT=$HOME/llvm-project

# 可选: Fortran 运行时库路径 (默认: ./flang)
export FLANG_DIR=$PWD/flang

# 可选: 设为 1 自动复制 .so 到构建中间目录
export COPY_TO_BUILD=1
```

**Windows (WSL) 用户**: SDK 路径需转换为 WSL 挂载路径:
```bash
export OHOS_SDK_NATIVE=/mnt/c/Users/你的用户名/AppData/Local/OpenHarmony/Sdk/12/native
```

**macOS 用户**: 使用 command-line-tools 路径:
```bash
export OHOS_SDK_NATIVE=~/command-line-tools/sdk/default/openharmony/native
```

## 构建步骤

### 第一步: 生成 CMakeLists.txt

```bash
perl generate.perl
```

### 第二步: 编译 Fortran 运行时库

仅需在首次构建或 LLVM 版本更新时执行:

```bash
./build-fortran-libs.sh
```

生成的库文件保存在 `./flang/` 目录:
- `libunwind.a`
- `libFortranDecimal.a`
- `libFortranRuntime.a`

### 第三步: 编译 Fortran 基准测试

```bash
# 编译单个基准测试
./build-fortran.sh 503

# 编译多个基准测试
./build-fortran.sh 503 507 549

# 编译全部 Fortran 基准测试
./build-fortran.sh all
```

支持的 Fortran 基准测试:

| 编号 | 名称 | 语言 | 说明 |
|------|------|------|------|
| 503 | bwaves_r | Fortran | 流体力学，单步编译 |
| 507 | cactuBSSN_r | C/C++/Fortran | 广义相对论，混合编译 |
| 521 | wrf_r | C/Fortran | 天气预报模型，双目标 (wrf + diffwrf) |
| 527 | cam4_r | C/Fortran | 气候模型，双目标 (cam4 + validate) |
| 548 | exchange2_r | Fortran | 数独求解器，单步编译 |
| 549 | fotonik3d_r | Fortran | 光子学计算，按序编译 |
| 554 | roms_r | Fortran | 海洋模型，多轮编译 |

### 第四步: 完整构建

编译完 Fortran 基准测试后，使用 Hvigor 完成完整构建:

```bash
# Linux
./build-linux.sh

# macOS (不含 Fortran 基准测试)
./build-macos.sh
```

## 工具链文件

`ohos-toolchain.cmake` 用于 CMake 交叉编译配置，通过 `OHOS_SDK_NATIVE` 环境变量定位 sysroot:

```bash
# 使用示例
cmake -DCMAKE_TOOLCHAIN_FILE=ohos-toolchain.cmake ..
```

## 常见问题

### Q: Fortran 模块依赖编译失败

部分 Fortran 基准测试 (507, 521, 527, 554) 的源文件之间有模块依赖关系。`build-fortran.sh` 使用多轮编译策略自动解决依赖: 每轮尝试编译所有未成功的文件，直到全部完成。

### Q: 找不到 clang RT 库

确保 `OHOS_SDK_NATIVE` 指向正确的 SDK native 目录，脚本会自动在 `llvm/lib/clang/*/lib/aarch64-linux-ohos` 下查找。

### Q: macOS 上无法编译 Fortran

macOS 尚不支持 `flang-new-20` 交叉编译。请在 Linux 或 WSL 上执行 Fortran 基准测试编译，然后将 `.so` 文件复制回项目目录。
