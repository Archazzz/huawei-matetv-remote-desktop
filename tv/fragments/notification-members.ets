  @StorageLink('screenLinkNotificationsRevision') @Watch('mateTvNotificationClick')
  private mateTvNotificationRevision: number = 0;

  private mateTvNotificationClick(): void {
    if (!this.mateTvMode || this.currentAbilityBackgroundState()) { return; }
    const notifications: TvNotificationService = TvNotificationService.getInstance();
    const activeHost: string = this.pendingHost?.id ?? this.hostId;
    const action: string = notifications.routeAction(activeHost, true, this.mateTvLeaving);
    if (action === 'same') {
      notifications.consume();
      if (this.bgRestorePending) { this.restoreFromBackground(); }
    } else if (action === 'leave') {
      // Keep the pending event until the old native session acknowledges teardown.
      this.mateTvLeaveSession();
    }
  }
