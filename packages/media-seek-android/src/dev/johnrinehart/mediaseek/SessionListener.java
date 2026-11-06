package dev.johnrinehart.mediaseek;

import android.service.notification.NotificationListenerService;

/** Exists only so that notification listener access lets SeekService read media sessions. */
public final class SessionListener extends NotificationListenerService {}
