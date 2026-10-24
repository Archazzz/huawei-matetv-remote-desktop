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


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f'upstream patch anchor changed: {before[:100]!r}')
    return text.replace(before, after, 1)


def patch_session(text: str) -> str:
    text = replace_once(text, "import { pasteboard, BusinessError } from '@kit.BasicServicesKit';",
                        "import { pasteboard, BusinessError, deviceInfo } from '@kit.BasicServicesKit';")
    members = (ROOT / 'tv/fragments/session-members.ets').read_text()
    text = replace_once(text, 'struct RemoteDesktop {', 'struct RemoteDesktop {\n' + members)
    text = replace_once(text, '  private canForwardInput(source: string): boolean {',
                        '  private canForwardInput(source: string): boolean {\n    if (this.mateTvTextOpen && source !== \'matetv-submit-text\') { return false; }')
    text = replace_once(text, '  private handleXComponentKey = (event: KeyEvent): boolean => {',
                        '  private handleXComponentKey = (event: KeyEvent): boolean => {\n    if (this.mateTvTextOpen) { return false; }')
    text = replace_once(text, '  aboutToDisappear(): void {',
                        '  aboutToDisappear(): void {\n    this.mateTvCancelDrag();\n    this.mateTvCloseText();')
    # TV remote uses normalized click/pan. Ignore synthesized touch to avoid a
    # second click; actual mouse and keyboard continue through upstream handlers.
    if text.count('.onTouch(this.handleConfiguredTouchInput)') != 2:
        raise ValueError('input surface count changed')
    text = text.replace('.onTouch(this.handleConfiguredTouchInput)',
        '.onTouch((event: TouchEvent): void => { if (!this.mateTvMode) { this.handleConfiguredTouchInput(event); } })')
    anchor = '        .gesture(\n          GestureGroup(GestureMode.Parallel,'
    addition = '''        .onClick((event: ClickEvent): void => { this.mateTvClick(event); })
        .parallelGesture(PanGesture({ fingers: 1, distance: 8 })
          .onActionStart((event: GestureEvent): void => { this.mateTvPanStart(event); })
          .onActionUpdate((event: GestureEvent): void => { this.mateTvPanUpdate(event); })
          .onActionEnd((event: GestureEvent): void => { this.mateTvPanEnd(event); })
          .onActionCancel((): void => { if (this.mateTvMode) { this.mateTvCancelDrag(); } }))
'''
    text = replace_once(text, anchor, addition + anchor)
    anchor = '      // Keep the file-transfer sheet on its own host.'
    addition = '''      if (this.mateTvMode && this.connected) {
        this.mateTvToolbar()
      }
      if (this.mateTvMode && this.mateTvTextOpen) {
        Stack() { this.mateTvTextPanel() }
          .width('100%').height('100%').backgroundColor('#CC101C25')
          .hitTestBehavior(HitTestMode.Block).zIndex(200)
      }

'''
    return replace_once(text, anchor, addition + anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='use a previously downloaded pinned GitHub tarball')
    parser.add_argument('--output', type=Path, default=ROOT / '.work/client')
    args = parser.parse_args()
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
