import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5

import ".."
import "../components"

import org.kde.kirigami 2.6 as Kirigami

// Steam Workshop browser, in a tab rather than a separate window.
//
// This is a native grid, not an embedded browser. A WebEngineView lives in the
// same process as plasmashell, and if QtWebEngine was never initialised for
// that process, creating one aborts it - taking the whole desktop shell down.
// Not worth the risk for a listing that parses fine as data.
//
// Browsing only: subscribing opens the item in Steam, which is the only thing
// that can actually add it to the library.
RowLayout {
    id: workshopPage

    property int page: 1
    property string sortMode: "trend"
    property string query: ""
    property bool busy: false
    property string errorText: ""
    property bool loadedOnce: false

    // Tags to require, taken from the checkboxes on the left. Steam ANDs these,
    // so unlike the library's filters (which hide things) these narrow a search.
    property var selectedTags: []

    readonly property var sortModel: [
        { text: "Popular this week", value: "trend" },
        { text: "Most recent",       value: "mostrecent" },
        { text: "Top rated",         value: "toprated" },
        { text: "Most subscribed",   value: "totaluniquesubscribers" }
    ]

    ListModel { id: wsModel }

    function load() {
        if(!pyext || !pyext.ok) {
            workshopPage.errorText = "The python helper is not running yet.";
            return;
        }
        workshopPage.busy = true;
        workshopPage.errorText = "";
        pyext.workshop_browse(workshopPage.sortMode, workshopPage.page,
                              workshopPage.query, workshopPage.selectedTags)
            .then((res) => {
                workshopPage.busy = false;
                workshopPage.loadedOnce = true;
                wsModel.clear();
                if(!res) { workshopPage.errorText = "No response from the helper."; return; }
                if(res.error) { workshopPage.errorText = res.error; return; }
                const items = res.items || [];
                for(let i = 0; i < items.length; i++) wsModel.append(items[i]);
                if(items.length === 0)
                    workshopPage.errorText = "Nothing matched. Try fewer filters.";
                // A new listing means the old scroll position is meaningless.
                wsGrid.positionViewAtBeginning();
            })
            .catch((reason) => {
                workshopPage.busy = false;
                workshopPage.errorText = String(reason);
            });
    }

    function reload() { workshopPage.page = 1; load(); }

    function toggleTag(tag, on) {
        const out = [];
        for(let i = 0; i < selectedTags.length; i++)
            if(selectedTags[i] !== tag) out.push(selectedTags[i]);
        if(on) out.push(tag);
        selectedTags = out;
        reload();
    }

    function clearTags() {
        selectedTags = [];
        reload();
    }

    // Loading only starts when the tab is first shown - StackLayout builds every
    // page up front, and fetching a web page just because the dialog opened
    // would be rude.
    onVisibleChanged: maybeLoad()

    function maybeLoad() {
        if(visible && !loadedOnce && pyext && pyext.ok) load();
    }

    // The helper connects a moment after the dialog is built, so the first
    // attempt can land before it is up. Retry once it reports ready instead of
    // leaving "the python helper is not running yet" on screen forever.
    Connections {
        target: pyext
        function onOkChanged() { workshopPage.maybeLoad(); }
    }

    // Subscribing and unsubscribing both happen in Steam - only Steam can change
    // what an account is subscribed to. Done in place through the client's
    // cached login, each action then tracks the download (or removal) so the
    // tile shows a live loading indicator and the Wallpapers tab keeps up on its
    // own. Several can run at once, so this is a map rather than one pending id.
    //
    // downloads[id] = {
    //   phase: "sub" | "dl" | "rm",   // subscribing / downloading / removing
    //   onDisk, target,               // bytes so far, and total when known
    //   lastSize, stable,             // for "download finished" detection
    //   tries,                        // poll count, so a stall gives up
    //   note                          // e.g. "Opened in Steam"
    // }
    property var downloads: ({})
    // hasWorkshopId and downloads are plain JS reads, so bindings on them never
    // re-run by themselves. Bump this whenever either changes and have those
    // bindings read it, so tiles react.
    property int libraryRevision: 0

    function itemDir(id) {
        return String(cfg_SteamLibraryPath || "")
             + "/steamapps/workshop/content/431960/" + String(id);
    }

    function dlGet(id) {
        return workshopPage.downloads[String(id)] || null;
    }
    function _dlSet(id, obj) {
        var d = workshopPage.downloads;
        d[String(id)] = Object.assign(d[String(id)] || {}, obj);
        workshopPage.downloads = d;            // reassign so the property notifies
        workshopPage.libraryRevision++;
        pollWatch.ensureRunning();
    }
    function _dlClear(id) {
        var d = workshopPage.downloads;
        delete d[String(id)];
        workshopPage.downloads = d;
        workshopPage.libraryRevision++;
    }
    function _dlCount() { return Object.keys(workshopPage.downloads).length; }

    // Turn "21.416 MB" and friends into bytes, for a proportional bar on a
    // brand-new download whose size Steam does not know yet.
    function _sizeToBytes(text) {
        var m = String(text || "").match(/([\d.,]+)\s*([KMGT]?B)/i);
        if(!m) return 0;
        var n = parseFloat(m[1].replace(/,/g, ""));
        if(!isFinite(n)) return 0;
        var mult = { "B": 1, "KB": 1024, "MB": 1048576,
                     "GB": 1073741824, "TB": 1099511627776 };
        return Math.round(n * (mult[m[2].toUpperCase()] || 1));
    }

    function _openInSteam(id) {
        Qt.openUrlExternally("steam://url/CommunityFilePage/" + id);
    }

    // Learn the total size for a fresh download from the item page, so the bar
    // is proportional from the start rather than a spinner that suddenly fills.
    function _seedTarget(id) {
        if(!pyext || !pyext.workshop_item) return;
        pyext.workshop_item(id).then((res) => {
            if(!res || !res.details) return;
            for(var i = 0; i < res.details.length; i++) {
                if(String(res.details[i].label).toLowerCase().indexOf("size") !== -1) {
                    var b = workshopPage._sizeToBytes(res.details[i].value);
                    var cur = workshopPage.dlGet(id);
                    if(b > 0 && cur && !cur.target) workshopPage._dlSet(id, { target: b });
                    return;
                }
            }
        }).catch(() => {});
    }

    function subscribe(id) {
        // Instant feedback - the tile flips to "Subscribing…" before any round
        // trip, so pressing Get never feels dead.
        workshopPage._dlSet(id, { phase: "sub", onDisk: 0, target: 0,
                                  lastSize: -1, stable: 0, tries: 0, note: "" });
        if(pyext && pyext.ok && pyext.steam_subscribe) {
            pyext.steam_subscribe(id).then((res) => {
                if(res && res.ok) {
                    workshopPage._dlSet(id, { phase: "dl", tries: 0 });
                    workshopPage._seedTarget(id);
                } else {
                    workshopPage._openInSteam(id);
                    workshopPage._dlSet(id, { phase: "dl", tries: 0,
                                              note: "Opened in Steam" });
                    workshopPage._seedTarget(id);
                }
            }).catch(() => {
                workshopPage._openInSteam(id);
                workshopPage._dlSet(id, { phase: "dl", tries: 0, note: "Opened in Steam" });
            });
        } else {
            workshopPage._openInSteam(id);
            workshopPage._dlSet(id, { phase: "dl", tries: 0, note: "Opened in Steam" });
        }
    }

    // Steam removes the files itself once unsubscribed; the watcher sees the
    // folder go and drops it from the library view.
    function unsubscribe(id) {
        workshopPage._dlSet(id, { phase: "rm", tries: 0, note: "" });
        if(pyext && pyext.ok && pyext.steam_unsubscribe) {
            pyext.steam_unsubscribe(id).then((res) => {
                if(res && res.ok) {
                    workshopPage._dlSet(id, { phase: "rm", tries: 0 });
                } else {
                    workshopPage._openInSteam(id);
                    workshopPage._dlSet(id, { phase: "rm", tries: 0, note: "Opened in Steam" });
                }
            }).catch(() => {
                workshopPage._openInSteam(id);
                workshopPage._dlSet(id, { phase: "rm", tries: 0, note: "Opened in Steam" });
            });
        } else {
            workshopPage._openInSteam(id);
            workshopPage._dlSet(id, { phase: "rm", tries: 0, note: "Opened in Steam" });
        }
    }

    // One poll drives every in-flight download and removal.
    Timer {
        id: pollWatch
        interval: 2000
        repeat: true
        function ensureRunning() { if(!running && workshopPage._dlCount() > 0) start(); }

        onTriggered: {
            if(!pyext || !pyext.ok) return;
            if(workshopPage._dlCount() === 0) { stop(); return; }
            var ids = Object.keys(workshopPage.downloads);
            for(var i = 0; i < ids.length; i++) workshopPage._pollOne(ids[i]);
        }
    }

    function _pollOne(id) {
        var d = workshopPage.dlGet(id);
        if(!d) return;
        // "sub" is only the brief pre-network state; the poll acts once it is
        // downloading or removing.
        if(d.phase === "sub") return;

        d.tries = (d.tries || 0) + 1;
        // ~3 minutes of no result, then stop tracking rather than poll forever.
        if(d.tries > 90) {
            workshopPage._dlClear(id);
            wpListModel.refresh();
            return;
        }

        pyext.workshop_download_state(cfg_SteamLibraryPath, id).then((st) => {
            if(!st || st.error) return;
            var cur = workshopPage.dlGet(id);
            if(!cur) return;

            if(cur.phase === "rm") {
                if(!st.present) {           // files gone -> unsubscribed
                    workshopPage._dlClear(id);
                    wpListModel.refresh();
                }
                return;
            }

            // Downloading: track bytes and decide when it has landed.
            var onDisk = st.onDisk + st.staging;
            var stable = (onDisk === cur.lastSize) ? (cur.stable || 0) + 1 : 0;
            var patch = { onDisk: onDisk, lastSize: onDisk, stable: stable, tries: cur.tries };
            if(st.target && !cur.target) patch.target = st.target;
            workshopPage._dlSet(id, patch);

            // Done when Steam records the install, or the files are present and
            // their size has held steady across a few polls (nothing left to
            // fetch) with no pending update.
            var landed = (st.installed && st.present && !st.needsUpdate)
                      || (st.present && stable >= 2 && !st.needsUpdate);
            if(landed) {
                workshopPage._dlClear(id);
                wpListModel.refresh();
            }
        }).catch(() => {});
    }

    // Keep "In library" and Unsubscribe current after any rescan.
    Connections {
        target: wpListModel
        function onModelRefreshed() { workshopPage.libraryRevision++; }
    }

    WorkshopDetail {
        id: wsDetail
        parent: root
        anchors.centerIn: parent
    }

    // ------------------------------------------------------------- filters
    Control {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        Layout.fillHeight: true
        topPadding: Kirigami.Units.smallSpacing
        leftPadding: Kirigami.Units.smallSpacing
        rightPadding: Kirigami.Units.smallSpacing

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    text: "Filters"
                    level: 5
                    opacity: 0.7
                    Layout.fillWidth: true
                }
                ToolButton {
                    text: "None"
                    onClicked: workshopPage.clearTags()
                    ToolTip.visible: hovered
                    ToolTip.text: "Clear every filter"
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.55
                color: Kirigami.Theme.textColor
                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                text: "Ticking narrows the search - items must carry every ticked tag."
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                // Plasma sizes the config page from implicitHeight; reporting the
                // full list height would inflate the dialog and squash the grid.
                implicitHeight: 0
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                ColumnLayout {
                    width: Math.max(1, parent.width - Kirigami.Units.smallSpacing)
                    spacing: 0

                    Repeater {
                        // Same tag vocabulary as the library filters, minus the
                        // ones that only mean something locally (Favorite,
                        // playlists) - Steam has no equivalent.
                        model: Common.filterModel
                        delegate: Item {
                            required property int index
                            required property string text
                            required property string type
                            required property string key

                            readonly property bool isHeader: type === '_nocheck'
                            readonly property bool usable:
                                isHeader || type === 'type' || type === 'tags'
                                || type === 'contentrating'

                            visible: usable
                            Layout.fillWidth: true
                            implicitHeight: !usable ? 0
                                : (isHeader ? hdr.implicitHeight + Kirigami.Units.largeSpacing
                                            : box.implicitHeight)

                            Label {
                                id: hdr
                                visible: parent.isHeader
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                text: parent.text
                                opacity: 0.55
                                color: Kirigami.Theme.textColor
                                font.bold: true
                                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                            }

                            CheckBox {
                                id: box
                                visible: parent.usable && !parent.isHeader
                                anchors.left: parent.left
                                anchors.right: parent.right
                                text: parent.text
                                checked: workshopPage.selectedTags.indexOf(parent.key) !== -1
                                onToggled: workshopPage.toggleTag(parent.key, checked)
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- main
    ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            TextField {
                id: wsSearch
                Layout.fillWidth: true
                placeholderText: "Search the Workshop…"
                onAccepted: { workshopPage.query = text; workshopPage.reload(); }
            }
            Button {
                icon.name: "search"
                text: "Search"
                onClicked: { workshopPage.query = wsSearch.text; workshopPage.reload(); }
            }
            ComboBox {
                textRole: "text"
                model: workshopPage.sortModel
                currentIndex: Math.max(0, Common.modelIndexOfValue(workshopPage.sortModel, workshopPage.sortMode))
                onActivated: (i) => {
                    workshopPage.sortMode = workshopPage.sortModel[i].value;
                    workshopPage.reload();
                }
            }
            ToolButton {
                icon.name: "go-previous"
                enabled: workshopPage.page > 1 && !workshopPage.busy
                onClicked: { workshopPage.page--; workshopPage.load(); }
            }
            Label {
                text: "Page " + workshopPage.page
                color: Kirigami.Theme.textColor
            }
            ToolButton {
                icon.name: "go-next"
                enabled: !workshopPage.busy
                onClicked: { workshopPage.page++; workshopPage.load(); }
            }
            ToolButton {
                icon.name: "view-refresh-symbolic"
                enabled: !workshopPage.busy
                onClicked: workshopPage.load()
            }
            Button {
                icon.name: "steam"
                text: "Open in Steam"
                onClicked: Qt.openUrlExternally("steam://url/SteamWorkshopPage/431960")
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            readonly property int activeCount: {
                workshopPage.libraryRevision;      // recount on change
                return workshopPage._dlCount();
            }
            visible: workshopPage.busy || workshopPage.errorText.length > 0
                     || activeCount > 0
            color: Kirigami.Theme.textColor
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: {
                if(workshopPage.busy) return "Loading…";
                if(activeCount > 0)
                    return activeCount === 1 ? "1 wallpaper in progress…"
                                             : activeCount + " wallpapers in progress…";
                return workshopPage.errorText;
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            implicitHeight: 0
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            GridView {
                id: wsGrid
                model: wsModel
                readonly property real thumbScale: (cfg_ThumbScale > 0 ? cfg_ThumbScale : 100) / 100.0
                cellWidth: Math.max(120, Kirigami.Units.gridUnit * 13 * thumbScale)
                cellHeight: cellWidth * 0.72 + Kirigami.Units.gridUnit * 4

                delegate: Item {
                    width: wsGrid.cellWidth
                    height: wsGrid.cellHeight

                    required property string id
                    required property string title
                    required property string author
                    required property string preview

                    readonly property bool installed: {
                        workshopPage.libraryRevision;   // re-check on library changes
                        return wpListModel.hasWorkshopId(id);
                    }
                    // Live download/removal state for this tile, if any.
                    readonly property var dl: {
                        workshopPage.libraryRevision;
                        return workshopPage.dlGet(id);
                    }
                    readonly property bool busy: dl !== null
                    readonly property real progress:
                        (dl && dl.target > 0) ? Math.min(1, dl.onDisk / dl.target) : 0
                    readonly property string busyLabel: {
                        if(!dl) return "";
                        if(dl.phase === "sub") return "Subscribing…";
                        if(dl.phase === "rm")  return "Removing…";
                        if(dl.target > 0)
                            return "Downloading… " + Math.round(progress * 100) + "%";
                        if(dl.onDisk > 0)
                            return "Downloading… " + (dl.onDisk / 1048576).toFixed(1) + " MB";
                        return "Downloading…";
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        radius: 4
                        color: hoverArea.containsMouse
                            ? Kirigami.Theme.alternateBackgroundColor
                            : "transparent"
                        border.width: 1
                        border.color: hoverArea.containsMouse
                            ? Kirigami.Theme.highlightColor : "transparent"

                        // Beneath the content: a click on the artwork or title
                        // opens the detail view. The buttons sit above this and
                        // consume their own clicks, so Get subscribes rather than
                        // falling through to here.
                        MouseArea {
                            id: clickArea
                            anchors.fill: parent
                            onClicked: wsDetail.show(id, title, preview)
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: 2

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: width * 0.62
                                clip: true

                                Image {
                                    id: shot
                                    anchors.fill: parent
                                    source: preview
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: true
                                    smooth: true
                                }
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: Kirigami.Units.iconSizes.large
                                    height: width
                                    source: "view-preview"
                                    visible: shot.status !== Image.Ready
                                    opacity: 0.4
                                }
                                Rectangle {
                                    visible: installed && !busy
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: 3
                                    radius: 3
                                    color: Kirigami.Theme.positiveBackgroundColor
                                    width: ownedLabel.implicitWidth + 8
                                    height: ownedLabel.implicitHeight + 4
                                    Label {
                                        id: ownedLabel
                                        anchors.centerIn: parent
                                        text: "In library"
                                        color: Kirigami.Theme.textColor
                                        font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize - 1)
                                    }
                                }

                                // Loading screen while this item subscribes,
                                // downloads or is removed: dims the thumbnail
                                // and shows a spinner, a status line, and a bar.
                                Rectangle {
                                    anchors.fill: parent
                                    visible: busy
                                    color: Qt.rgba(0, 0, 0, 0.55)

                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        width: parent.width * 0.8
                                        spacing: Kirigami.Units.smallSpacing

                                        BusyIndicator {
                                            Layout.alignment: Qt.AlignHCenter
                                            running: busy
                                            implicitWidth: Kirigami.Units.gridUnit * 2
                                            implicitHeight: Kirigami.Units.gridUnit * 2
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            elide: Text.ElideRight
                                            color: "white"
                                            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                                            text: busyLabel
                                        }
                                        ProgressBar {
                                            Layout.fillWidth: true
                                            visible: dl && dl.phase === "dl"
                                            // Proportional when the size is known,
                                            // otherwise a moving indeterminate bar.
                                            indeterminate: !(dl && dl.target > 0)
                                            from: 0; to: 1
                                            value: progress
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            visible: dl && dl.note && dl.note.length > 0
                                            color: "white"
                                            opacity: 0.8
                                            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize - 1)
                                            text: dl ? (dl.note || "") : ""
                                        }
                                    }
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                color: Kirigami.Theme.textColor
                                text: title
                            }
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                visible: author.length > 0 && !hoverArea.containsMouse
                                opacity: 0.6
                                color: Kirigami.Theme.textColor
                                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                                text: "by " + author
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                visible: hoverArea.containsMouse || busy
                                Button {
                                    Layout.fillWidth: true
                                    enabled: !busy
                                    text: busy ? busyLabel : (installed ? "In Steam" : "Get")
                                    icon.name: "steam"
                                    onClicked: {
                                        if(installed) workshopPage._openInSteam(id);
                                        else workshopPage.subscribe(id);
                                    }
                                }
                                ToolButton {
                                    visible: installed && !busy
                                    icon.name: "list-remove"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Unsubscribe"
                                    onClicked: workshopPage.unsubscribe(id)
                                }
                                ToolButton {
                                    icon.name: "documentinfo"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Details"
                                    onClicked: wsDetail.show(id, title, preview)
                                }
                            }
                        }

                        // Full-tile hover only. NoButton means it never grabs a
                        // press, so clicks pass through to the buttons (and to
                        // clickArea beneath). It exists just to light the tile and
                        // reveal the action row, staying lit even over a button.
                        MouseArea {
                            id: hoverArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                            cursorShape: Qt.PointingHandCursor
                        }
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            wrapMode: Text.WordWrap
            opacity: 0.55
            color: Kirigami.Theme.textColor
            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
            text: "Click a wallpaper for details. Subscribe in Steam, then press Refresh "
                + "on the Wallpapers tab. Only items Steam shows publicly appear here - "
                + "mature entries need the Workshop site while signed in."
        }
    }
}
