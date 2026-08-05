import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.5
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents

import "page"
import "components"

ColumnLayout {
    id: root
    spacing: 5

    // Plasma 6.4's ConfigurationContainmentAppearance.qml injects these two
    // properties into every wallpaper config page. The upstream plugin never
    // declared them, so object creation failed and the picker never loaded.
    // Declaring them (unused) lets the assignment succeed.
    property var configDialog
    property var wallpaperConfiguration



    property string cfg_SteamLibraryPath
    property string cfg_WallpaperWorkShopId
    property string cfg_WallpaperSource
    property string cfg_FilterStr
    property int    cfg_SortMode
    property bool   cfg_SortReverse
    property int    cfg_ThumbScale
    property int    cfg_OptionsWidth

    // Search box text. Deliberately not a cfg_ key: it should reset each time
    // the dialog opens rather than persist into the wallpaper config.
    property string searchStr: ""

    property alias  cfg_Fps:                 settingPage.cfg_Fps
    property alias  cfg_Volume:              settingPage.cfg_Volume
    property alias  cfg_MpvStats:            settingPage.cfg_MpvStats
    property alias  cfg_Speed:               settingPage.cfg_Speed
    property alias  cfg_MuteAudio:           settingPage.cfg_MuteAudio
    property alias  cfg_MouseInput:          settingPage.cfg_MouseInput
    property alias  cfg_ResumeTime:          settingPage.cfg_ResumeTime
    property alias  cfg_SwitchTimer:         settingPage.cfg_SwitchTimer
    property alias  cfg_RandomizeWallpaper:  settingPage.cfg_RandomizeWallpaper
    property alias  cfg_NoRandomWhilePaused: settingPage.cfg_NoRandomWhilePaused
    property alias  cfg_PauseFilterByScreen: settingPage.cfg_PauseFilterByScreen
    property alias  cfg_PauseOnBatPower:     settingPage.cfg_PauseOnBatPower
    property alias  cfg_PauseBatPercent:     settingPage.cfg_PauseBatPercent
    property int    cfg_DisplayMode
    property int    cfg_PauseMode
    property int    cfg_VideoBackend

    property bool   cfg_PerOptChanged

    //property alias  cfg_UseMpv
    //property string cfg_BackgroundColor: "black"
    //property alias  cfg_FilterMode: wallpaperPage.cfg_FilterMode

    property string cfg_CustomConf
    property var customConf: {
        customConf = Common.loadCustomConf(cfg_CustomConf);
    }

    property var iconSizes: {
        if(PlasmaCore.Units) {
            iconSizes = PlasmaCore.Units.iconSizes;
        } else {
            iconSizes = {
                large: 48
            }
        }
    }
    // property var themeWidth: {
    //     if(PlasmaCore.Theme && PlasmaCore.Theme.mSize) {
    //         themeWidth = PlasmaCore.Theme.mSize(theme.defaultFont).width;
    //     } else if(theme) {
    //         themeWidth = theme.mSize(theme.defaultFont).width;
    //     } else {
    //         themeWidth = font.pixelSize;
    //     }
    // }

    property var libcheck: ({
        wallpaper: Common.checklib_wallpaper(root),
        qtwebsockets: Common.checklib_websockets(root),
        qtwebchannel: Common.checklib_webchannel(root)
    })


                    
    property var plugin_info: {
        if(!libcheck.wallpaper) {
            plugin_info = {
                version: "-",
                cache_path: null
            }
        } else {
            plugin_info = Qt.createQmlObject(`
                import QtQuick 2.0;
                import com.github.catsout.wallpaperEngineKde 1.2
                PluginInfo {}
            `, this);
        }
    }

    property var pyext: {
        if(!libcheck.qtwebsockets) {
            pyext = null
        } else {
            pyext = Qt.createQmlObject(`
                import QtQuick 2.0;
                Pyext {}
            `, this);
        }
    }

    function saveConfig() {
        wallpaperPage.saveConfig();
    }

    WallpaperListModel {
        id: wpListModel
        workshopDirs: Common.getProjectDirs(cfg_SteamLibraryPath)
        globalConfigPath: Common.getGlobalConfigPath(cfg_SteamLibraryPath)
        filterStr: cfg_FilterStr
        sortMode: cfg_SortMode
        sortReverse: cfg_SortReverse
        searchStr: root.searchStr
        initItemOp: (item) => {
            if(!root.customConf) return;
            item.favor = root.customConf.favor.has(item.workshopid);
        }
        enabled: Boolean(cfg_SteamLibraryPath)
        readfile: pyext.readfile
    }

    Component.onDestruction: {
        if(this.pyext) this.pyext.destroy();
    }

    function saveCustomConf() {
        // Kept for compatibility, but this only reaches disk on OK/Apply and is
        // per-containment. The shared copy below is the one that counts.
        cfg_CustomConf = Common.prepareCustomConf(this.customConf);
        saveFavorites();
    }

    // ---- shared favourites -------------------------------------------------
    // cfg_CustomConf is stored per containment, so a favourite added while the
    // dialog was open on one monitor was invisible on the others, and was lost
    // outright if the dialog was closed with anything but OK. These go through
    // the python helper into ~/.config/wekde/favorites.json instead: one list
    // for every screen, written the moment a bookmark is clicked.
    property bool _favLoaded: false

    function loadFavorites() {
        if(!pyext || !pyext.ok || root._favLoaded) return;
        pyext.read_favorites().then((ids) => {
            root._favLoaded = true;
            const previous = root.customConf.favor;
            // Union, so favourites already saved per-containment migrate over
            // instead of being wiped by the first load.
            const merged = new Set([...(ids || []), ...previous]);
            root.customConf.favor = merged;
            if(merged.size !== (ids || []).length) root.saveFavorites();
            wpListModel.applyFavorites((id) => merged.has(id));
        }).catch(reason => console.error("read favourites failed", reason));
    }

    function saveFavorites() {
        if(pyext && pyext.ok)
            pyext.write_favorites([...root.customConf.favor]);
    }

    Connections {
        target: pyext
        function onOkChanged() { root.loadFavorites(); }
    }

    // ---- settings shared across every monitor -------------------------------
    // Everything here is stored per containment by Plasma, so a change made
    // while the dialog happened to be open on one screen never reached the
    // others - filters, sort order, library path and the playback settings all
    // silently diverged. Plasma also only writes them on OK, so anything set
    // and then closed with Cancel or the window button was thrown away.
    //
    // So: mirror them onto every desktop as soon as they change. Deliberately
    // NOT included are WallpaperSource and WallpaperWorkShopId - those are
    // per-screen by design, and copying them would give every monitor the same
    // wallpaper.
    CmdRunner { id: shareRunner }

    // False until the dialog has finished building, so simply opening it does
    // not fire a write for every property as it is initialised.
    property bool _shareReady: false

    // Snapshot taken once the dialog has settled; only keys differing from it
    // are ever written.
    //
    // Writing the whole set on any change was destructive: several of these are
    // aliases into the Settings page's controls, and until those controls have
    // taken their values from config they read as 0. One early sync stamped
    // Volume=0 and Speed=0.1 onto all three screens, overwriting values the
    // user had never touched. Diffing against a baseline means initialisation
    // noise is ignored and only genuine edits travel between screens.
    property var _shareBaseline: null

    function sharedSettings() {
        return {
            SteamLibraryPath:    cfg_SteamLibraryPath,
            FilterStr:           cfg_FilterStr,
            SortMode:            cfg_SortMode,
            SortReverse:         cfg_SortReverse,
            ThumbScale:          cfg_ThumbScale,
            OptionsWidth:        cfg_OptionsWidth,
            DisplayMode:         cfg_DisplayMode,
            PauseMode:           cfg_PauseMode,
            VideoBackend:        cfg_VideoBackend,
            Fps:                 cfg_Fps,
            Volume:              cfg_Volume,
            MpvStats:            cfg_MpvStats,
            Speed:               cfg_Speed,
            MuteAudio:           cfg_MuteAudio,
            MouseInput:          cfg_MouseInput,
            ResumeTime:          cfg_ResumeTime,
            SwitchTimer:         cfg_SwitchTimer,
            RandomizeWallpaper:  cfg_RandomizeWallpaper,
            NoRandomWhilePaused: cfg_NoRandomWhilePaused,
            PauseFilterByScreen: cfg_PauseFilterByScreen,
            PauseOnBatPower:     cfg_PauseOnBatPower,
            PauseBatPercent:     cfg_PauseBatPercent,
            CustomConf:          cfg_CustomConf
        };
    }

    function shareSettingsNow() {
        const current = sharedSettings();
        if(!root._shareBaseline) { root._shareBaseline = current; return; }

        // Only the keys that actually changed.
        const diff = {};
        let n = 0;
        for(const k in current)
            if(current[k] !== root._shareBaseline[k]) { diff[k] = current[k]; n++; }
        if(n === 0) return;
        root._shareBaseline = current;

        const vals = JSON.stringify(diff);
        const js = 'var P="com.github.catsout.wallpaperEngineKde";'
                 + 'var v=' + vals + ';var d=desktops();'
                 + 'for(var i=0;i<d.length;i++){'
                 + 'd[i].currentConfigGroup=["Wallpaper",P,"General"];'
                 + 'for(var k in v) d[i].writeConfig(k, v[k]);'
                 + 'd[i].reloadConfig();}print("ok");';
        const cmd = "qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
                  + "'" + js.replace(/'/g, "'\\''") + "'";
        shareRunner.exec(cmd, () => {});
    }

    // Coalesced: dragging a slider emits a change per step, and each write here
    // touches every containment.
    Timer {
        id: shareDebounce
        interval: 400
        onTriggered: root.shareSettingsNow()
    }

    function shareSettings() {
        if(root._shareReady) shareDebounce.restart();
    }

    Timer {
        interval: 3000
        running: true
        repeat: false
        onTriggered: {
            root._shareBaseline = root.sharedSettings();
            root._shareReady = true;
        }
    }

    onCfg_SteamLibraryPathChanged:    shareSettings()
    onCfg_FilterStrChanged:           shareSettings()
    onCfg_SortModeChanged:            shareSettings()
    onCfg_SortReverseChanged:         shareSettings()
    onCfg_ThumbScaleChanged:          shareSettings()
    onCfg_OptionsWidthChanged:        shareSettings()
    onCfg_DisplayModeChanged:         shareSettings()
    onCfg_PauseModeChanged:           shareSettings()
    onCfg_VideoBackendChanged:        shareSettings()
    onCfg_FpsChanged:                 shareSettings()
    onCfg_VolumeChanged:              shareSettings()
    onCfg_MpvStatsChanged:            shareSettings()
    onCfg_SpeedChanged:               shareSettings()
    onCfg_MuteAudioChanged:           shareSettings()
    onCfg_MouseInputChanged:          shareSettings()
    onCfg_ResumeTimeChanged:          shareSettings()
    onCfg_SwitchTimerChanged:         shareSettings()
    onCfg_RandomizeWallpaperChanged:  shareSettings()
    onCfg_NoRandomWhilePausedChanged: shareSettings()
    onCfg_PauseFilterByScreenChanged: shareSettings()
    onCfg_PauseOnBatPowerChanged:     shareSettings()
    onCfg_PauseBatPercentChanged:     shareSettings()
    onCfg_CustomConfChanged:          shareSettings()

    Connections {
        target: wpListModel
        // A rescan rebuilds every item through initItemOp, which runs before
        // favourites may have arrived; re-stamp them once the list settles.
        function onModelRefreshed() {
            if(root._favLoaded)
                wpListModel.applyFavorites((id) => root.customConf.favor.has(id));
        }
    }


    // Content
    PlasmaComponents.TabBar {
        id: bar
        implicitWidth: font.pixelSize*8 * 4
        PlasmaComponents.TabButton {
            text: "Wallpapers"
        }
        PlasmaComponents.TabButton {
            text: "Workshop"
        }
        PlasmaComponents.TabButton {
            text: "Settings"
        }
        PlasmaComponents.TabButton {
            text: "About"
        }
    }

    StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: bar.currentIndex

        WallpaperPage {
            id: wallpaperPage
            // Unsubscribe from the library tab reuses the Workshop tab's
            // Steam-session removal, so there is one implementation and the
            // library rescans itself when the files disappear.
            unsubscribeFn: (id) => workshopPage.unsubscribe(id)
        }

        // Order must match the tab bar above - StackLayout indexes by position.
        WorkshopPage {
            id: workshopPage
        }

        SettingPage {
            id: settingPage
        }

        AboutPage {}
    }
}
