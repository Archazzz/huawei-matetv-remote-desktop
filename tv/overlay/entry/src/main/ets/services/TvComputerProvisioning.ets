import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { HostSyncService } from './HostSyncService';
import { RemoteHost } from '../model/RemoteHost';
import { TV_COMPUTER_PRESETS } from './TvProvisionedComputers';

// Synchronous after store initialization: concurrent page refreshes cannot add duplicates.
// Mark each imported preset so later edits/deletions remain the user's decision.
export function provisionTvComputers(context: common.Context): void {
  if (TV_COMPUTER_PRESETS.length === 0) { return; }
  if (!CloudStore.getInstance().isReady()) { throw new Error('本机存储尚未就绪'); }
  const service: HostSyncService = HostSyncService.getInstance();
  const scope: string = AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
  const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'MateTvProvisioning' });
  for (const preset of TV_COMPUTER_PRESETS) {
    const key: string = scope + ':' + preset.id;
    if (store.getSync(key, false) === true) { continue; }
    const existing: RemoteHost | undefined = service.getAllHosts().find((host: RemoteHost): boolean =>
      host.protocol === 'rustdesk' && host.rustdeskDirectEnabled &&
      host.rustdeskDirectHost === preset.address && host.rustdeskDirectPort === preset.port);
    if (existing === undefined) {
      const host: RemoteHost = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.userId = scope;
      host.label = preset.label;
      host.protocol = 'rustdesk';
      host.host = preset.address;
      host.port = preset.port;
      host.customHostname = preset.address;
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = preset.address;
      host.rustdeskDirectPort = preset.port;
      host.rustdeskAuthMode = 'password';
      host.rustdeskPasswordMode = 1;
      if (!service.addHost(host)) { throw new Error('预置电脑保存失败，请重试'); }
    }
    store.putSync(key, true);
    store.flushSync();
  }
}
