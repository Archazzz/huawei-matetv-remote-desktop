"""Materialize the pinned upstream client and apply the reviewable TV overlay.

The upstream tree stays in .work; local signing configuration is never copied
into this repository. Patches fail closed if upstream anchor text changes.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / 'tv/upstream.json').read_text())


def computer_presets(path: Path) -> str:
    """Validate a private, credential-free list before embedding it in a local HAP."""
    items = json.loads(path.read_text())
    if not isinstance(items, list) or len(items) > 20:
        raise ValueError('computers must be an array with at most 20 entries')
    ids = set()
    endpoints = set()
    for item in items:
        required = {'id', 'label', 'address', 'port'}
        if not isinstance(item, dict) or not required <= set(item) or set(item) - required - {'credentialGroup'}:
            raise ValueError('each computer requires id, label, address and port; only credentialGroup is optional; credentials are forbidden')
        group = item.get('credentialGroup', '')
        if not isinstance(group, str) or (group and not re.fullmatch(r'[a-z0-9_-]{1,64}', group)):
            raise ValueError('credentialGroup must be an explicit lowercase group identifier')
        if not isinstance(item['id'], str) or not re.fullmatch(r'[a-z0-9_-]{1,64}', item['id']):
            raise ValueError('computer id must be a stable lowercase identifier')
        if not isinstance(item['label'], str) or not 1 <= len(item['label'].strip()) <= 60:
            raise ValueError('computer label must contain 1–60 characters')
        address = item['address']
        if not isinstance(address, str) or not 1 <= len(address) <= 253 or re.search(r'[\s/\\?#@]', address):
            raise ValueError('invalid computer address; use a bare IP or hostname')
        if type(item['port']) is not int or not 1 <= item['port'] <= 65535:
            raise ValueError('computer port must be an integer in 1–65535')
        endpoint = (address.lower(), item['port'])
        if item['id'] in ids or endpoint in endpoints:
            raise ValueError('duplicate computer id or endpoint')
        ids.add(item['id'])
        endpoints.add(endpoint)
    return ('// PRIVATE GENERATED BUILD CONFIGURATION. Do not publish this file or HAP.\n'
            'export interface TvComputerPreset { id: string; label: string; address: string; port: number; credentialGroup?: string; }\n'
            'export const TV_COMPUTER_PRESETS: TvComputerPreset[] = ' +
            json.dumps(items, ensure_ascii=True, indent=2) + ';\n')


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f'upstream patch anchor changed: {before[:100]!r}')
    return text.replace(before, after, 1)


def patch_session(text: str) -> str:
    text = "import { TV_COMPUTER_PRESETS, TvComputerPreset } from '../services/TvProvisionedComputers';\n" + text
    text = replace_once(text, "import { pasteboard, BusinessError } from '@kit.BasicServicesKit';",
                        "import { pasteboard, BusinessError, deviceInfo } from '@kit.BasicServicesKit';")
    members = (ROOT / 'tv/fragments/session-members.ets').read_text()
    members += (ROOT / 'tv/fragments/saved-login-members.ets').read_text()
    members += (ROOT / 'tv/fragments/display-members.ets').read_text()
    members += (ROOT / 'tv/fragments/lifecycle-members.ets').read_text()
    members += (ROOT / 'tv/fragments/viewport-members.ets').read_text()
    members += (ROOT / 'tv/fragments/corner-controls.ets').read_text()
    text = replace_once(text, 'struct RemoteDesktop {', 'struct RemoteDesktop {\n' + members)
    text = replace_once(text, '  private canForwardInput(source: string): boolean {',
                        '  private canForwardInput(source: string): boolean {\n    if (this.mateTvDisplayOpen || (this.mateTvTextOpen && source !== \'matetv-submit-text\')) { if (source !== \'mouse\' && source !== \'mouseMove\') { hilog.info(RD_DOMAIN, RD_TAG, \'dropInput \' + source + \' tvPanel=1 \' + this.sessionInputOwner.debugString()); } return false; }')
    text = replace_once(text,
                        "          } else if (this.pendingHost.protocol === 'rustdesk') {\n            this.openRustDeskAuthSheet();",
                        "          } else if (this.pendingHost.protocol === 'rustdesk') {\n            if (!this.mateTvTrySavedPassword()) { this.openRustDeskAuthSheet(); }")
    text = replace_once(text, '  private handleXComponentKey = (event: KeyEvent): boolean => {',
                        '  private handleXComponentKey = (event: KeyEvent): boolean => {\n    if (this.mateTvTextOpen || this.mateTvDisplayOpen) { return false; }\n    if (this.mateTvMode && event.keyCode === 2016) { return false; }')
    text = replace_once(text, '  aboutToDisappear(): void {',
                        '  aboutToDisappear(): void {\n    this.mateTvStopJoystick();\n    this.mateTvCancelDrag();\n    this.mateTvCloseText();\n    this.mateTvCloseDisplay();')
    text = replace_once(text, '  private handleXComponentMouse = (event: MouseEvent): void => {',
                        '  private handleXComponentMouse = (event: MouseEvent): void => {\n    if (this.mateTvObserveMouse(event)) { return; }')
    text = replace_once(text, "message: '远端未开放输入控制，请在被控手机开启 RustDesk 输入控制/无障碍权限',",
                        "message: '电脑端尚未允许控制，请检查 RustDesk 当前连接的键盘鼠标权限及系统辅助功能授权',")
    text = replace_once(text, '      if (this.connected && this.shouldShowRemoteSessionTopBar()) {',
                        '      if (!this.mateTvMode && this.connected && this.shouldShowRemoteSessionTopBar()) {')
    text = replace_once(text, "            this.restoreRustDeskDesktopFlipMode(this.pendingHost, 'host-restore');",
                        "            this.mateTvLoadControls();\n            this.mateTvInitStreamDefaults();\n            this.restoreRustDeskDesktopFlipMode(this.pendingHost, 'host-restore');")
    text = replace_once(text, '  onBackPress(): boolean {',
                        '  onBackPress(): boolean {\n    if (this.mateTvDisplayOpen) { this.mateTvCloseDisplay(); return true; }\n    if (this.mateTvTextOpen) { this.mateTvCloseText(); return true; }\n    if (this.mateTvMode) { if (this.keyboardOpen) { this.dismissKeyboard(); } else { this.goBack(); } return true; }')
    text = replace_once(text, '  private goBack(): void {',
                        '  private goBack(): void {\n    if (this.mateTvMode) { this.mateTvLeaveSession(); return; }')
    text = replace_once(text,
                        "      this.windowCloseResolve?.(); this.windowCloseResolve = null;\n      hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-return elapsedMs=' +",
                        "      this.windowCloseResolve?.(); this.windowCloseResolve = null;\n      this.mateTvFinishLeave();\n      hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-return elapsedMs=' +")
    text = replace_once(text,
                        ".width(this.shouldShowRustDeskMultiCanvasPreview() ? '50%' : '100%').height('100%')",
                        ".width(this.mateTvTextOpen ? '68%' : (this.shouldShowRustDeskMultiCanvasPreview() ? '50%' : '100%')).height('100%')")
    text = replace_once(text,
                        ".align(this.shouldShowRustDeskMultiCanvasPreview() ? Alignment.Start : Alignment.Center)",
                        ".align(this.mateTvTextOpen || this.shouldShowRustDeskMultiCanvasPreview() ? Alignment.Start : Alignment.Center)")
    text = replace_once(text, '  private currentCanvasDisplayDefault(viewport: CanvasViewport): CanvasTransform {',
                        "  private currentCanvasDisplayDefault(viewport: CanvasViewport): CanvasTransform {\n    if (this.mateTvMode) { return baseCanvasTransform(this.mateTvTextOpen ? 'fit' : this.mateTvViewMode, 100, viewport, this.canvasRotationQuarterTurns); }")
    text = replace_once(text, '    this.updateRendererViewportCacheForCanvasTransform(viewport);',
                        '    this.updateRendererViewportCacheForCanvasTransform(viewport);\n    this.mateTvSyncViewport(viewport);')
    for method in ['applyRemotePointerCanvasFollow(remoteX: number, remoteY: number)',
                   'updatePhysicalPointerCanvasFollow(localX: number, localY: number)']:
        text = replace_once(text, '  private ' + method + ': void {',
                            '  private ' + method + ': void {\n    if (this.mateTvMode) { return; }')
    text = replace_once(text, '    this.rustDeskProfileTargetDisplay = display.display;',
                        '    if (this.mateTvMode) { this.mateTvStopJoystick(); this.resetCanvasToDisplayDefault(); }\n    this.rustDeskProfileTargetDisplay = display.display;')
    text = replace_once(text,
                        '    previousHeight: number, nextWidth: number, nextHeight: number): void {',
                        '    previousHeight: number, nextWidth: number, nextHeight: number): void {\n    if (this.mateTvMode && (previousWidth !== nextWidth || previousHeight !== nextHeight)) { this.canvasTransformGestureModified = false; return; }')
    text = replace_once(text, '  private handleXComponentAxis = (event?: AxisEvent): void => {',
                        "  private handleXComponentAxis = (event?: AxisEvent): void => {\n    if (this.mateTvMode && event) { hilog.info(RD_DOMAIN, RD_TAG, 'MateTV axis action=' + event.action + ' tool=' + event.sourceTool + ' vertical=' + event.getVerticalAxisValue() + ' horizontal=' + event.getHorizontalAxisValue()); }")
    # Release both pending TV gestures and physical buttons across lifecycle/geometry fences.
    text = replace_once(text, '  private releaseAllHeldKeys(releaseMouseButtons: boolean = true): void {',
                        '  private releaseAllHeldKeys(releaseMouseButtons: boolean = true): void {\n    if (this.mateTvMode && releaseMouseButtons) { this.mateTvResetTouchState(); this.mateTvRightMouseRelease = false; }')
    if text.count('.onTouch(this.handleConfiguredTouchInput)') != 2:
        raise ValueError('input surface count changed')
    text = text.replace('.onTouch(this.handleConfiguredTouchInput)',
        '.onTouch((event: TouchEvent): void => { if (this.mateTvMode) { this.mateTvTouch(event); } else { this.handleConfiguredTouchInput(event); } })')
    # Match the TV input lab: preserve ArkUI's semantic onClick activation,
    # including pointer remote/accessibility, and add other gestures in parallel.
    anchor = '        .gesture(\n          GestureGroup(GestureMode.Parallel,'
    text = replace_once(text, anchor,
                        '        .onClick((event: ClickEvent): void => { this.mateTvActivate(event); })\n        .parallelGesture(\n          GestureGroup(GestureMode.Parallel,')
    text = replace_once(text, "        .focusable(false)\n        .focusOnTouch(false)\n        .defaultFocus(false)",
                        "        .focusable(this.mateTvMode)\n        .focusOnTouch(this.mateTvMode)\n        .defaultFocus(this.mateTvMode)")
    anchor = '      // Keep the file-transfer sheet on its own host.'
    addition = '''      if (this.mateTvMode && this.connected && !this.mateTvTextOpen && !this.mateTvDisplayOpen && !this.mateTvLeaving) {
        this.mateTvCornerControls()
      }
      if (this.mateTvMode && this.mateTvLeaving) {
        Stack() { this.mateTvLeavingPanel() }
          .width('100%').height('100%').backgroundColor('#ED101C25')
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(300)
      }
      if (this.mateTvMode && this.mateTvDisplayOpen) {
        Stack() { this.mateTvDisplayPanel() }
          .width('100%').height('100%').backgroundColor('#CC101C25')
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(200)
      }
      if (this.mateTvMode && this.mateTvTextOpen) {
        Stack({ alignContent: Alignment.TopEnd }) { this.mateTvTextPanel() }
          .width('100%').height('100%').backgroundColor('#18101C25')
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(200)
      }

'''
    return replace_once(text, anchor, addition + anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='use a previously downloaded pinned GitHub tarball')
    parser.add_argument('--output', type=Path, default=ROOT / '.work/client')
    parser.add_argument('--computers', type=Path, help='private JSON computer list to import once on the TV (no passwords)')
    args = parser.parse_args()
    presets = computer_presets(args.computers) if args.computers else None
    dest = args.output.resolve()
    dest.parent.mkdir(parents=True, exist_ok=True)
    archive = args.archive or ROOT / '.work' / (PIN['commit'] + '.tar.gz')
    if not archive.exists():
        url = 'https://api.github.com/repos/Mydstiny/RemoteDesktopHarmonyOS/tarball/' + PIN['commit']
        temporary = archive.with_suffix('.download')
        subprocess.run(['curl', '-fL', '--retry', '2', '-o', str(temporary), url], check=True)
        temporary.replace(archive)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        prefix = members[0].name.split('/')[0]
        if not prefix.endswith(PIN['commit'][:7]):
            raise ValueError('archive does not match the pinned upstream commit')
        # Extract to a sibling staging directory. Python 3.12+ data filter rejects
        # traversal and unsafe links before any source is compiled or executed.
        staging = dest.parent / 'upstream-extract'
        staging.mkdir(exist_ok=True)
        source.extractall(staging, filter='data')
    upstream = staging / prefix
    # Preserve existing local signing configuration and user-created private files.
    preserved = {}
    for rel in ['build-profile.json5', 'local.properties', 'entry/src/main/resources/rawfile/agconnect-services.json']:
        if (dest / rel).exists():
            preserved[rel] = (dest / rel).read_bytes()
    shutil.copytree(upstream, dest, dirs_exist_ok=True)
    shutil.copytree(ROOT / 'tv/overlay', dest, dirs_exist_ok=True)
    if presets is not None:
        (dest / 'entry/src/main/ets/services/TvProvisionedComputers.ets').write_text(presets)
    module = dest / 'entry/src/main/module.json5'
    text = module.read_text()
    text, count = re.subn(r'"deviceTypes"\s*:\s*\[[^\]]+\]', '"deviceTypes": ["tv"]', text, count=1)
    if count != 1:
        raise ValueError('deviceTypes declaration missing')
    module.write_text(text)
    app_path = dest / 'AppScope/app.json5'
    app = json.loads(app_path.read_text())
    app['app']['bundleName'] = PIN['bundleName']
    app['app']['vendor'] = 'MateTV Remote contributors'
    app['app']['versionName'] = '0.1.0'
    app['app']['versionCode'] = 1000000
    app_path.write_text(json.dumps(app, ensure_ascii=False, indent=2) + '\n')
    pages_path = dest / 'entry/src/main/resources/base/profile/main_pages.json'
    pages = json.loads(pages_path.read_text())
    pages['src'] = ['pages/TvHome', 'pages/TvInputLab'] + [p for p in pages['src'] if p not in ['pages/TvHome', 'pages/TvInputLab']]
    pages_path.write_text(json.dumps(pages, indent=2) + '\n')
    startup = dest / 'entry/src/main/ets/services/AppStartupPolicy.ets'
    startup.write_text(startup.read_text().replace("'pages/GuidePage'", "'pages/TvHome'").replace("'pages/LoginPage'", "'pages/TvInputLab'"))
    remote = dest / 'entry/src/main/ets/pages/RemoteDesktop.ets'
    remote.write_text(patch_session(remote.read_text()))
    # HitTestMode.None excludes only the cursor container. Its Image/Stack
    # descendants still intercept touches exactly at the pointer hotspot.
    cursor = dest / 'entry/src/main/ets/components/RemoteCursorOverlay.ets'
    cursor.write_text(replace_once(cursor.read_text(),
        '.hitTestBehavior(HitTestMode.None)', '.hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)'))
    # The upstream mobile software path downsizes every frame to 1600px.
    # TV quality=2 preserves source detail within a bounded 4K pixel budget;
    # normal/low quality retain the upstream performance cap.
    decoder = dest / 'entry/src/main/cpp/render/software_decoder.cpp'
    decoder_text = '#include "matetv_decode_quality.h"\n' + decoder.read_text()
    start = decoder_text.index('void computeOutputSize(')
    end = decoder_text.index('\n#ifdef USE_FFMPEG_SOFTWARE_DECODER', start)
    decoder_text = decoder_text[:start] + """void computeOutputSize(int srcWidth, int srcHeight, int& outWidth, int& outHeight) {
    MateTv::outputSize(srcWidth, srcHeight,
        MateTv::decodeQuality.load(std::memory_order_relaxed), outWidth, outHeight);
}
""" + decoder_text[end:]
    decoder_text = replace_once(decoder_text, 'constexpr int kSoftwareDecodeMaxOutputEdge = 1600;\n', '')
    decoder_text = replace_once(decoder_text, 'impl_->codecCtx->thread_count, kSoftwareDecodeMaxOutputEdge);',
        'impl_->codecCtx->thread_count, MateTv::decodeQuality.load(std::memory_order_relaxed) == 2 ? 8192 : 1600);')
    decoder.write_text(decoder_text)
    # Resolution budget is a separate TV preference, never changed by bitrate tier.
    napi = dest / 'entry/src/main/cpp/extensions/extension_loader_napi.cpp'
    napi_text = '#include "render/matetv_decode_quality.h"\n' + napi.read_text()
    napi_text = replace_once(napi_text, '/** NAPI: setRustDeskImageQuality(sessionId, quality): boolean */',
        """napi_value NapiSetMateTvSourceResolution(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool source = true;
    const bool accepted = argc == 1 && napi_get_value_bool(env, args[0], &source) == napi_ok;
    if (accepted) MateTv::setDecodeQuality(source ? 2 : 1);
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: setRustDeskImageQuality(sessionId, quality): boolean */""")
    napi_text = replace_once(napi_text,
        '    napi_set_named_property(env, exports, "setRustDeskImageQuality", fn);',
        '    napi_set_named_property(env, exports, "setRustDeskImageQuality", fn);\n'
        '    napi_create_function(env, "setMateTvSourceResolution", NAPI_AUTO_LENGTH, NapiSetMateTvSourceResolution, nullptr, &fn);\n'
        '    napi_set_named_property(env, exports, "setMateTvSourceResolution", fn);')
    napi.write_text(napi_text)
    native_types = dest / 'entry/src/main/cpp/types/librdpnapi/index.d.ts'
    native_types.write_text(replace_once(native_types.read_text(),
        '  export function setRustDeskImageQuality(sessionId: number, quality: number): boolean;',
        '  export function setRustDeskImageQuality(sessionId: number, quality: number): boolean;\n'
        '  export function setMateTvSourceResolution(source: boolean): boolean;'))
    hardware = dest / 'entry/src/main/cpp/render/hw_decoder.cpp'
    hardware_text = hardware.read_text()
    hardware_text = replace_once(hardware_text,
        '            admission == Render::VideoFrameAdmission::AcceptAfterSoftDrop &&',
        '            (admission == Render::VideoFrameAdmission::AcceptAfterSoftDrop ||\n             admission == Render::VideoFrameAdmission::DropAndWaitForKeyframe) &&')
    hardware_text = replace_once(hardware_text,
        '        ownedAdmission = HardwareDecodeAdmission::Backpressure;\n        return 0;\n    }\n    if (droppedIncomingForCapacity)',
        '        ownedAdmission = HardwareDecodeAdmission::Backpressure;\n        return requestKeyframe ? kDecodeKeyframeRequired : 0;\n    }\n    if (droppedIncomingForCapacity)')
    hardware_text = replace_once(hardware_text,
        '                return {result, DecoderNapi::OwnedSubmitStatus::Backpressure};',
        '                return {result, result == DecoderNapi::kDecodeHardwareKeyframeRequired ?\n                    DecoderNapi::OwnedSubmitStatus::NeedKeyframe : DecoderNapi::OwnedSubmitStatus::Backpressure};')
    hardware.write_text(hardware_text)
    runtime = dest / 'rustdesk_ffi/src/lib.rs'
    runtime_text = runtime.read_text()
    runtime_text = replace_once(runtime_text,
        '    if image_quality == 2 {\n        return BEST_QUALITY_FPS;\n    }\n    if requested_fps > 0 {\n        return requested_fps.min(MAX_REQUESTED_FPS);\n    }',
        '    // An explicit TV frame-rate choice is independent of encoder quality.\n'
        '    if requested_fps > 0 {\n        return requested_fps.min(MAX_REQUESTED_FPS);\n    }\n'
        '    if image_quality == 2 {\n        return BEST_QUALITY_FPS;\n    }')
    runtime_text = replace_once(runtime_text, 'fn best_quality_keeps_30_fps_over_an_explicit_frame_rate()',
        'fn best_quality_honors_explicit_frame_rate_and_bounds_it()')
    runtime_text = replace_once(runtime_text,
        'assert_eq!(stream_fps_for(RustDeskProfile::Performance, 0, 2, 60), 30);',
        'assert_eq!(stream_fps_for(RustDeskProfile::Performance, 0, 2, 60), 60);')
    runtime_text = replace_once(runtime_text,
        'assert_eq!(stream_fps_for(RustDeskProfile::Balanced, 4, 2, 120), 30);',
        'assert_eq!(stream_fps_for(RustDeskProfile::Balanced, 4, 2, 120), 120);\n'
        '        assert_eq!(stream_fps_for(RustDeskProfile::Balanced, 4, 2, 500), 120);')
    runtime.write_text(runtime_text)
    connector = dest / 'rustdesk_ffi/src/connector.rs'
    connector_text = connector.read_text()
    for before, after in [
        ('const BACKPRESSURE_FPS: [u32; 4] = [60, 45, 30, 15];',
         'const BACKPRESSURE_FPS: [u32; 4] = [120, 45, 30, 15];'),
        ('const VP9_BACKPRESSURE_FPS: [u32; 4] = [30, 26, 22, 18];',
         'const VP9_BACKPRESSURE_FPS: [u32; 4] = [60, 26, 22, 18];'),
        ('const VP9_HIGH_RESOLUTION_FPS: u32 = 30;', 'const VP9_HIGH_RESOLUTION_FPS: u32 = 60;'),
        ('fn live_best_quality_caps_30_and_switching_back_restores_the_user_rate()',
         'fn live_best_quality_preserves_the_user_rate()'),
        ('assert_eq!(to_best, Some((30, 30, 30)));', 'assert_eq!(to_best, None);'),
        ('fn high_resolution_vp9_uses_a_stable_thirty_fps_ceiling()',
         'fn high_resolution_vp9_caps_at_sixty_without_raising_lower_user_choices()'),
        ('assert_eq!(resolution_aware_fps_ceiling(2, 2940, 1912, 60), 30);',
         'assert_eq!(resolution_aware_fps_ceiling(2, 2940, 1912, 60), 60);\n'
         '        assert_eq!(resolution_aware_fps_ceiling(2, 5120, 1440, 120), 60);\n'
         '        assert_eq!(pressure_target_fps(4, 4, 120, 0, false), 120);\n'
         '        assert_eq!(pressure_target_fps(4, 4, 120, 2, false), 30);'),
    ]:
        connector_text = replace_once(connector_text, before, after)
    connector.write_text(connector_text)
    protocol = dest / 'rustdesk_ffi/src/protocol/session.rs'
    protocol_text = protocol.read_text()
    quality_call = 'opt.set_image_quality(Self::image_quality_from_pref(image_quality));'
    if protocol_text.count(quality_call) != 3:
        raise ValueError('RustDesk login/live quality call sites changed')
    protocol_text = protocol_text.replace(quality_call, 'Self::apply_mate_tv_quality(&mut opt, image_quality);')
    protocol_text = replace_once(protocol_text, '    fn image_quality_from_pref(',
        (ROOT / 'tv/fragments/quality-members.rs').read_text() + '    fn image_quality_from_pref(')
    protocol_text = protocol_text.replace('live_best_quality_uses_official_best_image_quality_enum',
        'live_tv_quality_uses_official_custom_quality_field')
    protocol_text = replace_once(protocol_text,
        'assert_eq!(option.get_image_quality(), ImageQuality::Best);',
        'assert_eq!(option.get_image_quality(), ImageQuality::NotSet);\n                    assert_eq!(option.get_custom_image_quality(), 2000 << 8);')
    protocol.write_text(protocol_text + '\n' + (ROOT / 'tests/tv-quality.test.rs').read_text())
    for resource in (dest / 'AppScope/resources').glob('*/element/string.json'):
        data = json.loads(resource.read_text())
        for item in data.get('string', []):
            if item['name'] == 'app_name':
                item['value'] = 'MateTV Remote'
        resource.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    # Upstream excludes local build profiles. Restore the reviewed module template.
    template = dest / 'entry/build-profile.json5.bak-freerdp'
    module_build = template.read_text().replace('["arm64-v8a", "x86_64"]', '["arm64-v8a"]')
    (dest / 'entry/build-profile.json5').write_text(module_build)
    build = {'app': {'products': [{'name': 'default', 'targetSdkVersion': '26.0.0',
             'compatibleSdkVersion': '6.1.0(23)', 'runtimeOS': 'HarmonyOS',
             'buildOption': {'strictMode': {'caseSensitiveCheck': True, 'useNormalizedOHMUrl': True}}}],
             'buildModeSet': [{'name': 'debug'}, {'name': 'release'}]},
             'modules': [{'name': 'entry', 'srcPath': './entry', 'targets': [{'name': 'default', 'applyToProducts': ['default']}]}]}
    (dest / 'build-profile.json5').write_text(json.dumps(build, indent=2) + '\n')
    ag_example = dest / 'entry/src/main/resources/rawfile/agconnect-services.example.json'
    if ag_example.exists():
        shutil.copyfile(ag_example, ag_example.with_name('agconnect-services.json'))
    for rel, data in preserved.items():
        (dest / rel).write_bytes(data)
    (dest / 'MATETV_UPSTREAM_COMMIT').write_text(PIN['commit'] + '\n')
    print(dest)


if __name__ == '__main__':
    main()
