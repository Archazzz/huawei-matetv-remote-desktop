  @State private mateTvLeaving: boolean = false;
  private mateTvRestoreWaitingForDetach: Promise<void> | null = null;

  private restoreFromBackground(): void {
    if (this.currentAbilityBackgroundState() || this.mateTvLeaving) { return; }
    const pending: Promise<void> | null = this.backgroundDetachPromise;
    if (pending === null) {
      this.performForegroundRestore();
      return;
    }
    if (this.mateTvRestoreWaitingForDetach === pending) { return; }
    this.mateTvRestoreWaitingForDetach = pending;
    const sessionId: number = this.sessionId;
    const attemptId: number = this.connectAttemptId;
    hilog.info(RD_DOMAIN, RD_TAG, 'foreground restore waiting for background detach barrier');
    // PIP auto-start can take several seconds. Never reset cleanup/surface
    // state or poll the page surface while that operation can still detach it.
    const resume = (): void => {
      if (this.mateTvRestoreWaitingForDetach !== pending) { return; }
      this.mateTvRestoreWaitingForDetach = null;
      if (this.sessionId !== sessionId || this.connectAttemptId !== attemptId ||
          !this.connected || this.mateTvLeaving || this.currentAbilityBackgroundState() ||
          this.pcWindowHandoffStarted || this.pcWindowHandoffComplete) { return; }
      // Re-enter the gate in case another detach started before this callback.
      // Even a rejected detach must pass the existing PIP terminal barrier.
      if (this.bgRestorePending) { this.restoreFromBackground(); }
    };
    pending.then(resume, (error: Error): void => {
      hilog.warn(RD_DOMAIN, RD_TAG, 'background detach failed before foreground restore: ' + error.message);
      resume();
    });
  }

  private mateTvLeaveSession(): void {
    this.mateTvCancelResumeReconnect();
    this.mateTvStopJoystick();
    if (this.mateTvLeaving) { return; }
    this.mateTvCancelDrag();
    this.mateTvCloseText(false);
    this.mateTvCloseDisplay();
    this.mateTvLeaving = true;
    // A failed/auth-cancelled route may already have completed native teardown.
    if (this.cleanupStarted && this.cleanupDisconnectIdentity === null &&
        this.nativeDisconnectRequestId === 0 && !this.nativeDisconnectPending &&
        this.nativeDisconnectRetryTimer < 0 && this.registryTermination === null &&
        !this.connected && !this.connecting && this.sessionId <= 0) {
      this.mateTvFinishLeave();
      return;
    }
    // Keep this page mounted until finishNativeDisconnect confirms the terminal
    // receipt and releases the registry. A timeout must never free the slot early.
    this.disconnectAndCleanup('matetv-explicit-switch');
  }

  private mateTvFinishLeave(): void {
    if (!this.mateTvMode || !this.mateTvLeaving) { return; }
    this.mateTvLeaving = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV teardown complete; returning to computer list');
    router.back();
  }

  @Builder
  private mateTvLeavingPanel() {
    Column({ space: 16 }) {
      LoadingProgress().width(36).height(36).color('#70E0C2')
      Text('正在断开连接…').fontSize(22).fontColor('#F4F8FA')
      Text('释放完成后返回电脑列表').fontSize(16).fontColor('#B1C2CA')
    }.padding(28).backgroundColor('#192A34').borderRadius(14)
  }
