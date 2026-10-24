"""Create a small, independent HAP for testing real MateTV input capabilities."""
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / '.work' / 'input-lab'


def write(path, data):
    target = DEST / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def main():
    global DEST
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEST)
    args = parser.parse_args()
    DEST = args.output.resolve()
    write('AppScope/app.json5', {'app': {
        'bundleName': 'io.github.archazzz.matetvinputlab', 'vendor': 'MateTV Remote contributors',
        'versionCode': 1000000, 'versionName': '0.1.0', 'icon': '$media:app_icon', 'label': '$string:app_name'}})
    write('AppScope/resources/base/element/string.json', {'string': [{'name': 'app_name', 'value': 'MateTV 输入测试'}]})
    write('entry/src/main/resources/base/element/string.json', {'string': []})
    write('entry/src/main/resources/base/element/color.json', {'color': [{'name': 'start_window_background', 'value': '#101C25'}]})
    write('entry/src/main/resources/base/profile/main_pages.json', {'src': ['pages/TvInputLab']})
    write('entry/src/main/module.json5', {'module': {
        'name': 'entry', 'type': 'entry', 'mainElement': 'EntryAbility', 'deviceTypes': ['tv', 'tablet'],
        'deliveryWithInstall': True, 'installationFree': False, 'pages': '$profile:main_pages',
        'abilities': [{'name': 'EntryAbility', 'srcEntry': './ets/entryability/EntryAbility.ets',
                       'label': '$string:app_name', 'icon': '$media:app_icon', 'orientation': 'landscape',
                       'startWindowIcon': '$media:app_icon', 'startWindowBackground': '$color:start_window_background',
                       'exported': True, 'skills': [{'entities': ['entity.system.home'], 'actions': ['ohos.want.action.home']}]}]}})
    if not (DEST / 'build-profile.json5').exists():
        write('build-profile.json5', {'app': {'products': [{'name': 'default', 'targetSdkVersion': '26.0.0',
            'compatibleSdkVersion': '6.1.0(23)', 'runtimeOS': 'HarmonyOS'}],
            'buildModeSet': [{'name': 'debug'}, {'name': 'release'}]},
            'modules': [{'name': 'entry', 'srcPath': './entry', 'targets': [{'name': 'default', 'applyToProducts': ['default']}]}]})
    write('entry/build-profile.json5', {'apiType': 'stageMode', 'buildOption': {}, 'targets': [{'name': 'default'}]})
    write('oh-package.json5', {'modelVersion': '6.0.0', 'name': 'matetv-input-lab', 'version': '0.1.0', 'dependencies': {}})
    write('entry/oh-package.json5', {'name': 'entry', 'version': '0.1.0', 'dependencies': {}})
    write('hvigor/hvigor-config.json5', {'modelVersion': '6.0.0', 'dependencies': {}})
    for path, task in [('hvigorfile.ts', 'appTasks'), ('entry/hvigorfile.ts', 'hapTasks')]:
        (DEST / path).write_text(f"import {{ {task} }} from '@ohos/hvigor-ohos-plugin';\nexport default {{ system: {task}, plugins: [] }};\n")
    ability = DEST / 'entry/src/main/ets/entryability/EntryAbility.ets'
    ability.parent.mkdir(parents=True, exist_ok=True)
    ability.write_text("""import { UIAbility, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
export default class EntryAbility extends UIAbility {
  onCreate(): void { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK); }
  onWindowStageCreate(stage: window.WindowStage): void { stage.loadContent('pages/TvInputLab'); }
}
""")
    page = DEST / 'entry/src/main/ets/pages/TvInputLab.ets'
    page.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'tv/overlay/entry/src/main/ets/pages/TvInputLab.ets', page)
    icon = '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" rx="24" fill="#101C25"/><rect x="20" y="24" width="88" height="64" rx="8" fill="none" stroke="#70E0C2" stroke-width="6"/><path d="M45 106h38M64 90v16" stroke="#70E0C2" stroke-width="6"/></svg>'
    for prefix in ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']:
        directory = DEST / prefix
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'app_icon.svg').write_text(icon)
    print(DEST)


if __name__ == '__main__':
    main()
