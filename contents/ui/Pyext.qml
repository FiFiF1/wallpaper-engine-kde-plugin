import QtQuick 2.0
import QtWebSockets 1.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support

import "js/jsonrpc.mjs" as Jsonrpc

Item {
    id: root
    readonly property string file: "plasma/wallpapers/com.github.catsout.wallpaperEngineKde/contents/pyext.py"
    readonly property string source: {
        const sh = [
            `EXT=${file}`,
            `WKD="no_pyext_file_found"`,
            "[ -f /usr/share/$EXT ] && WKD=/usr/share/$EXT",
            "[ -f \"$HOME/.local/share/$EXT\" ] && WKD=\"$HOME/.local/share/$EXT\"",
            "[ -f \"$XDG_DATA_HOME/$EXT\" ] && WKD=\"$XDG_DATA_HOME/$EXT\"", 
            `exec python3 "$WKD" "${ws_server.url}"`
        ].join("\n");
        return sh;
    }
    readonly property bool ok: ws_server.socket && ws_server.socket.status == WebSocket.Open

    property string _log
    readonly property string log: _log

    property var commands: []

    readonly property string version: _version

    property string _version: {
        if(ok) {
            ws_server.jrpc.send("version").then(res => { 
                this._version = res.result 
            });
        }
        return '-';
    }
    
    function readfile(path) {
        return ws_server.jrpc.send("readfile", [path]).then((el) => {
            return Qt.atob(el.result);
        });
    }
    function get_dir_size(path, depth=3) {
        return ws_server.jrpc.send("get_dir_size", [path, depth]).then(res => res.result);
    }
    function get_folder_list(path, opt={}) {
        return ws_server.jrpc.send("get_folder_list", [path, opt]).then(res => res.result);
    }
    function read_wallpaper_config(id) {
        return ws_server.jrpc.send("read_wallpaper_config", [id]).then(res => res.result);
    }
    function write_wallpaper_config(id, changed) {
        return ws_server.jrpc.send("write_wallpaper_config", [id, changed]);
    }
    function reset_wallpaper_config(id) {
        return ws_server.jrpc.send("reset_wallpaper_config", [id]);
    }
    // Public Steam Workshop listing for the Workshop tab. Read-only browsing:
    // subscribing still happens in Steam itself.
    function workshop_browse(sort, page, query, tags, days) {
        return ws_server.jrpc.send("workshop_browse",
            [sort || "trend", page || 1, query || "", tags || [], days || 0]).then(res => res.result);
    }
    function path_exists(path) {
        return ws_server.jrpc.send("path_exists", [String(path)]).then(res => res.result);
    }
    // Record the wallpaper just applied, so the crash guard can name the most
    // likely culprit if it then crashes the shell.
    function record_last_applied(wid) {
        return ws_server.jrpc.send("record_last_applied", [String(wid)]);
    }
    function workshop_item(id) {
        return ws_server.jrpc.send("workshop_item", [String(id)]).then(res => res.result);
    }
    // What one wallpaper can actually do - its type, and whether it has any
    // sound at all - so the settings page can drop controls it would ignore.
    function wallpaper_caps(path) {
        return ws_server.jrpc.send("wallpaper_caps", [String(path)]).then(res => res.result);
    }
    // Resolution tier per item, batched: [{workshopid, path, type}, ...] ->
    // {workshopid: {tier, w, h}}. Cached on the python side, so repeat calls
    // for an unchanged library return immediately.
    function resolve_resolutions(items) {
        return ws_server.jrpc.send("resolve_resolutions", [items]).then(res => res.result);
    }
    // Subscribe / unsubscribe directly, reusing the Steam client's own cached
    // login so no browser opens. The helper reports failure as a flag rather
    // than throwing, and the caller falls back to opening Steam.
    function steam_session_status() {
        return ws_server.jrpc.send("steam_session_status", []).then(res => res.result);
    }
    function steam_subscribe(id) {
        return ws_server.jrpc.send("steam_subscribe", [String(id)]).then(res => res.result);
    }
    function steam_unsubscribe(id) {
        return ws_server.jrpc.send("steam_unsubscribe", [String(id)]).then(res => res.result);
    }
    // Download progress of one item, for the tile's loading indicator.
    function workshop_download_state(library, id) {
        return ws_server.jrpc.send("workshop_download_state",
            [String(library), String(id)]).then(res => res.result);
    }
    // Favourites, shared across all monitors and written immediately, rather
    // than living per-containment in Plasma config that only saves on OK.
    function read_favorites() {
        return ws_server.jrpc.send("read_favorites", []).then(res => res.result);
    }
    function write_favorites(ids) {
        return ws_server.jrpc.send("write_favorites", [ids]);
    }
    // Only ever called from the Translate button - this sends the text to an
    // online translation service, so it must stay user-initiated.
    function translate(text, target) {
        return ws_server.jrpc.send("translate", [text, target || "en"]).then(res => res.result);
    }



    function _createTimer(callback) {
        const timer = Qt.createQmlObject("import QtQuick 2.0; Timer {}", root);
        const interval = 500;
        timer.interval = interval;
        timer.repeat = true;
        timer.triggered.connect(() => callback(500));
        timer.start();
        return timer;
    }

    WebSocketServer {
        id: ws_server
        listen: true
        property var socket: { status: WebSocket.Closed }
        property var backmsg: []
        property var jrpc: {
            jrpc = new Jsonrpc.Jsonrpc(sendStr.bind(this), _createTimer);
        }

        onClientConnected: {
            console.error("----python helper connected----")
            this.socket = webSocket;
            webSocket.onTextMessageReceived.connect((message) => {
                ws_server.jrpc.receive(message);
            });
            webSocket.onStatusChanged.connect((status) => {
                if(status != WebSocket.Open) {
                    ws_server.jrpc.rejectUnfinished();
                    console.error("----python helper disconnected----")
                } else {
                    ws_server.dealBackmsg();
                }
            });
            this.dealBackmsg();
        }

        function dealBackmsg() {
            if(!ok) return;
            const m = backmsg;
            backmsg = [];
            m.forEach(el => {
                ws_server.socket.sendTextMessage(el);
            });
        }
        function sendStr(s) {
            if(!ok) {
                this.backmsg.push(s);
            } else {
                this.socket.sendTextMessage(s);
            }
        }
    }

    Plasma5Support.DataSource {
        engine: 'executable'
        connectedSources: [source]
        onNewData: {
            _log += "\n" + data.stderr;
            _log += "\n" + data.stdout;
            console.error(data.stderr);
            console.error(data.stdout);
        }
    }
}
