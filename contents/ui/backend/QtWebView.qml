import QtQuick 2.5
import QtWebEngine 1.10
import QtWebChannel 1.10
import ".."
import "../js/utils.mjs" as Utils

Item {
    id: webItem
    anchors.fill: parent
    property alias source: web.url
    property bool hasLib: background.hasLib
    property int fps: background.fps
    property var readfile

    onFpsChanged: {
        if(webobj.loaded) {
            webobj.generalProperties.fps = webItem.fps;
            webobj.sigGeneralProperties(webobj.sigGeneralProperties);
        }
    }

    Image {
        id: pauseImage
        anchors.fill: parent
        visible: true
        enabled: false
    }
    // Feeds webobj.sigAudio from the native AudioCapture (system audio ->
    // FFT), so window.wallpaperRegisterAudioListener callbacks in the page
    // actually receive data - previously sigAudio was declared and consumed
    // (see below and main.js of any audio-reactive web wallpaper) but never
    // emitted from anywhere, so every such wallpaper sat permanently idle
    // regardless of what was playing. Loaded by file path (matching the same
    // hasLib-gated pattern main.qml uses for backend/Scene.qml), not a
    // top-level import in this file, so a missing native bundle degrades to
    // "no reactive audio" rather than breaking web wallpapers outright - a
    // Loader whose source fails to resolve reports Loader.Error without
    // affecting this document. See WebAudioBridge.qml.
    Loader {
        id: audioLoader
        source: webItem.hasLib ? "WebAudioBridge.qml" : ""
        onLoaded: audioLoader.item.target = webobj
    }

    QtObject {
        id: webobj
        WebChannel.id: "wpeQml"
        signal sigGeneralProperties(var properties)
        signal sigUserProperties(var properties)
        signal sigAudio(var audioArray)
        property bool loaded: false
        property var userProperties 
        property var generalProperties
        onLoadedChanged: {
            if(!webobj.generalProperties)
                webobj.generalProperties = {fps: 24};
            webobj.sigGeneralProperties(webobj.generalProperties);
            // readfile() returns a Promise (see Pyext.qml) -- it does not take a
            // callback. Calling it as readfile(path, cb) silently discards both
            // the returned Promise and the never-invoked cb, so user properties
            // (e.g. this wallpaper's own introanimation/modelresolution/etc.)
            // never reached the page. That left every web wallpaper stuck
            // without its properties -- some (like this one) depend on a
            // property just to start rendering at all, so they stayed black.
            const _pjPath = Common.urlNative(background.getWorkshopIDPath()) + "/project.json";
            readfile(_pjPath).then((text) => {
                const json = Utils.parseJson(text);
                if (!json || !json.general || !json.general.properties) {
                    console.error("wpe: project.json missing general.properties at " + _pjPath);
                    return;
                }
                webobj.userProperties = json.general.properties;
                webobj.sigUserProperties(webobj.userProperties);
            }).catch((e) => {
                console.error("wpe: failed to read/parse project.json at " + _pjPath + ": " + e);
            });
        }
    }
    WebChannel {
        id: channel
        registeredObjects: [webobj]
    }

    WebEngineView {
    //WebView {
        id: web
        anchors.fill: parent
        enabled: true
        audioMuted: background.mute
        activeFocusOnPress: false
        webChannel: channel

        property bool paused: false
        property bool _init: {
            settings.fullscreenSupportEnabled = true;
            settings.autoLoadIconsForPage = false;
            settings.printElementBackgrounds = false;
            settings.playbackRequiresUserGesture = false;
            settings.pdfViewerEnabled = false;
            settings.showScrollBars = false;

            settings.localContentCanAccessRemoteUrls = true;
            settings.allowGeolocationOnInsecureOrigins = true;
            _init = true;
        }


        //onContextMenuRequested: function(request) {
        //    request.accepted = true;
        //}
        onLoadingChanged: (loadingInfo) => {
            if(loadingInfo.status == WebEngineView.LoadSucceededStatus) {
                // check pause after load
                if(paused) {
                    webItem.play();
                    webItem.pause();
                }
                background.sig_backendFirstFrame('QtWebEngine');
            }
        }

        onPausedChanged: {
            if(paused) {
                pauseTimer.start();
            }
            else {
                web.visible = true;
                web.lifecycleState = WebEngineView.LifecycleState.Active;
                pauseImage.visible = false;
            }
        }

        // qwebchannel.js is normally a Qt resource, but not every Qt build
        // exposes it under that qrc path (Fedora's Qt6 ships it only as a plain
        // file under /usr/share). When it is missing the injection silently does
        // nothing, QWebChannel stays undefined, and every web wallpaper loses
        // its user properties.
        //
        // WebEngine resolves sourceUrl itself, so instead of probing for the
        // file (QML's XMLHttpRequest refuses these reads) we register the known
        // locations. Whichever resolves defines QWebChannel; the others load
        // nothing, and a redefinition is harmless.
        //
        // Assign to userScripts.collection rather than calling insert(): in Qt6
        // webEngineScript is a structured value type, and only property
        // assignment converts these plain JS objects into it. insert() silently
        // accepted them and injected nothing, which is why web wallpapers lost
        // their properties entirely.
        Component.onCompleted: {
            userScripts.collection = [
                {
                    injectionPoint: WebEngineScript.DocumentCreation,
                    worldId: WebEngineScript.MainWorld,
                    name: "QWebChannelQrc",
                    sourceUrl: "qrc:///qtwebchannel/qwebchannel.js"
                },
                {
                    injectionPoint: WebEngineScript.DocumentCreation,
                    worldId: WebEngineScript.MainWorld,
                    name: "QWebChannelQt6",
                    sourceUrl: "file:///usr/share/qt6/webchannel/qwebchannel.js"
                },
                {
                    injectionPoint: WebEngineScript.DocumentCreation,
                    worldId: WebEngineScript.MainWorld,
                    name: "QWebChannelQt5",
                    sourceUrl: "file:///usr/share/qt5/qtwebchannel/qwebchannel.js"
                },
                {
                    injectionPoint: WebEngineScript.DocumentCreation,
                    worldId: WebEngineScript.MainWorld,
                    name: "Audio",
                    sourceCode: `
                        window.wallpaperRegisterAudioListener = function(listener) {
                            if(window.wpeQml)
                                window.wpeQml.sigAudio.connect(listener);
                            else
                                window.wallpaperRAed = listener;
                        }
                    `
                },
                {
                    worldId: WebEngineScript.MainWorld,
                    injectionPoint: WebEngineScript.Deferred,
                    name: "ObjectInjector",
                    sourceCode: `
                        new QWebChannel(qt.webChannelTransport, function(channel) {
                            window.wpeQml = channel.objects.wpeQml;
                            const wpeQml = window.wpeQml;
                            const propertyListener = window.wallpaperPropertyListener;
                            if(window.wallpaperRAed)
                                wpeQml.sigAudio.connect(window.wallpaperRAed);
                            if(propertyListener) {
                                if(propertyListener.applyGeneralProperties)
                                    wpeQml.sigGeneralProperties.connect(propertyListener.applyGeneralProperties);
                                if(propertyListener.applyUserProperties)
                                    wpeQml.sigUserProperties.connect(propertyListener.applyUserProperties);
                            }
                            wpeQml.loaded = true;
                        });
                        document.getElementsByTagName('body')[0].ondragstart = function() { return false; }
                        `
                }
            ];
            background.nowBackend = 'QtWebEngine';
        }

    }
    // There is no signal for frame complete, so use timer to make sure not black result
    Timer{
        id: pauseTimer
        running: false
        repeat: false
        interval: 300 
        onTriggered: {
            // only check paused status on timer, not set
            // this is async
            web.grabToImage(function(result) {
                // check for paused again, make sure web is visible
                if(web.paused == false || web.visible == false) return;
                pauseImage.source = result.url;
                pauseImage.visible = true;
                web.visible = false;
                web.lifecycleState = WebEngineView.LifecycleState.Frozen;
            });
        }   
    }
    Component.onCompleted: {
    //target: web.children[0] ? web.children[0] : null
    }

    function play(){
        web.paused = false;
    }
    function pause(){
        // Set status first
        web.paused = true;
    }
    function getMouseTarget() {
        web.activeFocusOnPress = true;
        return Qt.binding(function() { return web.children[0]; })
    }
}
