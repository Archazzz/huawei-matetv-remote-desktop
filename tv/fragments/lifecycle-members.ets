  @State private mateTvLeaving: boolean = false;

  private mateTvLeaveSession(): void {
    if (this.mateTvLeaving) { return; }
    this.mateTvCancelDrag();
    this.mateTvCloseText();
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
