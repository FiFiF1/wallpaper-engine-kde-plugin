import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Controls 2.3 as QQC
import QtQuick.Window 2.0 // for Screen
import QtQuick.Dialogs
import QtQuick.Layouts 1.5

import ".."
import "../components"

import "../js/utils.mjs" as Utils
import "../js/bbcode.mjs" as BBCode

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
// for kcm gridview
import org.kde.kcmutils as KCM
import org.kde.kirigami 2.6 as Kirigami
import org.kde.kquickcontrolsaddons 2.0

RowLayout {
    id: wpRoot
    Layout.fillWidth: true

    // Width of the options panel on the right.
    //
    // This used to be parent.width / 3, which meant widening the dialog made the
    // options panel bigger rather than fitting more wallpapers per row - the
    // panel just grew a wider and wider gap between each label and its control.
    // A fixed width that the user can drag keeps every extra pixel for the grid.
    readonly property int minOptionsWidth: Kirigami.Units.gridUnit * 21
    readonly property int maxOptionsWidth: Kirigami.Units.gridUnit * 42
    property int optionsWidth: Math.max(minOptionsWidth,
        Math.min(maxOptionsWidth, cfg_OptionsWidth > 0 ? cfg_OptionsWidth : 400))

    function saveConfig() {
        right_opts.save_changes();
    }

    // Unsubscribing deletes the wallpaper's files, so it runs through the same
    // Steam-session path the Workshop tab uses. config.qml wires this to
    // workshopPage.unsubscribe so there is a single implementation, and the
    // library rescans itself when the files go.
    property var unsubscribeFn: null

    function requestUnsubscribe(workshopid, title) {
        if(!workshopid || !String(workshopid).match(Common.regex_workshop_online)) return;
        unsubConfirm.wid = String(workshopid);
        unsubConfirm.wtitle = String(title || "");
        unsubConfirm.open();
    }

    Kirigami.PromptDialog {
        id: unsubConfirm
        property string wid: ""
        property string wtitle: ""
        title: "Unsubscribe"
        subtitle: "Unsubscribe from " + (wtitle ? "\"" + wtitle + "\"" : "this wallpaper")
            + "? Steam will delete its downloaded files."
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                text: "Unsubscribe"
                icon.name: "list-remove"
                onTriggered: {
                    if(wpRoot.unsubscribeFn) wpRoot.unsubscribeFn(unsubConfirm.wid);
                    unsubConfirm.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel"
                onTriggered: unsubConfirm.close()
            }
        ]
    }

    SideBar {
        id: sidebar
        onLibraryRequested: wpDialog.open()
        onRefreshRequested: wpListModel.refresh()

        // Follow the monitor: show what that screen is actually displaying,
        // rather than leaving the grid and the details panel pointing at the
        // previous screen's wallpaper.
        onTargetPicked: (index) => {
            if (picViewLoader.item) picViewLoader.item.selectScreenWallpaper(index);
        }
    }
    
    Control {
        id: left_content
        Layout.fillWidth: true
        Layout.fillHeight: true
        topPadding: 8
        leftPadding: 0
        rightPadding: 0
        bottomPadding: 0

        contentItem: ColumnLayout {
            id: wpselsect
            // No anchors here: a Control already sizes its contentItem to the
            // padding rect. Anchoring only left/right left the height at
            // implicitHeight, so the grid never filled the available space.

            Loader {
                id: picViewLoader
                Layout.fillWidth: true
                Layout.fillHeight: true
                
                // over wite the implicitWidth to 0
                Layout.preferredHeight: 0

                asynchronous: false
                sourceComponent: picViewCom
                visible: status == Loader.Ready

                Component.onCompleted: {
                    const refreshIndex = () => {
                        this.item.view.model = wpListModel.model; 
                        if(this.status == Loader.Ready) {
                            this.item.setCurIndex(wpListModel.model);
                        }
                    }
                    wpListModel.modelStartSync.connect(this.item.backtoBegin);
                    wpListModel.modelRefreshed.connect(refreshIndex.bind(this));
                }

                Kirigami.Heading {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    visible: picViewLoader.item && picViewLoader.item.view.count === 0
                    level: 2
                    text: { 
                        if(!(libcheck.qtwebsockets && pyext))
                            return `Please make sure qtwebsockets(qml module) installed, and open this again`
                        if(!pyext.ok) {
                            return `Python helper run failed: ${pyext.log}`;
                        }
                        if(!cfg_SteamLibraryPath)
                            return "Pick your Steam library folder with the Library button on the left";
                        if(root.searchStr)
                            return `Nothing matches “${root.searchStr}”.\nTry a different search, or clear it.`;
                        if(wpListModel.countNoFilter > 0)
                            return `Found ${wpListModel.countNoFilter} wallpapers, but none of them matched filters`;
                        return `There are no wallpapers in steam library`;
                    }
                    opacity: 0.5
                }
            }
            Component { 
                id: picViewCom
                KCM.GridView {
                    id: picViewGrid
                    anchors.fill: parent

                    readonly property var currentModel: view.model.get(view.currentIndex)
                    readonly property var defaultModel: ListModel {}
                    visible: view.count > 0

                    // from org.kde.image
                    // Scaled by the Size slider in the sidebar, so the grid can
                    // be tightened up to show more wallpapers per row.
                    readonly property real thumbScale: (cfg_ThumbScale > 0 ? cfg_ThumbScale : 100) / 100.0
                    view.implicitCellWidth: Screen.width / 10 * thumbScale + Kirigami.Units.smallSpacing * 2
                    view.implicitCellHeight: Screen.height / 10 * thumbScale + Kirigami.Units.smallSpacing * 2 + Kirigami.Units.gridUnit * 3
                    view.model: defaultModel
                    view.delegate: KCM.GridDelegate {
                        // path is file://, safe to concat with '/'
                        text: title
                        // tags is a nested list model once inside the outer
                        // ListModel (not a plain JS array), so it needs .get();
                        // subtitle already elides to one line, so no length cap
                        // is needed here.
                        subtitle: {
                            const t = model.tags;
                            if (!t || !t.count) return "";
                            const names = [];
                            for (let i = 0; i < t.count; i++)
                                names.push(t.get(i).key);
                            return names.join(", ");
                        }
                        hoverEnabled: true
                        actions: [
                            Kirigami.Action {
                                icon.name: favor?"user-bookmarks-symbolic":"bookmark-add-symbolic"
                                tooltip: favor?"Remove from favorites":"Add to favorites"
                                onTriggered: picViewLoader.item.toggleFavor(model, index)
                            },
                            Kirigami.Action {
                                icon.name: "folder-remote-symbolic"
                                tooltip: "Open Workshop Link"
                                enabled: workshopid.match(Common.regex_workshop_online)
                                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(workshopid))
                            },
                            Kirigami.Action {
                                icon.name: "list-remove"
                                tooltip: "Unsubscribe (deletes the files)"
                                enabled: workshopid.match(Common.regex_workshop_online)
                                onTriggered: wpRoot.requestUnsubscribe(workshopid, title)
                            }
                        ]
                        thumbnail: Rectangle {
                            anchors.fill: parent
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                width: root.iconSizes.large
                                height: width
                                source: "view-preview"
                                visible: !imgPre.visible
                            }
                            Image {
                                id: imgPre
                                anchors.fill: parent
                                source: Common.getWpModelPreviewSource(model);
                                sourceSize.width: parent.width
                                sourceSize.height: parent.height
                                fillMode: Image.PreserveAspectCrop//Image.Stretch
                                cache: false
                                asynchronous: true
                                smooth: true
                                visible: Boolean(preview)
                            }
                        }
                        onClicked: {
                            const src = Common.packWallpaperSource(model);
                            view.currentIndex = index;

                            // Note the wallpaper being applied, so if it crashes
                            // the shell the crash guard knows which one to blame.
                            if(typeof pyext !== "undefined" && pyext && pyext.ok)
                                pyext.record_last_applied(workshopid);

                            // Plasma writes the cfg_ properties onto the containment
                            // this dialog belongs to when OK is pressed. A click that
                            // applied to that same screen over D-Bus but left cfg_
                            // stale would therefore be undone by OK, writing the old
                            // wallpaper straight back over the new one. Keep cfg_ in
                            // step whenever our own screen is among the targets.
                            const hitsOwnScreen = !sidebar.targetChosen
                                || sidebar.applyTarget === -1
                                || sidebar.applyTarget === sidebar.currentScreenIndex;
                            if (hitsOwnScreen) {
                                cfg_WallpaperSource = src;
                                cfg_WallpaperWorkShopId = workshopid;
                            }

                            // Until a monitor is actually picked, behave exactly like
                            // stock Plasma and change nothing until OK. This is also
                            // the path the model's automatic first-item selection
                            // takes, so an unattended auto-select can never write to
                            // a screen.
                            if (!sidebar.targetChosen) return;

                            if (sidebar.applyTarget === -1)
                                sidebar.screenModel.applyToAll(src, workshopid);
                            else
                                sidebar.screenModel.applyTo(sidebar.applyTarget, src, workshopid);
                        }
                    }

     
                    function backtoBegin() {
                        // Changing a filter or search re-runs the model; jump back
                        // to the top rather than leaving the view scrolled into
                        // the middle of a list that no longer exists.
                        view.positionViewAtBeginning();
                        view.model = defaultModel
                        //view.positionViewAtBeginning();
                    }

                    function setCurIndex(model) {
                        // model, ListModel
                        new Promise((reoslve, reject) => {
                            for(let i=0;i < model.count;i++) {
                                if(model.get(i).workshopid === cfg_WallpaperWorkShopId) {
                                    view.currentIndex = i;
                                    break;
                                }
                            }
                            if(view.currentIndex == -1 && model.count != 0)
                                view.currentIndex = 0;

                            if(!cfg_WallpaperSource)
                                if(view.currentIndex != -1)
                                    view.currentItem.onClicked();

                            resolve();
                        });
                    }
                    // Move the selection onto the wallpaper the given Plasma
                    // desktop is currently showing. Selection only - this must
                    // never call onClicked, or merely looking at another monitor
                    // would rewrite its wallpaper.
                    function selectScreenWallpaper(screenIndex) {
                        // "All monitors" has no single wallpaper to point at.
                        if(screenIndex < 0) return;

                        const list = sidebar.screenModel.screens;
                        let wid = "";
                        for(let i = 0; i < list.length; i++) {
                            if(list[i].index === screenIndex) {
                                wid = String(list[i].workshopid || "");
                                break;
                            }
                        }
                        if(!wid) return;

                        const m = view.model;
                        for(let j = 0; j < m.count; j++) {
                            if(String(m.get(j).workshopid) === wid) {
                                view.currentIndex = j;
                                view.positionViewAtIndex(j, GridView.Contain);
                                return;
                            }
                        }
                        // That screen's wallpaper is filtered or searched out of
                        // the grid. Select nothing rather than leave the panel
                        // describing some other screen's wallpaper.
                        view.currentIndex = -1;
                    }

                    function toggleFavor(model, index) {
                        // The right-hand panel calls this with no index and means
                        // "the selected one". `!index` also caught index 0, so
                        // bookmarking the very first tile in the grid silently
                        // favourited whatever happened to be selected instead.
                        if(index === undefined || index === null) index = view.currentIndex;
                        if(index < 0 || index >= view.model.count) return;

                        if(model.favor) {
                            root.customConf.favor.delete(model.workshopid);
                        } else {
                            root.customConf.favor.add(model.workshopid);
                        }
                        this.view.model.assignModel(index, {favor: !model.favor});
                        root.saveCustomConf();

                        if(index == view.currentIndex) this.view.currentIndexChanged();
                    }

                }
            }

            FolderDialog {
                id: wpDialog
                title: "Select steamlibrary folder"
                onAccepted: {
                    const path = Utils.trimCharR(wpDialog.selectedFolder.toString(), '/');
                    cfg_SteamLibraryPath = path;
                    return wpListModel.refresh();
                }
            }
        }
    }

    // Drag handle between the wallpaper grid and the options panel.
    Rectangle {
        id: optionsSplitter
        Layout.fillHeight: true
        Layout.preferredWidth: 4
        color: splitDrag.pressed || splitDrag.containsMouse
            ? Kirigami.Theme.highlightColor
            : Kirigami.Theme.alternateBackgroundColor
        opacity: splitDrag.pressed || splitDrag.containsMouse ? 1.0 : 0.45

        MouseArea {
            id: splitDrag
            anchors.fill: parent
            // A 4px strip is a hard target; widen the grab area either side.
            anchors.leftMargin: -4
            anchors.rightMargin: -4
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor

            property real pressRootX: 0
            property int startWidth: 0

            onPressed: (mouse) => {
                // Root coordinates, because this handle itself moves as the
                // layout resizes - a delta in local x would fight itself.
                pressRootX = mapToItem(wpRoot, mouse.x, 0).x;
                startWidth = wpRoot.optionsWidth;
            }
            onPositionChanged: (mouse) => {
                if(!pressed) return;
                const dx = mapToItem(wpRoot, mouse.x, 0).x - pressRootX;
                // Dragging left widens the panel, so the delta is subtracted.
                const w = Math.max(wpRoot.minOptionsWidth,
                          Math.min(wpRoot.maxOptionsWidth, startWidth - dx));
                wpRoot.optionsWidth = Math.round(w);
            }
            onReleased: cfg_OptionsWidth = wpRoot.optionsWidth
            onDoubleClicked: {
                wpRoot.optionsWidth = 400;
                cfg_OptionsWidth = 400;
            }
        }
    }

    Control {
        id: right_content
        Layout.preferredWidth: wpRoot.optionsWidth
        Layout.minimumWidth: wpRoot.minOptionsWidth
        Layout.maximumWidth: wpRoot.maxOptionsWidth
        // Never fill: the grid takes the slack, which is the whole point.
        Layout.fillWidth: false
        Layout.fillHeight: true

        readonly property int image_size: 300
        readonly property int content_margin: 16
        property var wpmodel: {
            return picViewLoader.item.currentModel
            ? Common.wpitemFromQtObject(picViewLoader.item.currentModel)
            : Common.wpitem_template;
        }

        // ---- translation --------------------------------------------------
        // Workshop titles and descriptions are very often Chinese, Japanese or
        // Russian. Translation is on demand only, never automatic, because it
        // sends the text to an online service.
        property string descRaw: ""
        property string translatedTitle: ""
        property string translatedDesc: ""
        property bool   showTranslated: false
        property bool   translating: false

        readonly property string displayTitle:
            showTranslated && translatedTitle ? translatedTitle : wpmodel.title
        readonly property string displayDesc:
            showTranslated && translatedDesc ? translatedDesc : descRaw

        // A translation of the previous wallpaper must never linger on the next.
        onWpmodelChanged: {
            showTranslated = false;
            translatedTitle = "";
            translatedDesc = "";
        }

        function toggleTranslate() {
            if(showTranslated) { showTranslated = false; return; }
            // Already fetched once - just switch back to it, no second request.
            if(translatedTitle || translatedDesc) { showTranslated = true; return; }
            if(translating || !pyext) return;

            translating = true;
            const title = wpmodel.title || "";
            const desc = descRaw || "";
            Promise.all([
                title ? pyext.translate(title) : Promise.resolve(""),
                desc  ? pyext.translate(desc)  : Promise.resolve("")
            ]).then((res) => {
                right_content.translatedTitle = res[0];
                right_content.translatedDesc = res[1];
                right_content.showTranslated = true;
                right_content.translating = false;
            }).catch((reason) => {
                console.error("translate failed", reason);
                right_content.translating = false;
            });
        }

        visible: Layout.preferredWidth > image_size + content_margin*2 + right_content_scrollbar.width

        topPadding: 0
        leftPadding: 0
        rightPadding: 0
        bottomPadding: 0

        background: Rectangle {
            color: Theme.view.backgroundColor
        }

        contentItem: Flickable {
            anchors.fill: parent

            ScrollBar.vertical: ScrollBar { id: right_content_scrollbar }

            contentWidth: width - (right_content_scrollbar.visible ? right_content_scrollbar.width : 0)
            contentHeight: flick_content.implicitHeight

            clip: true
            boundsBehavior: Flickable.OvershootBounds

            ColumnLayout {
                id: flick_content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: right_content.content_margin
                anchors.rightMargin: anchors.leftMargin
                spacing: 8

                AnimatedImage { 
                    id: animated_image; 
                    Layout.topMargin: right_content.content_margin
                    Layout.preferredWidth: right_content.image_size
                    Layout.preferredHeight: Layout.preferredWidth
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop

                    source: Common.getWpModelPreviewSource(right_content.wpmodel)
                    fillMode: Image.PreserveAspectFit
                    cache: true
                    asynchronous: true
                    onStatusChanged: playing = (status == AnimatedImage.Ready)
                }

                Text {
                    Layout.alignment: Qt.AlignTop
                    Layout.minimumWidth: 0
                    Layout.fillWidth: true
                    Layout.minimumHeight: implicitHeight

                    text: right_content.displayTitle
                    // Kirigami.Theme directly rather than the plugin's Theme
                    // singleton: that singleton samples the palette once, from
                    // outside the item tree, and hands back a colour that is
                    // invisible against this panel.
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    spacing: 8

                    Control {
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Theme.view.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                            text: right_content.wpmodel.type
                        }
                    }

                    Control {
                        id: control_dir_size
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding
                        visible: false

                        background: Rectangle {
                            color: Theme.view.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                            readonly property bool _set_text: {
                                const dir = right_content.wpmodel.path;
                                if(!dir.match(Common.regex_path_check)) {
                                    control_dir_size.visible = false;
                                    return false;
                                }
                                pyext.get_dir_size(Common.urlNative(dir)).then(res => {
                                    this.text = Utils.prettyBytes(res);
                                    control_dir_size.visible = true;
                                }).catch(reason => console.error(reason));
                                return true;
                            }
                        }
                    }

                    Kirigami.ActionToolBar {
                        Layout.fillWidth: false
                        Layout.preferredWidth: implicitWidth
                        flat: true

                        actions: [
                            Kirigami.Action {
                                id: right_act_favor
                                // Named theme icons, not the bundled SVGs: those
                                // were tinted with a stale palette colour and came
                                // out invisible against the panel, which made the
                                // favourite button look like it did nothing.
                                icon.name: right_content.wpmodel.favor
                                    ? "user-bookmarks-symbolic"
                                    : "bookmark-add-symbolic"
                                tooltip: right_content.wpmodel.favor
                                    ? 'Remove from favorites'
                                    : 'Add to favorites'
                                onTriggered: picViewLoader.item.toggleFavor(right_content.wpmodel)
                            },
                            Kirigami.Action {
                                icon.name: "translator"
                                text: right_content.translating
                                    ? "…"
                                    : (right_content.showTranslated ? "原" : "EN")
                                enabled: !right_content.translating
                                tooltip: right_content.showTranslated
                                    ? "Show the original text"
                                    : "Translate the title and description to English\n(sends that text to Google Translate)"
                                onTriggered: right_content.toggleTranslate()
                            },
                            Kirigami.Action {
                                icon.name: "folder-remote-symbolic"
                                tooltip: "Open Workshop Link"
                                enabled: right_content.wpmodel.workshopid.match(Common.regex_workshop_online)
                                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(right_content.wpmodel.workshopid))
                            },
                            Kirigami.Action {
                                icon.name: "folder-open-symbolic"
                                tooltip: "Open Containing Folder"
                                onTriggered: Qt.openUrlExternally(right_content.wpmodel.path)
                            }
                        ]
                    }
                }

                ListView {
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    implicitWidth: contentItem.childrenRect.width
                    implicitHeight: contentItem.childrenRect.height

                    orientation: ListView.Horizontal
                    model: ListModel {}
                    readonly property bool _set_model: {
                        const wpmodel = right_content.wpmodel;
                        const tags = right_content.wpmodel.tags;
                        const playlists = right_content.wpmodel.playlists;
                        const _model = this.model;
                        _model.clear();
                        for(const i of Array(tags.length).keys())
                            _model.append(tags.get(i));
                        for(const i of Array(playlists.length).keys()){
                            var playlist = playlists.get(i);
                            if(playlist != null) { _model.append(playlists.get(i)); }
                        }
                        _model.append({key: wpmodel.contentrating});
                        return true;
                    }
                    clip: false
                    spacing: 8

                    delegate: Control {
                        leftPadding: 8
                        topPadding: 4
                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Theme.activeBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            text: model.key
                        }
                    }
                }

                Component {
                    id: right_opt_combox
                    ComboBox {
                        property int def_val

                        textRole: "text"
                        onActivated: {}

                        property int res_val: currentIndex && Common.cbCurrentValue(this)
                        function finish() {
                            currentIndex = Common.cbIndexOfValue(this, def_val);
                        }
                    }
                }
                Component {
                    id: right_opt_switch
                    Switch {
                        property bool def_val
                        property bool res_val: checked
                        function finish() {
                            checked = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_spinbox
                    SpinBox {
                        property int def_val
                        property int res_val: value
                        function finish() {
                            value = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_dspinbox
                    DoubleSpinBox {
                        property real def_val
                        property real res_val: dValue
                        function finish() {
                            dValue = def_val;
                        }
                    }
                }
                // Slider plus a live readout, for the numeric options. A bare
                // spin box gives no sense of where a value sits in its range,
                // which matters most for the ones you set by eye - zoom, offset
                // and the colour adjustments.
                Component {
                    id: right_opt_slider
                    RowLayout {
                        id: sliderOpt

                        property real def_val: 0
                        property real from: 0
                        property real to: 100
                        property real stepSize: 1
                        // 0 shows a whole number; 1 shows one decimal (Speed).
                        property int decimals: 0

                        property real res_val: sliderOpt.decimals === 0
                            ? Math.round(slider.value) : slider.value

                        function finish() { slider.value = sliderOpt.def_val; }

                        spacing: Kirigami.Units.smallSpacing

                        Slider {
                            id: slider
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                            from: sliderOpt.from
                            to: sliderOpt.to
                            stepSize: sliderOpt.stepSize
                            snapMode: Slider.SnapAlways
                            live: true
                        }
                        Label {
                            Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5
                            horizontalAlignment: Text.AlignRight
                            color: Kirigami.Theme.textColor
                            text: slider.value.toFixed(sliderOpt.decimals)
                        }
                    }
                }

                // Per-wallpaper options used to reach disk only when OK was
                // pressed. Save as soon as something changes instead, so closing
                // the dialog any other way does not discard it. Coalesced,
                // because a slider emits a change per step.
                //
                // Lives out here rather than inside right_opts: OptionGroup's
                // default property is a children list, which only accepts Items,
                // and a Timer in there takes the whole config page down.
                Timer {
                    id: perOptSave
                    interval: 300
                    onTriggered: right_opts.save_changes()
                }

                OptionGroup {
                    id: right_opts
                    Layout.fillWidth: true

                    readonly property string workshopid: right_content.wpmodel.workshopid

                    property var config_resets: new Set()
                    property var config_changes: ({})
                    property var config: ({})
                    property bool _set_config: {
                        if (workshopid)
                            pyext.read_wallpaper_config(workshopid).then(res => { 
                                this.config = res;
                            });
                        return true;
                    }
                    function save_changes() {
                        config_resets.forEach((wid) => {
                            pyext.reset_wallpaper_config(wid).then(res => {});
                        });
                        Object.entries(config_changes).forEach(([wid, cfg]) => {
                            pyext.write_wallpaper_config(wid, cfg).then(res => {
                                // Was `this.cofnig.update(...)` - a typo on a
                                // property that does not exist, so this threw
                                // inside the promise and the pending changes
                                // were never cleared.
                                if(wid === right_opts.workshopid)
                                    right_opts.config = Object.assign({}, right_opts.config, cfg);
                                right_opts.config_changes = {};
                            });
                        });

                        config_resets.clear();
                    }

                    function set_config(key, val) {
                        if(!key || !workshopid) return;

                        if (!config_changes[workshopid])
                            config_changes[workshopid] = {}
                        config_changes[workshopid][key] = val;

                        this.config_changesChanged();
                        cfg_PerOptChanged = !cfg_PerOptChanged;
                        perOptSave.restart();
                    }
                    function reset_config() {
                        config_resets.add(workshopid);
                        delete config_changes[workshopid];
                        config = {}
                        cfg_PerOptChanged = !cfg_PerOptChanged;
                        perOptSave.restart();
                    }
                    function in_config_changes(key) {
                        return config_changes.hasOwnProperty(workshopid) && config_changes[workshopid].hasOwnProperty(key);
                    }

                    function get_config_val(key) {
                        if (in_config_changes(key))
                            return config_changes[workshopid][key];
                        if (config.hasOwnProperty(key))
                            return config[key];
                        return null;
                    }
                    function has_change(key) {
                        return config.hasOwnProperty(key) || in_config_changes(key);
                    }

                    header.text: 'Option'
                    header.text_color: Kirigami.Theme.textColor
                    header.icon: '../../images/cheveron-down.svg'
                    header.color: Theme.activeBackgroundColor

                    header.actor: Kirigami.ActionToolBar {
                        Layout.fillWidth: true
                        alignment: Qt.AlignRight
                        flat: true
                        actions: [
                            Kirigami.Action {
                                text: 'Reset'
                                onTriggered: {
                                    right_opts.reset_config();
                                }
                            }
                        ]
                    }
                    Repeater {
                        property bool markModel: false;
                        model: [
                            {
                                mark_: markModel,
                                text: 'Display',
                                config_key: 'display_mode',
                                comp: right_opt_combox,
                                props: {
                                    model: [
                                        {
                                            text: "Keep Aspect Ratio",
                                            value: Common.DisplayMode.Aspect
                                        },
                                        {
                                            text: "Scale and Crop",
                                            value: Common.DisplayMode.Crop
                                        },
                                        {
                                            text: "Scale to Fill",
                                            value: Common.DisplayMode.Scale
                                        },
                                    ],
                                    def_val: cfg_DisplayMode,
                                }
                            },
                            {
                                text: 'Mute Audio',
                                config_key: 'mute_audio',
                                comp: right_opt_switch,
                                props: {
                                    def_val: cfg_MuteAudio
                                },
                            },
                            {
                                text: 'Volume',
                                config_key: 'volume', 
                                comp: right_opt_slider,
                                props: {
                                    def_val: cfg_Volume,
                                    from: 1,
                                    to: 100,
                                    stepSize: 1,
                                },
                            },
                            {
                                text: 'Speed',
                                config_key: 'speed',
                                comp: right_opt_slider,
                                props: {
                                    def_val: cfg_Speed,
                                    from: 0.1,
                                    to: 16,
                                    stepSize: 0.1,
                                    decimals: 1,
                                },
                            },
                            {
                                text: 'Frame Rate',
                                config_key: 'fps',
                                comp: right_opt_slider,
                                props: {
                                    def_val: cfg_Fps,
                                    from: 1,
                                    to: 240,
                                    stepSize: 1,
                                },
                            },
                            {
                                text: 'Mouse Input',
                                config_key: 'mouse_input',
                                comp: right_opt_switch,
                                props: {
                                    def_val: cfg_MouseInput,
                                },
                            },

                            // --- position ---------------------------------
                            // Wallpaper Engine's flip / position controls.
                            // Applied as a QML transform on the backend item,
                            // so these work for scene, video and web alike.
                            {
                                text: 'Flip Horizontally',
                                config_key: 'flip_h',
                                comp: right_opt_switch,
                                props: { def_val: false },
                            },
                            {
                                text: 'Flip Vertically',
                                config_key: 'flip_v',
                                comp: right_opt_switch,
                                props: { def_val: false },
                            },
                            {
                                text: 'Rotate',
                                config_key: 'rotate',
                                comp: right_opt_combox,
                                props: {
                                    model: [
                                        { text: "None",  value: 0   },
                                        { text: "90°",   value: 90  },
                                        { text: "180°",  value: 180 },
                                        { text: "270°",  value: 270 }
                                    ],
                                    def_val: 0,
                                }
                            },
                            {
                                text: 'Zoom %',
                                config_key: 'zoom',
                                comp: right_opt_slider,
                                props: { def_val: 100, from: 10, to: 400, stepSize: 5 },
                            },
                            {
                                text: 'Offset X %',
                                config_key: 'offset_x',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: -100, to: 100, stepSize: 1 },
                            },
                            {
                                text: 'Offset Y %',
                                config_key: 'offset_y',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: -100, to: 100, stepSize: 1 },
                            },

                            // --- filtering --------------------------------
                            // Colour adjustment via MultiEffect. Neutral values
                            // skip the extra render pass entirely.
                            {
                                text: 'Brightness',
                                config_key: 'brightness',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: -100, to: 100, stepSize: 5 },
                            },
                            {
                                text: 'Contrast',
                                config_key: 'contrast',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: -100, to: 100, stepSize: 5 },
                            },
                            {
                                text: 'Saturation',
                                config_key: 'saturation',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: -100, to: 100, stepSize: 5 },
                            },
                            {
                                text: 'Blur',
                                config_key: 'blur',
                                comp: right_opt_slider,
                                props: { def_val: 0, from: 0, to: 100, stepSize: 5 },
                            },

                        ]
                        OptionItem {
                            text: modelData.text
                            text_color: Kirigami.Theme.textColor

                            property bool is_changed: right_opts.config && 
                                right_opts.config_changes && 
                                right_opts.has_change(modelData.config_key)

                            icon: is_changed ? Qt.resolvedUrl('../../images/edit-pencil.svg') : ''
                            actor: Loader {
                                sourceComponent: modelData.comp
                                onLoaded: {
                                    Object.entries(modelData.props).forEach(([key, value]) => {
                                        this.item[key] = value;
                                    });
                                    const changed_val = right_opts.get_config_val(modelData.config_key);
                                    if(changed_val !== null) {
                                        this.item['def_val'] = changed_val;
                                    }

                                    this.item.finish();
                                    this.item.onRes_valChanged.connect(() => {
                                        right_opts.set_config(modelData.config_key, this.item.res_val);
                                    });
                                }
                            }
                        }
                        Component.onCompleted: {
                            right_opts.onConfigChanged.connect(() => {
                                markModel = !markModel;
                            });
                        }
                    }
                }
                PlasmaComponents.TextArea {
                    Layout.alignment: Qt.AlignTop
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.minimumHeight: implicitHeight

                    // Bound rather than assigned, so the Translate button can
                    // swap the text without this having to re-read the file.
                    visible: Boolean(right_content.displayDesc)
                    text: right_content.displayDesc
                        ? BBCode.parser.parse(right_content.displayDesc) : ''
                    color: Kirigami.Theme.textColor
                    readonly property bool _set_text: {
                        const path = Common.getWpModelProjectPath(right_content.wpmodel);
                        right_content.descRaw = '';
                        if(path) {
                            pyext.readfile(Common.urlNative(path)).then(value => {
                                const project = Utils.parseJson(value);
                                right_content.descRaw = project && project.description
                                    ? project.description : '';
                            }).catch(reason => console.error(`read '${path}' error\n`, reason));
                        }
                        return true;
                    }
                    font.bold: false
 
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                    horizontalAlignment: Text.AlignLeft
                    readOnly: true

                    onLinkActivated: Qt.openUrlExternally(link)
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                        acceptedButtons: Qt.NoButton
                    }
                }
            }
        }
    }
}
