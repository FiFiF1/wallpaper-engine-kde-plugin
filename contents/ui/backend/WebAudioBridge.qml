import QtQuick 2.5
import com.github.catsout.wallpaperEngineKde 1.2

// Isolated in its own file (rather than inline in QtWebView.qml) so it can be
// loaded through a Loader gated on hasLib: this is the only place a web
// wallpaper backend touches the native plugin module, and a plain top-level
// "import com.github.catsout.wallpaperEngineKde" in QtWebView.qml itself would
// make EVERY web wallpaper hard-depend on the native library being installed
// (currently only scene wallpapers do - the native bundle is a separate,
// sometimes-missing install; see wekde-crashguard-self-heal memory). A Loader
// whose source fails to resolve just reports Loader.Error, it does not break
// the parent document, so this keeps that failure contained to "no reactive
// audio" instead of "web wallpapers stop working".
Item {
    id: bridge
    // The QtObject exposing signal sigAudio(var audioArray) - see webobj in
    // QtWebView.qml.
    property var target

    WebAudioSpectrum { id: spec }

    Timer {
        // ~20Hz: plenty smooth for a visualizer (the page's own
        // requestAnimationFrame does the actual frame interpolation), and
        // AudioCapture's own analysis is cached/throttled well above this
        // rate internally, so this costs nothing extra.
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (bridge.target) bridge.target.sigAudio(spec.spectrum());
        }
    }
}
