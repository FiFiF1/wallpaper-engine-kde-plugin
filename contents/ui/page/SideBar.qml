import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5
import QtQuick.Window 2.0 // for Screen

import ".."
import "../components"

import "../js/utils.mjs" as Utils

import org.kde.kirigami 2.6 as Kirigami

// Wallpaper-Engine-style left rail: monitor selection on top, then library
// actions, then sorting and the full filter list underneath.
Control {
    id: sidebar

    // Which monitor a wallpaper click should land on.
    //   >= 0  -> that Plasma desktop index
    //   -1    -> every monitor at once
    property int applyTarget: currentScreenIndex

    // False until the user actually clicks a monitor row. While false, clicking a
    // wallpaper must behave exactly like stock Plasma: edit only the containment
    // this dialog belongs to, via the cfg_ properties, applied on OK.
    //
    // This matters because currentScreenIndex is derived from the window's screen,
    // which is NOT guaranteed to be the containment being edited (Plasma can place
    // the dialog elsewhere, e.g. after a display hotplug). Relying on it to decide
    // whether to write is how an unattended auto-select ended up pushing a
    // wallpaper onto the wrong screen. Treat it as a display hint only.
    property bool targetChosen: false

    readonly property alias screenModel: screenModel

    // The screen this config dialog was opened on. Plasma opens the dialog on
    // the containment's own screen, so the attached Screen tells us which one
    // we are natively editing (that one keeps normal OK/Cancel semantics).
    readonly property int currentScreenIndex: {
        const list = screenModel.screens;
        if (!list || !list.length) return 0;
        // Position is the most reliable link between this dialog's window and a
        // Plasma desktop; fall back to the output name, then to the first screen.
        for (var i = 0; i < list.length; i++) {
            if (list[i].x === Screen.virtualX && list[i].y === Screen.virtualY) return list[i].index;
        }
        for (var j = 0; j < list.length; j++) {
            if (list[j].name && list[j].name === Screen.name) return list[j].index;
        }
        return list[0].index;
    }

    // What the monitor button reads. Before the user picks anything this shows
    // the screen the dialog belongs to, because that is where OK would apply.
    readonly property string targetLabel: {
        if (targetChosen && applyTarget === -1) return "All monitors";
        const idx = targetChosen ? applyTarget : currentScreenIndex;
        const list = screenModel.screens;
        for (var i = 0; i < list.length; i++) {
            if (list[i].index === idx) {
                const base = list[i].name ? list[i].name : "Screen " + (idx + 1);
                return idx === currentScreenIndex ? base + "  (this one)" : base;
            }
        }
        return "This screen";
    }

    signal libraryRequested()
    signal refreshRequested()

    // Emitted when the user picks a monitor, so the grid can move its selection
    // to whatever that monitor is currently showing. -1 means "all monitors".
    signal targetPicked(int index)

    Layout.preferredWidth: Kirigami.Units.gridUnit * 14
    Layout.minimumWidth: Kirigami.Units.gridUnit * 12
    Layout.fillHeight: true

    topPadding: Kirigami.Units.smallSpacing
    leftPadding: 0
    rightPadding: Kirigami.Units.smallSpacing
    bottomPadding: 0

    ScreenModel { id: screenModel }

    function clearSearch() {
        searchField.text = "";
        searchDebounce.stop();
        root.searchStr = "";
    }

    function toggleFilter(idx) {
        const vals = Common.filterModel.getValueArray(cfg_FilterStr);
        vals[idx] = Number(!vals[idx]);
        cfg_FilterStr = Utils.intArrayToStr(vals);
    }

    function setAllFilters(on) {
        const vals = Common.filterModel.getValueArray(cfg_FilterStr);
        for (var i = 0; i < Common.filterModel.count; i++) {
            if (Common.filterModel.get(i).type !== '_nocheck') vals[i] = Number(on);
        }
        cfg_FilterStr = Utils.intArrayToStr(vals);
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        // ------------------------------------------------------------ search
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search wallpapers…"
                // No binding to root.searchStr: the debounce timer writes it, and
                // binding back would fight the user's typing.
                onTextEdited: searchDebounce.restart()
                Keys.onEscapePressed: sidebar.clearSearch()

                Timer {
                    id: searchDebounce
                    interval: 200
                    onTriggered: root.searchStr = searchField.text
                }
            }

            ToolButton {
                visible: searchField.text.length > 0
                icon.name: "edit-clear"
                onClicked: sidebar.clearSearch()
                ToolTip.visible: hovered
                ToolTip.text: "Clear search"
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            visible: root.searchStr.length > 0
            opacity: 0.55
            elide: Text.ElideRight
            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
            text: wpListModel.model.count + " match"
                  + (wpListModel.model.count === 1 ? "" : "es")
        }

        // ---------------------------------------------------------- monitors
        Kirigami.Heading {
            text: "Monitors"
            level: 5
            opacity: 0.7
            Layout.leftMargin: Kirigami.Units.smallSpacing
        }

        // One button showing the current target, opening a map of the monitors
        // laid out the way the display settings show them. A flat list of output
        // names could not answer "which screen is which"; the map can, because
        // each monitor is drawn in place showing its own wallpaper.
        Button {
            Layout.fillWidth: true
            icon.name: sidebar.applyTarget === -1 ? "computer" : "video-display"
            text: sidebar.targetLabel
            ToolTip.visible: hovered
            ToolTip.text: "Choose which monitor a wallpaper click applies to"
            onClicked: screenChooser.open()
        }

        ScreenChooser {
            id: screenChooser

            // Popups are positioned against their parent, and the sidebar is a
            // narrow rail - centre it on the whole config page instead.
            parent: root
            anchors.centerIn: parent

            screenModel: sidebar.screenModel
            currentIndex: sidebar.currentScreenIndex
            selectedIndex: sidebar.targetChosen ? sidebar.applyTarget : sidebar.currentScreenIndex

            onAboutToShow: sidebar.screenModel.refresh()
            onChosen: (index) => {
                sidebar.applyTarget = index;
                sidebar.targetChosen = true;
                sidebar.targetPicked(index);
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            wrapMode: Text.WordWrap
            opacity: 0.55
            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
            text: !sidebar.targetChosen
                ? "Picking a wallpaper applies to this screen on OK."
                : (sidebar.applyTarget === -1
                    ? "Picking a wallpaper applies to every monitor immediately."
                    : "Picking a wallpaper applies to the selected monitor immediately.")
        }

        Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }

        // ----------------------------------------------------------- library
        Button {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            icon.name: "steam"
            text: "Get Wallpapers"
            ToolTip.visible: hovered
            ToolTip.text: "Open the Wallpaper Engine Steam Workshop.\nSubscribed items download automatically and appear here after Refresh."
            onClicked: Qt.openUrlExternally("steam://url/SteamWorkshopPage/431960")
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Button {
                Layout.fillWidth: true
                icon.name: "folder-symbolic"
                text: "Library"
                ToolTip.visible: hovered
                ToolTip.text: cfg_SteamLibraryPath ? cfg_SteamLibraryPath : "Select your Steam library folder"
                onClicked: sidebar.libraryRequested()
            }
            Button {
                icon.name: "view-refresh-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "Rescan the library"
                onClicked: {
                    sidebar.refreshRequested();
                    sidebar.screenModel.refresh();
                }
            }
        }

        Button {
            Layout.fillWidth: true
            icon.name: "internet-web-browser"
            text: "Workshop in Browser"
            flat: true
            onClicked: Qt.openUrlExternally("https://steamcommunity.com/app/431960/workshop/")
        }

        Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }

        // -------------------------------------------------------------- sort
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Label { text: "Sort"; opacity: 0.7; Layout.leftMargin: Kirigami.Units.smallSpacing }
            ComboBox {
                Layout.fillWidth: true
                textRole: "text"
                model: [
                    { text: "Date added",  value: Common.SortMode.Modified },
                    { text: "Name",        value: Common.SortMode.Name },
                    { text: "Type",        value: Common.SortMode.Type },
                    { text: "Favorites",   value: Common.SortMode.Favorite },
                    { text: "Workshop Id", value: Common.SortMode.Id }
                ]
                currentIndex: Math.max(0, Common.modelIndexOfValue(model, cfg_SortMode))
                onActivated: (i) => { cfg_SortMode = model[i].value; }
            }
            ToolButton {
                checkable: true
                checked: cfg_SortReverse
                icon.name: cfg_SortReverse ? "view-sort-ascending-symbolic"
                                           : "view-sort-descending-symbolic"
                onToggled: cfg_SortReverse = checked
                ToolTip.visible: hovered
                ToolTip.text: cfg_SortReverse
                    ? "Ascending — oldest / A→Z first"
                    : "Descending — newest / Z→A first"
            }
        }

        // Thumbnail size: how many wallpapers fit per row.
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Label {
                text: "Size"
                opacity: 0.7
                color: Kirigami.Theme.textColor
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }
            Slider {
                Layout.fillWidth: true
                from: 50
                to: 220
                stepSize: 10
                snapMode: Slider.SnapAlways
                value: cfg_ThumbScale > 0 ? cfg_ThumbScale : 100
                onMoved: cfg_ThumbScale = Math.round(value)
            }
            Label {
                text: (cfg_ThumbScale > 0 ? cfg_ThumbScale : 100) + "%"
                color: Kirigami.Theme.textColor
                opacity: 0.7
            }
        }

        // ----------------------------------------------------------- filters
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            Kirigami.Heading {
                text: "Filters"
                level: 5
                opacity: 0.7
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }
            ToolButton {
                text: "All"
                onClicked: sidebar.setAllFilters(true)
                ToolTip.visible: hovered
                ToolTip.text: "Enable every filter"
            }
            ToolButton {
                text: "None"
                onClicked: sidebar.setAllFilters(false)
                ToolTip.visible: hovered
                ToolTip.text: "Disable every filter"
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            // Plasma sizes the whole config page from currentItem.implicitHeight.
            // Left alone, this ScrollView would report the height of the entire
            // filter list, inflate the page, and squeeze the wallpaper grid to
            // nothing. Report zero and just fill whatever height is available.
            implicitHeight: 0

            ColumnLayout {
                width: Math.max(1, parent.width - Kirigami.Units.smallSpacing)
                spacing: 0

                Repeater {
                    model: Common.filterModel
                    delegate: Item {
                        required property int index
                        required property string text
                        required property string type

                        Layout.fillWidth: true
                        implicitHeight: type === '_nocheck' ? headerLabel.implicitHeight + Kirigami.Units.largeSpacing
                                                            : filterBox.implicitHeight

                        Label {
                            id: headerLabel
                            visible: type === '_nocheck'
                            anchors.left: parent.left
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.bottom: parent.bottom
                            text: parent.text
                            opacity: 0.55
                            font.bold: true
                            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                        }

                        CheckBox {
                            id: filterBox
                            visible: type !== '_nocheck'
                            anchors.left: parent.left
                            anchors.right: parent.right
                            text: parent.text
                            checked: Boolean(Common.filterModel.getValueArray(cfg_FilterStr)[index])
                            onToggled: sidebar.toggleFilter(index)
                        }
                    }
                }
            }
        }
    }
}
