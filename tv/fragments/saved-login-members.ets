  private mateTvTrySavedPassword(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!this.mateTvMode || host === null || host.protocol !== 'rustdesk' ||
        host.rustdeskPasswordMode !== 1 || host.rustdeskAuthMode === 'request_approval' ||
        host.password.trim().length === 0 || this.cleanupStarted ||
        this.currentAbilityBackgroundState() || (crypto.isSetupComplete() && !crypto.isReady())) {
      return false;
    }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    // An unfinished edited draft must still be reviewed in the ordinary dialog.
    if (this.rustDeskAuthDrafts.load(scope.ownerScopeId, scope.generation, host.id) !== null) { return false; }
    // Called only after the standard host-lock and account-scope checks.
    // The server still authenticates the saved password; errors open the normal dialog.
    this.rustDeskSessionPassword = host.password;
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
