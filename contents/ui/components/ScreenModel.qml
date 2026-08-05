import QtQuick 2.6
import QtQuick.Window 2.0

// Knows about every Plasma desktop (one per monitor), what wallpaper each one
// currently shows, and how to push a new wallpaper onto any of them.
//
// Plasma's wallpaper config page can only edit the containment it was opened
// for, so anything targeting another monitor goes through plasmashell's
// scripting D-Bus interface instead.
Item {
    id: screenModel

    readonly property string pluginId: "com.github.catsout.wallpaperEngineKde"

    // [{ index, screen, source, workshopid, plugin, name, x, y, width, height }]
    property var screens: []
    property int count: screens.length
    property bool busy: false

    signal applied(int index)
    signal refreshed()

    CmdRunner { id: runner }

    // Plasma stores wallpaper paths with $HOME left unexpanded (kconfig's [$e]
    // flag), so the raw string out of readConfig is not a usable URL - the
    // monitor picker's fallback thumbnail was trying to load "file:$HOME/...".
    property string homeDir: ""

    function expandPath(s) {
        if(!s) return "";
        return homeDir ? String(s).replace(/\$HOME/g, homeDir) : String(s);
    }

    function _shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function _evaluate(js, cb) {
        const cmd = "qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript " + _shq(js);
        runner.exec(cmd, cb);
    }

    // Geometry comes from plasmashell (authoritative for which containment maps
    // to which monitor). Qt only supplies the human-readable output name, matched
    // by position rather than by index — the two do not necessarily agree.
    function _qtNameAt(x, y) {
        const list = Qt.application.screens;
        if (!list) return "";
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].virtualX === x && list[i].virtualY === y) return list[i].name || "";
        }
        return "";
    }

    function refresh() {
        const js = 'var P=' + JSON.stringify(pluginId) + ';'
                 + 'var out=[];var d=desktops();'
                 + 'for(var i=0;i<d.length;i++){'
                 + 'd[i].currentConfigGroup=["Wallpaper",P,"General"];'
                 + 'var g=screenGeometry(d[i].screen);'
                 + 'out.push({i:i,screen:d[i].screen,src:String(d[i].readConfig("WallpaperSource")),'
                 + 'wsid:String(d[i].readConfig("WallpaperWorkShopId")),'
                 + 'plugin:String(d[i].wallpaperPlugin),x:g.x,y:g.y,w:g.width,h:g.height});'
                 + '}print(JSON.stringify(out));';
        screenModel.busy = true;
        _evaluate(js, (code, stdout) => {
            screenModel.busy = false;
            let parsed = [];
            try {
                parsed = JSON.parse(String(stdout).trim());
            } catch (e) {
                screenModel.screens = [];
                screenModel.refreshed();
                return;
            }
            screenModel.screens = parsed.map((el) => {
                return {
                    index: el.i,
                    screen: el.screen,
                    source: el.src === "undefined" ? "" : el.src,
                    // readConfig gives the string "undefined" for an unset key.
                    workshopid: el.wsid === "undefined" ? "" : el.wsid,
                    plugin: el.plugin,
                    name: _qtNameAt(el.x, el.y),
                    x: el.x,
                    y: el.y,
                    width: el.w,
                    height: el.h
                };
            });
            screenModel.refreshed();
        });
    }

    // Push a wallpaper onto one monitor. Also switches that monitor to this
    // wallpaper plugin if it was using a different one.
    function applyTo(index, source, workshopid) {
        const P = JSON.stringify(pluginId);
        const js = 'var d=desktops()[' + index + '];'
                 + 'd.wallpaperPlugin=' + P + ';'
                 + 'd.currentConfigGroup=["Wallpaper",' + P + ',"General"];'
                 + 'd.writeConfig("WallpaperSource",' + JSON.stringify(String(source)) + ');'
                 + 'd.writeConfig("WallpaperWorkShopId",' + JSON.stringify(String(workshopid || "")) + ');'
                 + 'd.reloadConfig();print("ok");';
        screenModel.busy = true;
        _evaluate(js, (code, stdout) => {
            screenModel.busy = false;
            screenModel.applied(index);
            screenModel.refresh();
        });
    }

    function applyToAll(source, workshopid) {
        const P = JSON.stringify(pluginId);
        const js = 'var d=desktops();for(var i=0;i<d.length;i++){'
                 + 'd[i].wallpaperPlugin=' + P + ';'
                 + 'd[i].currentConfigGroup=["Wallpaper",' + P + ',"General"];'
                 + 'd[i].writeConfig("WallpaperSource",' + JSON.stringify(String(source)) + ');'
                 + 'd[i].writeConfig("WallpaperWorkShopId",' + JSON.stringify(String(workshopid || "")) + ');'
                 + 'd[i].reloadConfig();}print("ok");';
        screenModel.busy = true;
        _evaluate(js, (code, stdout) => {
            screenModel.busy = false;
            screenModel.applied(-1);
            screenModel.refresh();
        });
    }

    Component.onCompleted: {
        runner.exec("printf %s \"$HOME\"", (code, stdout) => {
            screenModel.homeDir = String(stdout).trim();
        });
        refresh();
    }
}
