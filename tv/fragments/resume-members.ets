  private mateTvResumeEpoch: number = 0;
  private mateTvResumeBackground: boolean = false;
  private mateTvReconnectHost: string = '';
  private mateTvReconnectScope: string = '';
  private mateTvReconnectScopeGeneration: number = -1;
  private mateTvReconnectTerminal: boolean = false;
  private mateTvResumeNeedsFreshSession: boolean = false;
  private mateTvDetachDeadlineTimer: number = -1;

  private mateTvClearDetachDeadline(): void {
    if (this.mateTvDetachDeadlineTimer >= 0) {
      clearTimeout(this.mateTvDetachDeadlineTimer);
      this.mateTvDetachDeadlineTimer = -1;
    }
  }

  private mateTvWatchDetachDeadline(sessionId: number, attemptId: number): void {
    if (!this.mateTvMode || !this.mateTvResumeNeedsFreshSession ||
        this.mateTvDetachDeadlineTimer >= 0) { return; }
    const epoch: number = this.mateTvResumeEpoch;
    this.mateTvDetachDeadlineTimer = setTimeout((): void => {
      this.mateTvDetachDeadlineTimer = -1;
      if (this.sessionId !== sessionId || this.connectAttemptId !== attemptId ||
          this.mateTvResumeEpoch !== epoch || this.currentAbilityBackgroundState() ||
          this.mateTvLeaving || this.backgroundDetachPromise === null) { return; }
      // Never race native/PIP ownership just to meet a UI deadline. Expose a
      // bounded failure while the existing terminal barrier retains the slot.
      this.connecting = false;
      this.connectionProgressMessage = '';
      this.connectionError = '恢复准备超时，请返回电脑列表后重试';
      try { promptAction.showToast({ message: this.connectionError, duration: 3000 }); } catch (_) {}
      hilog.warn(RD_DOMAIN, RD_TAG, 'MateTV foreground detach barrier timeout; native ownership retained');
    }, 10000);
  }

  private mateTvCancelResumeReconnect(): void {
    this.mateTvClearDetachDeadline();
    this.mateTvResumeNeedsFreshSession = false;
    this.mateTvReconnectHost = '';
    this.mateTvReconnectScope = '';
    this.mateTvReconnectScopeGeneration = -1;
    this.mateTvReconnectTerminal = false;
  }

  private mateTvObserveLifecycle(background: boolean): void {
    if (background !== this.mateTvResumeBackground) {
      this.mateTvResumeBackground = background;
      this.mateTvResumeEpoch++;
      if (background && this.mateTvMode && this.connected && this.sessionId > 0 &&
          this.pendingHost?.protocol === 'rustdesk') {
        this.mateTvResumeNeedsFreshSession = true;
      }
    }
    if (background) { this.mateTvClearDetachDeadline(); }
    // An in-flight native teardown must finish. Keep only its host/scope intent;
    // routing stays suspended until a later foreground event, without a timer.
  }

  private mateTvReconnectPreservedSession(): boolean {
    if (!this.mateTvMode || !this.mateTvResumeNeedsFreshSession ||
        this.pendingHost?.protocol !== 'rustdesk') { return false; }
    if (this.currentAbilityBackgroundState() || this.mateTvLeaving ||
        this.pcWindowHandoffStarted || this.pcWindowHandoffComplete ||
        this.sessionId <= 0 || !this.connected) { return true; }
    if (this.backgroundDetachPromise !== null) { return true; }
    if (!this.registryRestoreAdoptionIsCurrent()) {
      this.mateTvResumeNeedsFreshSession = false;
      this.abandonSupersededRegistryRestore();
      return true;
    }
    // This is an Ability background/foreground transition, never an input
    // focus or settings/IME transition. Do not reuse its detached video chain.
    this.mateTvResumeNeedsFreshSession = false;
    this.mateTvClearDetachDeadline();
    this.mateTvQueueResumeReconnect('ability-foreground');
    return true;
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
    this.mateTvQueueResumeReconnect(reason);
    return true;
  }

  private mateTvQueueResumeReconnect(reason: string): void {
    if (this.mateTvReconnectHost.length > 0 || this.pendingHost === null) { return; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.mateTvReconnectHost = this.pendingHost.id;
    this.mateTvReconnectScope = scope.ownerScopeId;
    this.mateTvReconnectScopeGeneration = scope.generation;
    this.clearBackgroundRenderRetry();
    this.clearPipRestoreRetry();
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV foreground releasing preserved session reason=' + reason);
    // Native terminal receipt releases the single-session slot before navigation.
    this.disconnectAndCleanup('matetv-background-reconnect');
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
