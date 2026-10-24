  private mateTvTrySavedPassword(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!this.mateTvMode || host === null || host.protocol !== 'rustdesk' ||
        host.rustdeskPasswordMode !== 1 || host.rustdeskAuthMode === 'request_approval' ||
        this.cleanupStarted ||
        this.currentAbilityBackgroundState() || (crypto.isSetupComplete() && !crypto.isReady())) {
      return false;
    }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    // An unfinished edited draft must still be reviewed in the ordinary dialog.
    if (this.rustDeskAuthDrafts.load(scope.ownerScopeId, scope.generation, host.id) !== null) { return false; }
    let password: string = host.password;
    if (password.trim().length === 0 && !host.passwordConfigured && host.rustdeskDirectEnabled) {
      const target: TvComputerPreset | undefined = TV_COMPUTER_PRESETS.find((preset: TvComputerPreset): boolean =>
        preset.address === host.rustdeskDirectHost && preset.port === host.rustdeskDirectPort);
      const group: string = target?.credentialGroup ?? '';
      if (group !== '') {
        const donor: RemoteHost | undefined = this.srv.getAllHosts().find((candidate: RemoteHost): boolean =>
          candidate.userId === host.userId && !candidate.locked && candidate.protocol === 'rustdesk' &&
          candidate.rustdeskDirectEnabled && candidate.rustdeskAuthMode === 'password' &&
          candidate.rustdeskPasswordMode === 1 && candidate.password.trim().length > 0 &&
          TV_COMPUTER_PRESETS.some((preset: TvComputerPreset): boolean =>
            preset.credentialGroup === group && preset.address === candidate.rustdeskDirectHost &&
            preset.port === candidate.rustdeskDirectPort));
        if (donor !== undefined) { password = donor.password; }
      }
    }
    if (password.trim().length === 0) { return false; }
    // Called only after the standard host-lock and account-scope checks.
    // The server still authenticates the saved password; errors open the normal dialog.
    const selected: RemoteHost = host.runtimeClone();
    copyRustDeskPeerTwoFactorRuntime(host, selected);
    selected.password = password;
    this.pendingHost = selected;
    this.rustDeskSessionPassword = password;
    this.rustDeskSessionRememberPassword = true;
    this.rustDeskSessionPasswordMode = 1;
    this.rustDeskSessionAuthChoice = 'password';
    this.connectionError = '';
    this.connectionErrorDetail = '';
    this.connecting = true;
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV using saved permanent credential through normal authentication');
    this.tryStartConnect();
    return true;
  }
