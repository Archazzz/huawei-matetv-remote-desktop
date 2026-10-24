# 开发、构建与签名

## 环境

- macOS + DevEco Studio（当前在 26.0.0 Release / SDK 26 验证输入诊断构建）。
- Python 3.12+，Git、curl。
- 完整客户端还需要 Rust/Cargo、`aarch64-unknown-linux-ohos` target 及上游原生构建依赖。
- **工程完整路径不要含空格。** DevEco 项目选择器会拒绝含空格路径。

`.work` 是隐藏目录。在 DevEco 的“打开项目”顶部路径栏粘贴完整路径即可；也可以在生成时通过 `--output` 指定可见目录。

## 输入诊断应用

```sh
python3 scripts/create_diagnostic_project.py
bash scripts/build_hap.sh .work/input-lab
```

在 DevEco 打开 `.work/input-lab`，进入“项目结构 → 项目 → 签名配置”，登录华为开发者账号，连接电视并启用自动生成签名文件。电视需要开启开发者选项及无线调试，允许这台电脑连接。

如已生成 `app.signingConfigs`，但构建仍提示 `No signingConfig found`，确认 `app.products` 中目标产品的 `signingConfig` 设置为相应名称（一般为 `default`）。这些配置和证书仅保存在本机。

重新构建后通过 DevEco 运行，或使用 SDK 自带的 HDC：

```sh
hdc tconn TV_IP:DEBUG_PORT
hdc -t TV_IP:DEBUG_PORT install .work/input-lab/entry/build/default/outputs/default/entry-default-signed.hap
hdc -t TV_IP:DEBUG_PORT shell aa start -a EntryAbility -b io.github.archazzz.matetvinputlab
```

## 完整客户端

```sh
python3 scripts/prepare_client.py
cd .work/client
source scripts/macos_env.sh
rustup target add aarch64-unknown-linux-ohos
bash scripts/build_rustdesk_ffi_ohos.sh arm64
cd ../..
bash scripts/build_hap.sh .work/client
```

`prepare_client.py` 按 `tv/upstream.json` 下载固定提交，并把电视适配应用到本地工程；匹配不到上游代码锚点时会停止。可用 `--archive` 指定已下载的同版本上游源码包，或 `--output` 指定生成目录。它会保留已有本地根构建配置、签名和服务配置。不要直接把 `.work/client` 当作本仓库的提交内容。

上游脚本先下载并校验 Opus，再交叉编译 RustDesk FFI。首次构建需联网获取 Cargo 依赖，网络缓慢时可能需要较长时间。更完整的原生工具链说明见生成工程的 `docs/DEVELOPMENT.md`。

在 DevEco 对 `.work/client` 单独生成与其包名 `io.github.archazzz.matetvremote` 对应的调试签名。输入诊断应用的 profile 不能直接用于另一个包名。

## 修改与发布

- 修改 `tv/overlay` 或 `tv/fragments`，然后重新执行准备脚本；只修改生成目录会在下次准备时丢失改动。
- `.work`、`local`、调试 HAP、签名证书和账号配置均被 Git 忽略。
- 打包发布前保留对应固定上游源码、补丁、原生依赖来源和许可证，记录构建工具版本。
- 自动化 CI 目前只验证桥接和脚本。HarmonyOS 编译、签名与电视验收必须另行执行；CI 通过不等于 HAP 已可用。
