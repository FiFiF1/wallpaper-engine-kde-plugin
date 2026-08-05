import QtQuick 2.0
import org.kde.plasma.plasma5support as Plasma5Support

// Small helper: run a shell command and get its stdout back via callback.
// Used to drive Plasma's scripting D-Bus API so the wallpaper picker can read
// and write the wallpaper of screens other than the one it was opened on.
Plasma5Support.DataSource {
    id: runner

    engine: "executable"
    connectedSources: []

    property var _callbacks: ({})

    onNewData: (sourceName, data) => {
        const cb = runner._callbacks[sourceName];
        delete runner._callbacks[sourceName];
        runner.disconnectSource(sourceName);
        if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "");
    }

    function exec(cmd, callback) {
        if (runner._callbacks[cmd]) {
            // Same command already in flight; drop the duplicate.
            return;
        }
        if (callback) runner._callbacks[cmd] = callback;
        runner.connectSource(cmd);
    }
}
