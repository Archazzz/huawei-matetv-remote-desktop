  private mateTvVideoOwner: string = '';
  private mateTvVideoReceived: number = 0;
  private mateTvVideoPresented: number = 0;
  private mateTvVideoProgressAt: number = 0;
  private mateTvVideoRecoveryAt: number = 0;
  private mateTvVideoRecoveries: number = 0;

  private mateTvCheckVideoProgress(): void {
    if (!this.mateTvMode || !this.connected || this.sessionId <= 0 ||
        !this.remoteKeyboardForeground() || !this.surfaceReady || this.mateTvLeaving ||
        this.rustDeskDisplaySwitchState.inputBlocked) {
      this.mateTvVideoOwner = '';
      return;
    }
    const stats: RustDeskDiagnosticsSnapshot = this.loader.getSessionDiagnostics(this.sessionId);
    if (!stats.sessionActive || stats.sessionId !== this.sessionId) { return; }
    const now: number = Date.now();
    const owner: string = this.sessionId.toString() + ':' + this.connectAttemptId.toString() + ':' +
      (stats.decoderGeneration ?? 0).toString() + ':' + (stats.rendererGeneration ?? 0).toString() + ':' +
      stats.width.toString() + ':' + stats.height.toString();
    if (this.mateTvVideoOwner !== owner || stats.receivedFrames < this.mateTvVideoReceived ||
        stats.presentedFrames < this.mateTvVideoPresented) {
      this.mateTvVideoOwner = owner;
      this.mateTvVideoReceived = stats.receivedFrames;
      this.mateTvVideoPresented = stats.presentedFrames;
      this.mateTvVideoProgressAt = now;
      // Keep the recovery budget across decoder recreation in the same page.
      return;
    }
    const receiving: boolean = stats.receivedFrames > this.mateTvVideoReceived;
    const presenting: boolean = stats.presentedFrames > this.mateTvVideoPresented;
    this.mateTvVideoReceived = stats.receivedFrames;
    this.mateTvVideoPresented = stats.presentedFrames;
    if (presenting || !receiving) {
      this.mateTvVideoProgressAt = now;
      if (presenting && now - this.mateTvVideoRecoveryAt > 30000) { this.mateTvVideoRecoveries = 0; }
      return;
    }
    if (now - this.mateTvVideoProgressAt < 4000 || now - this.mateTvVideoRecoveryAt < 10000 ||
        this.mateTvVideoRecoveries >= 2) { return; }
    this.mateTvVideoRecoveries++;
    this.mateTvVideoRecoveryAt = now;
    const armed: boolean = this.mateTvVideoRecoveries > 1 ? this.loader.requestDecoderRecovery() : false;
    const refresh = this.loader.requestFrameRefresh();
    hilog.warn(RD_DOMAIN, RD_TAG, 'MateTV presentation stalled received=' + stats.receivedFrames.toString() +
      ' presented=' + stats.presentedFrames.toString() + ' attempt=' + this.mateTvVideoRecoveries.toString() +
      ' decoderRecovery=' + armed.toString() + ' refresh=' + refresh.ok.toString());
  }
