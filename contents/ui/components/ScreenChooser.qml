import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5

import ".."

import org.kde.kirigami 2.6 as Kirigami

// Wallpaper-Engine-style monitor picker.
//
// A flat list of output names ("DP-2", "HDMI-A-3") tells you nothing about
// which physical panel is which, so this mirrors the Display Configuration
// module instead: every monitor is drawn where it actually sits, at its real
// relative size, showing the wallpaper it is currently displaying. The picture
// is what identifies the screen - you just look at your desk and click the one
// that matches.
Popup {
    id: chooser

    property var screenModel: null

    // Plasma desktop index to highlight; -1 means "every monitor".
    property int selectedIndex: 0
    // The desktop this config dialog natively edits, marked "this one".
    property int currentIndex: 0

    // index >= 0 for a single monitor, -1 for all of them.
    signal chosen(int index)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: Kirigami.Units.largeSpacing

    readonly property var screens: screenModel ? screenModel.screens : []

    // Bounding box of the whole desktop in Plasma's virtual coordinates. Screens
    // are not necessarily flush or top-aligned, so this cannot be derived by
    // summing widths - it has to be a real min/max over the arrangement.
    readonly property var bounds: {
        const list = chooser.screens;
        if (!list || !list.length) return { x: 0, y: 0, w: 1, h: 1 };
        let x0 = list[0].x, y0 = list[0].y;
        let x1 = list[0].x + list[0].width, y1 = list[0].y + list[0].height;
        for (var i = 1; i < list.length; i++) {
            x0 = Math.min(x0, list[i].x);
            y0 = Math.min(y0, list[i].y);
            x1 = Math.max(x1, list[i].x + list[i].width);
            y1 = Math.max(y1, list[i].y + list[i].height);
        }
        return { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0) };
    }

    function previewFor(s) {
        if (!s) return "";
        const id = s.workshopid;
        // wpListModel comes from the config page's context. Guarded so this
        // component still renders if it is not there yet (or at all, as when
        // rendering the chooser on its own for a UI check).
        const m = (typeof wpListModel !== "undefined" && wpListModel)
            ? wpListModel.model : null;
        if (id && m) {
            for (var i = 0; i < m.count; i++) {
                const el = m.get(i);
                if (el.workshopid === id) {
                    const p = Common.getWpModelPreviewSource(el);
                    if (p) return p;
                }
            }
        }
        // The grid model is filtered, so a screen's current wallpaper is often
        // not in it. Fall back to the conventional preview file sitting next to
        // the wallpaper; if that does not exist either the Image stays hidden
        // and the placeholder icon shows through.
        const raw = screenModel ? screenModel.expandPath(s.source) : String(s.source || "");
        const dir = raw.split('+')[0].replace(/\/[^\/]*$/, "");
        return dir ? dir + "/preview.jpg" : "";
    }

    function labelFor(s) {
        if (!s) return "";
        return s.name ? s.name : "Screen " + (s.index + 1);
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            text: "Choose monitor"
            level: 3
        }

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.65
            text: "Monitors are laid out as they are arranged in your display settings, "
                + "each showing its current wallpaper."
        }

        // ------------------------------------------------------------- the map
        Item {
            id: map
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            Layout.preferredWidth: Kirigami.Units.gridUnit * 34
            Layout.preferredHeight: Math.max(
                Kirigami.Units.gridUnit * 7,
                Math.min(Kirigami.Units.gridUnit * 17,
                         width * chooser.bounds.h / chooser.bounds.w))

            // Uniform scale so the arrangement keeps its real proportions;
            // "scale" itself is taken by Item, hence the name.
            readonly property real sc: Math.min(width / chooser.bounds.w,
                                                height / chooser.bounds.h)
            readonly property real offX: (width - chooser.bounds.w * sc) / 2
            readonly property real offY: (height - chooser.bounds.h * sc) / 2

            Repeater {
                model: chooser.screens

                delegate: Item {
                    id: cell
                    required property var modelData

                    readonly property bool isSelected: chooser.selectedIndex === modelData.index
                    readonly property bool isCurrent: chooser.currentIndex === modelData.index

                    x: map.offX + (modelData.x - chooser.bounds.x) * map.sc
                    y: map.offY + (modelData.y - chooser.bounds.y) * map.sc
                    width: Math.max(24, modelData.width * map.sc)
                    height: Math.max(18, modelData.height * map.sc)

                    Rectangle {
                        anchors.fill: parent
                        // A visible gutter between adjacent monitors, so a
                        // side-by-side pair does not read as one wide screen.
                        anchors.margins: 2
                        radius: 4
                        clip: true

                        color: Theme.view.backgroundColor
                        border.width: cell.isSelected ? 3 : 1
                        border.color: cell.isSelected
                            ? Kirigami.Theme.highlightColor
                            : (hover.containsMouse ? Kirigami.Theme.highlightColor
                                             : Kirigami.Theme.textColor)
                        opacity: cell.isSelected || hover.containsMouse ? 1.0 : 0.85

                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: Math.min(parent.width, parent.height) / 3
                            height: width
                            source: "video-display"
                            visible: thumb.status !== Image.Ready
                            opacity: 0.5
                        }

                        Image {
                            id: thumb
                            anchors.fill: parent
                            source: chooser.previewFor(cell.modelData)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            smooth: true
                            visible: status === Image.Ready
                        }

                        // Keeps the labels readable over a bright wallpaper.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: Math.min(parent.height, labels.implicitHeight
                                             + Kirigami.Units.smallSpacing * 2)
                            color: "#000000"
                            opacity: 0.55
                            visible: thumb.status === Image.Ready
                        }

                        ColumnLayout {
                            id: labels
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: 0

                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                color: thumb.status === Image.Ready ? "white" : Kirigami.Theme.textColor
                                font.bold: true
                                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                                text: chooser.labelFor(cell.modelData)
                                    + (cell.isCurrent ? "  (this one)" : "")
                            }
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                visible: cell.height > Kirigami.Units.gridUnit * 3
                                opacity: 0.85
                                color: thumb.status === Image.Ready ? "white" : Kirigami.Theme.textColor
                                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize - 1)
                                text: cell.modelData.width + "×" + cell.modelData.height
                            }
                        }

                        // MouseArea rather than Hover/TapHandler: the pointer
                        // handlers need a newer QtQuick import than this plugin
                        // uses, and mixing import versions here made the whole
                        // config page fail to construct.
                        MouseArea {
                            id: hover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                chooser.chosen(cell.modelData.index);
                                chooser.close();
                            }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------- actions
        Button {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: chooser.screens.length > 1
            icon.name: "computer"
            text: "All monitors"
            highlighted: chooser.selectedIndex === -1
            onClicked: {
                chooser.chosen(-1);
                chooser.close();
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
                text: "Cancel"
                onClicked: chooser.close()
            }
        }
    }
}
