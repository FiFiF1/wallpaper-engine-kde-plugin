import QtQuick 2.12
import QtQuick.Effects
import com.github.catsout.wallpaperEngineKde 1.2
import QtQuick.Window 2.2
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

WallpaperItem {
Rectangle {
    id: background
    anchors.fill: parent
    color: wallpaper.configuration.BackgroundColor
    
    property string steamlibrary: Qt.resolvedUrl(wallpaper.configuration.SteamLibraryPath).toString()
    property string source: Qt.resolvedUrl(wallpaper.configuration.WallpaperSource).toString()

    property string filterStr: wallpaper.configuration.FilterStr

    property int    videoBackend: wallpaper.configuration.VideoBackend
    property int    switchTimer: wallpaper.configuration.SwitchTimer
    // Overridable per wallpaper (a heavy scene may want a lower frame cap than
    // the rest of the library), falling back to the global setting.
    property int    fps: get_opt_value('fps', wallpaper.configuration.Fps)

    property bool   randomizeWallpaper: wallpaper.configuration.RandomizeWallpaper
    property bool   noRandomWhilePaused: wallpaper.configuration.NoRandomWhilePaused
    property bool   mouseInput: get_opt_value('mouse_input', wallpaper.configuration.MouseInput)
    property bool   mpvStats: wallpaper.configuration.MpvStats

    property bool   pauseOnBatPower: wallpaper.configuration.PauseOnBatPower
    property int    pauseBatPercent: wallpaper.configuration.PauseBatPercent

    
    property var curOpt: ({})
    property string workshopid: {
        const wid = wallpaper.configuration.WallpaperWorkShopId;
        pyext.read_wallpaper_config(wid).then((res) => this.curOpt = res);
        return wid;
    }
    function get_opt_value(key, def) {
        if(curOpt.hasOwnProperty(key))
            return curOpt[key];
        return def;
    }
    property int    displayMode: get_opt_value('display_mode', wallpaper.configuration.DisplayMode)
    property bool   mute: get_opt_value('mute_audio', wallpaper.configuration.MuteAudio)
    property int    volume: get_opt_value('volume', wallpaper.configuration.Volume)
    property real    speed: get_opt_value('speed', wallpaper.configuration.Speed)

    // ---- per-wallpaper picture adjustments ---------------------------------
    // Wallpaper Engine's position / flip / filtering controls. These are applied
    // to the backend item on the QML side rather than pushed into a backend, so
    // one implementation covers scene, video and web wallpapers alike - the
    // native SceneViewer exposes no knobs for any of this.
    //
    // Stored per wallpaper only (no global default key): a crop or a hue shift
    // that suits one wallpaper is meaningless for the next. Neutral values here
    // are the "off" state and cost nothing.
    property bool  picFlipH:      get_opt_value('flip_h', false)
    property bool  picFlipV:      get_opt_value('flip_v', false)
    property int   picRotate:     get_opt_value('rotate', 0)
    property real  picZoom:       get_opt_value('zoom', 100) / 100.0
    property int   picOffsetX:    get_opt_value('offset_x', 0)
    property int   picOffsetY:    get_opt_value('offset_y', 0)
    property real  picBrightness: get_opt_value('brightness', 0) / 100.0
    property real  picContrast:   get_opt_value('contrast', 0) / 100.0
    property real  picSaturation: get_opt_value('saturation', 0) / 100.0
    property int   picBlur:       get_opt_value('blur', 0)

    // Layering the wallpaper into a texture costs a full extra render pass every
    // frame, so only do it when a colour filter is actually in use. Geometry
    // (flip/rotate/zoom/offset) is a plain transform and needs no layer.
    readonly property bool picFiltered: picBrightness !== 0 || picContrast !== 0
                                     || picSaturation !== 0 || picBlur > 0

    property int    perOptChanged: wallpaper.configuration.PerOptChanged
    onPerOptChangedChanged: {
        pyext.read_wallpaper_config(workshopid).then((res) => this.curOpt = res);
    }

    // auto pause
    property bool   ok: !windowModel.reqPause && !powerSource.reqPause

    // detect TTY switch and pause wallpaper(s)
    TTYSwitchMonitor {
        id: ttyMonitor
        onTtySwitch: {
            if (sleep) {
                console.log("Preparing for sleep (possibly a VT switch)");
                this.pause();
            } else {
                console.log("Waking up (VT switch back)");
                this.play();
            }
        }
    }

    property string nowBackend: ""

    property var mouseHooker
    property bool hasLib: Common.checklib_wallpaper(background)

    property var customConf: Common.loadCustomConf(wallpaper.configuration.CustomConf)

    property string wallpaperPath
    property string wallpaperType

    signal sig_backendFirstFrame(string backname)
    function onBackendFirstFrame(backname) {
        console.error(`backend ${backname} first frame`);
        if (wallpaper.hasOwnProperty('accentColor'))
            wallpaper.accentColorChanged();
    }

    // ---- crash breadcrumb --------------------------------------------------
    // A scene can crash the native renderer - and with it the whole shell -
    // while it parses (a pathological shader, say). Just before handing a scene
    // to the backend we drop a marker file; a Timer removes it once the scene
    // has clearly survived loading. A scene that crashed the shell mid-parse
    // dies before that Timer fires, so its marker is left behind and
    // wekde-crashguard can name exactly which wallpaper to disable next start.
    //
    // Everything here runs on the GUI thread only. IMPORTANT: never clear this
    // from a handler on sig_backendFirstFrame - that signal is emitted from the
    // native render thread, and running QML there crashes the shell. The Timer
    // (a plain GUI-thread timeout) is deliberately used instead.
    readonly property string crumbDir: "$HOME/.local/share/wekde/loading"
    property string pendingCrumbWid: ""
    Plasma5Support.DataSource {
        id: crumbRunner
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => disconnectSource(source)
        function run(cmd) { connectSource(cmd); }
    }
    function markSceneLoading(wid) {
        const w = String(wid).replace(/[^0-9]/g, "");   // ids are numeric
        if(!w) return;
        // A previous scene that reached this point clearly did not crash the
        // shell, so drop its marker before tracking the new one.
        if(background.pendingCrumbWid && background.pendingCrumbWid !== w)
            background.clearSceneLoading(background.pendingCrumbWid);
        background.pendingCrumbWid = w;
        crumbRunner.run(`mkdir -p "${background.crumbDir}" && : > "${background.crumbDir}/${w}"`);
        crumbClearTimer.restart();
    }
    function clearSceneLoading(wid) {
        const w = String(wid).replace(/[^0-9]/g, "");
        if(!w) return;
        crumbRunner.run(`rm -f "${background.crumbDir}/${w}"`);
    }
    Timer {
        id: crumbClearTimer
        // Scene shader crashes happen within a second or two of loading; a scene
        // still alive well past that has loaded fine, so retire its marker.
        interval: 15000
        onTriggered: {
            if(background.pendingCrumbWid) {
                background.clearSceneLoading(background.pendingCrumbWid);
                background.pendingCrumbWid = "";
            }
        }
    }

    Component.onDestruction: {
        if(mouseHooker) {
            mouseHooker.destroy();
        }
    }

    function applySource() {
        const { path, type } = Common.unpackWallpaperSource(source);
        const path_changed = background.wallpaperPath !== path;
        const type_changed = background.wallpaperType !== type;
        const is_infobackend = background.nowBackend === "InfoShow";

        if(type_changed) wallpaperType = type;
        if(path_changed) wallpaperPath = path;

        if(type_changed || is_infobackend || !source) {
            loadBackend();
        } else if(path_changed) {
            backendLoader.item.source = path;
        }

        sourceCallback();
    }

    function getWorkshopIDPath() {
        return Common.getWorkshopDir(this.steamlibrary) + `/${this.workshopid}`;
    }

    onMouseInputChanged: {
        if(this.mouseInput) {
            hookTimer.start();
        }
        else if(this.mouseHooker) {
            this.mouseHooker.target = null;
            this.mouseHooker.destroy;
            this.mouseHooker = null;
        }
    }

    Timer {
        id: hookTimer
        running: true
        repeat: false
        interval: 2000
        property int tryTimes: 0
        onTriggered: {
            tryTimes++;
            if(tryTimes >= 10 || !background.hasLib || !background.mouseInput) return;
            if(background.mouseHooker) return;
            background.hookMouse();
        }
        Component.onCompleted: {
            background.hookMouse.connect(background.hookMouseSlot);
        }
    }
    signal hookMouse
    function hookMouseSlot() {
        if(!background.doHookMouse()) {
            hookTimer.start();
        } else {
            hookTimer.tryTimes = 0;
        }
    }
    function doHookMouse() {
        if(background.Window) {
            const screenArea = Common.findItem(Window.contentItem, "MouseEventListener");
            if(screenArea === null)
                return false;
            const screenGrid = Common.findItem(screenArea, "QQuickGridView");
            if(screenGrid === null)
                return false;
            console.error(screenGrid);
            if(background.mouseHooker) background.mouseHooker.destroy();
            background.mouseHooker = Qt.createQmlObject(`import QtQuick 2.12;
                    import com.github.catsout.wallpaperEngineKde 1.2
                    MouseGrabber {
                        z: -1
                        anchors.fill: parent
                    }
            `, screenGrid);
            return true;
       }
       return false;
    }

    WindowModel {
        id: windowModel
        screenGeometry: wallpaper.parent.screenGeometry
        filterByScreen: wallpaper.configuration.PauseFilterByScreen
        modePlay: wallpaper.configuration.PauseMode
        resumeTime: wallpaper.configuration.ResumeTime
    }

    PowerSource {
        id: powerSource
        readonly property bool reqPause: {
            (background.pauseOnBatPower && (st_battery_state == 'NoCharge' || st_battery_state == 'Discharging')) ||
            (background.pauseBatPercent !== 0 && st_battery_has && st_battery_percent < background.pauseBatPercent)
        }
    }

    Pyext {
        id: pyext
    }
    WallpaperListModel {
        id: wpListModel
        enabled: background.randomizeWallpaper
        workshopDirs: Common.getProjectDirs(background.steamlibrary)
        globalConfigPath: Common.getGlobalConfigPath(background.steamlibrary)
        filterStr: background.filterStr
        initItemOp: (item) => {
            if(!background.customConf) return;
            item.favor = background.customConf.favor.has(item.workshopid);
        }
        readfile: pyext.readfile

        function changeWallpaper(index) {
            if(this.model.count === 0) return;
            const model = this.model.get(index);
            wallpaper.configuration.WallpaperWorkShopId = model.workshopid;
            wallpaper.configuration.WallpaperSource = Common.packWallpaperSource(model);
        }
    }
    Timer {
        id: randomizeTimer
        running: background.randomizeWallpaper
        interval: background.switchTimer * 1000 * 60
        repeat: true
        onTriggered: {
            if(!(background.noRandomWhilePaused && !background.ok)) {
                const i = Math.round(Math.random() * wpListModel.model.count);
                wpListModel.changeWallpaper(i);
            }
        }
    }

    // lauch pause time to avoid freezing
    Timer {
        id: lauchPauseTimer
        running: false
        repeat: false
        interval: 300
        onTriggered: {
            backendLoader.item.pause();
            playTimer.start();
        }
    }
    Timer{
        id: playTimer
        running: false
        repeat: false
        interval: 5000
        onTriggered: { background.autoPause(); }
    }
    // lauch pause end

    // As always autoplay for refresh lastframe, sourceChange need autoPause
    // need a time for delay, which is needed for refresh
    function sourceCallback() {
        sourcePauseTimer.start();   
    }
    Timer {
        id: sourcePauseTimer
        running: false
        repeat: false
        interval: 200
        onTriggered: background.autoPause();
    }
    // main  
    Item {
        id: backendLoader
        anchors.fill: parent
        property var item: null

        // Flip / rotate / zoom / offset. Anchored to fill the screen, so the
        // pan has to be a Translate rather than an x/y change, which anchors
        // would immediately overwrite.
        transform: [
            Scale {
                origin.x: backendLoader.width / 2
                origin.y: backendLoader.height / 2
                xScale: (background.picFlipH ? -1 : 1) * background.picZoom
                yScale: (background.picFlipV ? -1 : 1) * background.picZoom
            },
            Rotation {
                origin.x: backendLoader.width / 2
                origin.y: backendLoader.height / 2
                angle: background.picRotate
            },
            Translate {
                x: background.picOffsetX / 100.0 * backendLoader.width
                y: background.picOffsetY / 100.0 * backendLoader.height
            }
        ]

        // Rendered into a texture for picFx to sample. layer.effect is NOT used
        // here: MultiEffect is not a ShaderEffect, and as a layer effect it is
        // accepted silently and then does nothing at all.
        layer.enabled: background.picFiltered

        signal loaded

        Component.onCompleted: {
            if(background.hasLib) {
                this.loaded.connect(this.changeMouseTarget);
                background.mouseHookerChanged.connect(this.changeMouseTarget);
            }
        }
        Component.onDestruction: {
            if(this.item) this.item.destroy();
        }
        function load(url, properties) {
            const com = Qt.createComponent(url);
            if(com.status === Component.Ready) {
                if(this.item) this.item.destroy(100);
                this.item = null;
                try {
                    this.item = com.createObject(this, properties);
                } catch(e) {
                    this.loadInfoShow(e);
                    return;
                }
                this.loaded();
            } else if(com.status == Component.Error) {
                this.loadInfoShow(com.errorString());
            }
        }
        function loadInfoShow(info) {
            this.load("backend/InfoShow.qml", {
                wid: background.workshopid,
                type: background.wallpaperType,
                info: info
            });
        }
        function changeMouseTarget() {
           if(backendLoader.item && background.mouseHooker) {
                let re = backendLoader.item.getMouseTarget();
                if(!re)
                    re = null;
                background.mouseHooker.target = re;
           }
        }
    }

    // Colour filtering. Draws a filtered copy of the wallpaper over the top of
    // it, and only exists when a filter is actually set - with everything at
    // neutral this is invisible and costs nothing.
    //
    // The geometry transform is repeated here rather than shared: layer.enabled
    // captures backendLoader's content *before* its transform, so the filtered
    // copy has to be positioned itself to line up with the unfiltered one.
    // Transform objects cannot be attached to two items either way.
    MultiEffect {
        id: picFx
        anchors.fill: backendLoader
        source: backendLoader
        visible: background.picFiltered

        brightness: background.picBrightness
        contrast: background.picContrast
        saturation: background.picSaturation
        blurEnabled: background.picBlur > 0
        blur: background.picBlur / 100.0
        blurMax: 48

        transform: [
            Scale {
                origin.x: picFx.width / 2
                origin.y: picFx.height / 2
                xScale: (background.picFlipH ? -1 : 1) * background.picZoom
                yScale: (background.picFlipV ? -1 : 1) * background.picZoom
            },
            Rotation {
                origin.x: picFx.width / 2
                origin.y: picFx.height / 2
                angle: background.picRotate
            },
            Translate {
                x: background.picOffsetX / 100.0 * picFx.width
                y: background.picOffsetY / 100.0 * picFx.height
            }
        ]
    }

    function loadBackend() {
        let qmlsource = "";
        let properties = {};

    
        // check source
        if(!background.source) {
            backendLoader.loadInfoShow("Source is empty. The config may be broken.");
            return;
        }
        // choose backend
        switch (background.wallpaperType) {
            case 'video':
                if(background.videoBackend == Common.VideoBackend.Mpv && background.hasLib)
                    qmlsource = "backend/Mpv.qml";
                else qmlsource = "backend/QtMultimedia.qml";
                properties = {};
                break;
            case 'web':
                qmlsource = "backend/QtWebView.qml";
                properties = {readfile: pyext.readfile};
                break;
            case 'scene':
                if(background.hasLib) {
                    qmlsource = "backend/Scene.qml";
                    properties = {"assets": Common.getAssetsPath(steamlibrary)};
                } else {
                    backendLoader.loadInfoShow("Plugin lib not found. To support scene, please compile and install it.");
                    return; 
                }
                break;
            default:
                backendLoader.loadInfoShow("Not supported wallpaper type");
                return; 
        }
        properties['source'] = background.wallpaperPath;
        console.error("load backend: "+qmlsource);
        // Drop a crash breadcrumb right before the native scene backend parses
        // this wallpaper, so a crash mid-parse leaves a marker naming it.
        if(background.wallpaperType === 'scene')
            background.markSceneLoading(background.workshopid);
        backendLoader.load(qmlsource, properties);
        sourceCallback();
    }
   
    function autoPause() {
        background.ok
            ? backendLoader.item.play()
            : backendLoader.item.pause();
    }

    Component.onCompleted: {
        // load first backend
        applySource();

        // background signal connect
        background.videoBackendChanged.connect(loadBackend);
        background.okChanged.connect(autoPause);
        background.sourceChanged.connect(applySource);

        lauchPauseTimer.start();
        randomizeTimer.start();
    }
}
}
