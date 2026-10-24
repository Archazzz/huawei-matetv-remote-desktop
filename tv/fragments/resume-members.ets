  private mateTvResumeEpoch: number = 0;
  private mateTvResumeBackground: boolean = false;
  private mateTvReconnectHost: string = '';
  private mateTvReconnectScope: string = '';
  private mateTvReconnectScopeGeneration: number = -1;
  private mateTvReconnectTerminal: boolean = false;

  private mateTvCancelResumeReconnect(): void {
    this.mateTvReconnectHost = '';
    this.mateTvReconnectScope = '';
    this.mateTvReconnectScopeGeneration = -1;
    this.mateTvReconnectTerminal = false;
  }

  private mateTvObserveLifecycle(background: boolean): void {
    if (background !== this.mateTvResumeBackground) {
      this.mateTvResumeBackground = background;
      this.mateTvResumeEpoch++;
    }
    // An in-flight native teardown must finish. Keep only its host/scope intent;
    // routing stays suspended until a later foreground event, without a timer.
  }

  private mateTvResumeIsCurrent(sessionId: number, attemptId: number, epoch: number): boolean {
    return this.sessionId === sessionId && this.connectAttemptId === attemptId &&
      this.mateTvResumeEpoch === epoch && !this.currentAbilityBackgroundState() &&
      !this.mateTvLeaving && !this.cleanupStarted &&
      !this.pcWindowHandoffStarted && !this.pcWindowHandoffComplete;
  }

  // Only runs while restoring in the foreground. Background pages create no timer.
  private async mateTvWaitForRestoredFrame(sessionId: number, attemptId: number,
    epoch: number, before: RustDeskDiagnosticsSnapshot): Promise<boolean> {
    const start: number = Date.now();
    let refreshed: boolean = false;
    while (Date.now() - start < 12000) {
      if (!this.mateTvResumeIsCurrent(sessionId, attemptId, epoch)) { return false; }
      const state: number = this.loader.getConnectionState(sessionId);
      if (state === 0 || state === 4) { throw new Error('前台恢复连接已失效'); }
      const current: RustDeskDiagnosticsSnapshot = this.loader.getRustDeskDiagnostics(sessionId);
      const newIngress: boolean = current.receivedFrames > 0 &&
        current.receivedFrames !== before.receivedFrames;
      const newPresentation: boolean = current.presentedFrames > 0 &&
        (current.presentedFrames !== before.presentedFrames ||
        current.rendererGeneration !== before.rendererGeneration);
      if (current.sessionActive && current.sessionId === sessionId && newIngress && newPresentation &&
          current.width > 0 && current.height > 0) {
        hilog.info(RD_DOMAIN, RD_TAG, 'MateTV foreground fresh frame verified elapsedMs=' +
          (Date.now() - start).toString());
        return true;
      }
      if (!refreshed && Date.now() - start >= 5000) {
        refreshed = true;
        // Recreate only if new data reached the decoder without a fresh picture.
        if (newIngress) { this.loader.requestDecoderRecovery(); }
        this.loader.requestFrameRefresh();
        hilog.warn(RD_DOMAIN, RD_TAG, 'MateTV foreground fresh frame recovery requested');
      }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
    }
    if (!this.mateTvResumeIsCurrent(sessionId, attemptId, epoch)) { return false; }
    throw new Error('前台恢复未收到新画面');
  }

  private mateTvReconnectAfterRestoreFailure(sessionId: number, attemptId: number,
    reason: string): boolean {
    if (!this.mateTvMode || this.pendingHost?.protocol !== 'rustdesk') { return false; }
    // Consume a stale TV retry without touching a new session or reviving background UI.
    if (!this.mateTvResumeIsCurrent(sessionId, attemptId, this.mateTvResumeEpoch) ||
        !this.registryRestoreAdoptionIsCurrent()) { return true; }
    if (this.mateTvReconnectHost.length > 0) { return true; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.mateTvReconnectHost = this.pendingHost.id;
    this.mateTvReconnectScope = scope.ownerScopeId;
    this.mateTvReconnectScopeGeneration = scope.generation;
    this.clearBackgroundRenderRetry();
    this.clearPipRestoreRetry();
    hilog.warn(RD_DOMAIN, RD_TAG, 'MateTV foreground recovery exhausted; releasing session reason=' + reason);
    // Native terminal receipt releases the single-session slot before navigation.
    this.disconnectAndCleanup('matetv-background-reconnect');
    return true;
  }

  private mateTvFinishResumeReconnect(): void {
    if (this.mateTvReconnectHost.length === 0) { return; }
    this.mateTvReconnectTerminal = true;
    this.mateTvResumeReconnectOnForeground();
  }

  private mateTvResumeReconnectOnForeground(): boolean {
    const hostId: string = this.mateTvReconnectHost;
    if (hostId.length === 0) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const valid: boolean = this.mateTvMode &&
      !this.mateTvLeaving && !this.pcWindowHandoffStarted && !this.pcWindowHandoffComplete &&
      this.pendingHost?.id === hostId && scope.ownerScopeId === this.mateTvReconnectScope &&
      scope.generation === this.mateTvReconnectScopeGeneration;
    if (!valid) { this.mateTvCancelResumeReconnect(); return false; }
    if (this.currentAbilityBackgroundState() || !this.mateTvReconnectTerminal) { return true; }
    this.mateTvCancelResumeReconnect();
    // Fresh route repeats normal host-lock and credential checks. No password is routed.
    router.replaceUrl({ url: 'pages/RemoteDesktop', params: { hostId: hostId } })
      .catch((): void => { this.connectionError = '恢复连接失败，请返回后重试'; });
    return true;
  }
