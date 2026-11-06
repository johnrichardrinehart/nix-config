package dev.johnrinehart.mediaseek;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;
import java.util.List;

/**
 * Turns held Fast Forward / Rewind media keys into repeated seeks for players
 * that accept seekTo but not fast-forward/rewind (for example YouTube Music).
 * Players that advertise fast-forward/rewind get the key unchanged.
 */
public final class SeekService extends AccessibilityService {
    private static final String TAG = "MediaSeek";
    private static final long STEP_MS = 10_000;
    private static final long REPEAT_MS = 300;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaController controller;
    private int heldKey = KeyEvent.KEYCODE_UNKNOWN;
    private long direction;
    private long lastTarget = -1;
    private long lastSeekAt;

    private final Runnable repeat = new Runnable() {
        @Override
        public void run() {
            seekStep();
            handler.postDelayed(this, REPEAT_MS);
        }
    };

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        int key = event.getKeyCode();
        if (key != KeyEvent.KEYCODE_MEDIA_FAST_FORWARD && key != KeyEvent.KEYCODE_MEDIA_REWIND) {
            return false;
        }
        if (event.getAction() == KeyEvent.ACTION_UP) {
            if (key != heldKey) {
                return false;
            }
            stop();
            return true;
        }
        if (key == heldKey) {
            return true; // Key repeat: the handler already repeats.
        }
        MediaController target = activeController();
        if (target == null || handlesNatively(target, key)) {
            Log.d(TAG, "pass through to " + (target == null ? "no session" : target.getPackageName()));
            return false;
        }
        stop();
        controller = target;
        heldKey = key;
        direction = key == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD ? STEP_MS : -STEP_MS;
        lastTarget = -1;
        repeat.run();
        return true;
    }

    private void stop() {
        handler.removeCallbacks(repeat);
        heldKey = KeyEvent.KEYCODE_UNKNOWN;
        controller = null;
    }

    private void seekStep() {
        PlaybackState state = controller.getPlaybackState();
        if (state == null) {
            stop();
            return;
        }
        long now = SystemClock.elapsedRealtime();
        boolean playing = state.getState() == PlaybackState.STATE_PLAYING;
        float speed = playing ? state.getPlaybackSpeed() : 0f;
        long base;
        if (lastTarget >= 0) {
            // Later steps of one hold: players report the new position late
            // (YouTube Music sends fresh update times with the old position).
            base = lastTarget + (long) ((now - lastSeekAt) * speed);
        } else {
            base = state.getPosition() + (long) ((now - state.getLastPositionUpdateTime()) * speed);
        }
        long position = Math.max(0, base + direction);
        MediaMetadata metadata = controller.getMetadata();
        long duration = metadata == null ? 0 : metadata.getLong(MediaMetadata.METADATA_KEY_DURATION);
        if (duration > 0) {
            position = Math.min(position, duration - 1000);
        }
        controller.getTransportControls().seekTo(position);
        Log.d(TAG, controller.getPackageName() + " seekTo " + position);
        lastTarget = position;
        lastSeekAt = now;
    }

    private MediaController activeController() {
        MediaSessionManager manager = getSystemService(MediaSessionManager.class);
        List<MediaController> sessions;
        try {
            sessions = manager.getActiveSessions(new ComponentName(this, SessionListener.class));
        } catch (SecurityException e) {
            Log.w(TAG, "notification listener access is not granted", e);
            return null;
        }
        for (MediaController session : sessions) {
            PlaybackState state = session.getPlaybackState();
            if (state != null && state.getState() == PlaybackState.STATE_PLAYING) {
                return session;
            }
        }
        return sessions.isEmpty() ? null : sessions.get(0);
    }

    private static boolean handlesNatively(MediaController session, int key) {
        PlaybackState state = session.getPlaybackState();
        if (state == null || (state.getActions() & PlaybackState.ACTION_SEEK_TO) == 0) {
            return true;
        }
        long action = key == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                ? PlaybackState.ACTION_FAST_FORWARD
                : PlaybackState.ACTION_REWIND;
        return (state.getActions() & action) != 0;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {
        stop();
    }
}
