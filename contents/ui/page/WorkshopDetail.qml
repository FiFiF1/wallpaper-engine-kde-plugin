import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5
import QtQuick.Window 2.2

import ".."

import org.kde.kirigami 2.6 as Kirigami

// Detail view for one Workshop item: the full-size preview plus everything the
// listing grid has no room for - description, tags, rating, subscriber counts,
// file size and dates.
//
// Sizing note: this popup fills in twice - once from what the grid already
// knows, then again half a second later when the scraped detail page arrives.
// Nothing here may be sized by its content, or that second fill grows the popup
// and, since it is centred, pushes its top (the picture) up out of the dialog.
// So the frame is a fixed fraction of the window and the body scrolls inside it.
Popup {
    id: detail

    property string itemId: ""
    property var data: null
    property bool busy: false
    property string errorText: ""
    property bool installed: false

    // Centre on the dialog window rather than on the config page. The page is a
    // scrolling item that can be taller than the dialog and scrolled away from
    // its own middle, which would size this popup to a height the dialog cannot
    // show and centre it somewhere off-screen. The real parent is picked in
    // show(), once there is a window to ask about; root is only the fallback
    // for the moment before that.
    parent: root
    anchors.centerIn: parent

    readonly property real areaWidth:  parent ? parent.width  : Kirigami.Units.gridUnit * 40
    readonly property real areaHeight: parent ? parent.height : Kirigami.Units.gridUnit * 30

    width:  Math.min(Kirigami.Units.gridUnit * 36, areaWidth  - Kirigami.Units.gridUnit * 2)
    height: Math.min(Kirigami.Units.gridUnit * 38, areaHeight - Kirigami.Units.gridUnit * 2)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: Kirigami.Units.largeSpacing

    // ------------------------------------------------------------- translate
    // Workshop descriptions are very often Chinese, Japanese or Russian. Same
    // deal as the library pane: on demand only, never automatic, because it
    // sends the text to an online service.
    property string translatedTitle: ""
    property string translatedDesc: ""
    property bool   showTranslated: false
    property bool   translating: false

    readonly property string rawTitle: detail.data ? String(detail.data.title || "") : ""
    readonly property string rawDesc:  detail.data ? String(detail.data.description || "") : ""

    readonly property string displayTitle:
        showTranslated && translatedTitle ? translatedTitle : rawTitle
    readonly property string displayDesc:
        showTranslated && translatedDesc ? translatedDesc : rawDesc

    // Subscribing or unsubscribing while this is open changes the answer, so
    // re-ask rather than leaving a stale "In library" badge and Unsubscribe
    // button behind.
    Connections {
        target: wpListModel
        function onModelRefreshed() {
            if(detail.itemId)
                detail.installed = wpListModel.hasWorkshopId(detail.itemId);
        }
    }

    function toggleTranslate() {
        if(showTranslated) { showTranslated = false; return; }
        // Already fetched once - just switch back to it, no second request.
        if(translatedTitle || translatedDesc) { showTranslated = true; return; }
        if(translating || !pyext || !pyext.ok) return;

        detail.translating = true;
        const id = detail.itemId;
        const title = detail.rawTitle;
        const desc = detail.rawDesc;
        Promise.all([
            title ? pyext.translate(title) : Promise.resolve(""),
            desc  ? pyext.translate(desc)  : Promise.resolve("")
        ]).then((res) => {
            detail.translating = false;
            // Ignore a translation that lands after the user moved on.
            if(detail.itemId !== id) return;
            detail.translatedTitle = res[0];
            detail.translatedDesc = res[1];
            detail.showTranslated = true;
        }).catch((reason) => {
            console.error("translate failed", reason);
            detail.translating = false;
        });
    }

    function show(id, fallbackTitle, fallbackPreview) {
        // Re-parent to the window itself now that one exists. Popups always
        // draw in the overlay above everything; the parent only decides what
        // this is measured and centred against.
        const win = (typeof root !== "undefined" && root) ? root.Window.window : null;
        if(win && win.contentItem) detail.parent = win.contentItem;

        detail.itemId = String(id);
        // A translation of the previous item must never linger on the next.
        detail.showTranslated = false;
        detail.translatedTitle = "";
        detail.translatedDesc = "";
        detail.translating = false;
        // Show what the grid already knows straight away, so the dialog is never
        // blank while the detail page is being fetched.
        detail.data = { id: detail.itemId, title: fallbackTitle || "",
                        author: "", description: "", preview: fallbackPreview || "",
                        tags: [], stats: [], details: [], rating: "", num_ratings: "" };
        detail.installed = wpListModel.hasWorkshopId(detail.itemId);
        detail.errorText = "";
        detail.busy = true;
        detail.open();

        pyext.workshop_item(detail.itemId).then((res) => {
            detail.busy = false;
            if(!res) { detail.errorText = "No response."; return; }
            if(res.error) { detail.errorText = res.error; return; }
            // Ignore a reply that arrives after the user moved on.
            if(String(res.id) !== detail.itemId) return;
            // Never trade a picture for no picture: if the detail page yielded
            // no usable image, keep the thumbnail the grid already gave us
            // rather than blanking the view.
            if(!res.preview && detail.data && detail.data.preview)
                res.preview = detail.data.preview;
            detail.data = res;
        }).catch((reason) => {
            detail.busy = false;
            detail.errorText = String(reason);
        });
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Heading {
                Layout.fillWidth: true
                // Long titles must elide, not widen the popup.
                Layout.preferredWidth: 0
                level: 3
                elide: Text.ElideRight
                text: detail.displayTitle
            }
            Label {
                visible: detail.installed
                text: "In library"
                color: Kirigami.Theme.positiveTextColor
            }
            ToolButton {
                icon.name: "translator"
                text: detail.translating ? "…" : (detail.showTranslated ? "原" : "EN")
                display: AbstractButton.TextBesideIcon
                enabled: !detail.translating
                    && (detail.rawTitle.length > 0 || detail.rawDesc.length > 0)
                ToolTip.visible: hovered
                ToolTip.text: detail.showTranslated
                    ? "Show the original text"
                    : "Translate the title and description"
                onClicked: detail.toggleTranslate()
            }
            ToolButton {
                icon.name: "window-close"
                onClicked: detail.close()
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            visible: detail.busy || detail.errorText.length > 0
            opacity: 0.7
            elide: Text.ElideRight
            color: Kirigami.Theme.textColor
            text: detail.busy ? "Loading details…" : detail.errorText
        }

        // Everything that varies in size lives in here, so the popup frame
        // stays put no matter what the detail page turns out to contain.
        Flickable {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: bodyCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar { id: bodyScroll }

            ColumnLayout {
                id: bodyCol
                width: body.width - (bodyScroll.visible ? bodyScroll.width : 0)
                spacing: Kirigami.Units.smallSpacing

                // --------------------------------------------------- the image
                Image {
                    id: bigShot
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    Layout.preferredHeight: width * 0.5625
                    source: detail.data ? detail.data.preview : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    smooth: true

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: Kirigami.Units.iconSizes.large
                        height: width
                        source: "view-preview"
                        visible: bigShot.status !== Image.Ready
                        opacity: 0.4
                    }
                }

                Label {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    opacity: 0.75
                    wrapMode: Text.WordWrap
                    color: Kirigami.Theme.textColor
                    visible: detail.data && (detail.data.author || detail.data.rating)
                    text: {
                        if(!detail.data) return "";
                        let s = detail.data.author ? "by " + detail.data.author : "";
                        if(detail.data.rating) {
                            if(s) s += "   ·   ";
                            s += detail.data.rating + "★";
                            if(detail.data.num_ratings) s += " (" + detail.data.num_ratings + ")";
                        }
                        return s;
                    }
                }

                // Subscribers / favourites / visitors, then size and dates.
                Flow {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    spacing: Kirigami.Units.largeSpacing

                    Repeater {
                        model: detail.data ? detail.data.stats : []
                        delegate: Label {
                            required property var modelData
                            color: Kirigami.Theme.textColor
                            opacity: 0.75
                            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                            text: modelData.value + " " + modelData.label
                        }
                    }
                    Repeater {
                        model: detail.data ? detail.data.details : []
                        delegate: Label {
                            required property var modelData
                            color: Kirigami.Theme.textColor
                            opacity: 0.75
                            font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                            text: modelData.label + ": " + modelData.value
                        }
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: detail.data ? detail.data.tags : []
                        delegate: Rectangle {
                            required property var modelData
                            radius: 3
                            color: Kirigami.Theme.alternateBackgroundColor
                            width: tagText.implicitWidth + Kirigami.Units.largeSpacing
                            height: tagText.implicitHeight + Kirigami.Units.smallSpacing
                            Label {
                                id: tagText
                                anchors.centerIn: parent
                                text: modelData
                                color: Kirigami.Theme.textColor
                                font.pointSize: Math.max(6, Kirigami.Theme.smallFont.pointSize)
                            }
                        }
                    }
                }

                // ------------------------------------------------ description
                TextEdit {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    readOnly: true
                    wrapMode: Text.Wrap
                    selectByMouse: true
                    textFormat: TextEdit.PlainText
                    // Plenty of workshop items ship with no description at all, so
                    // say so rather than showing an empty box that looks broken.
                    readonly property bool hasDesc: detail.displayDesc.trim().length > 0
                    color: hasDesc ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                    text: hasDesc ? detail.displayDesc
                         : (detail.busy ? "" : "The author did not write a description.")
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true

            // Mirror any in-flight download/removal for this item, so Get and
            // Unsubscribe here give the same instant feedback the grid does.
            readonly property var dl: {
                workshopPage.libraryRevision;
                return workshopPage.dlGet(detail.itemId);
            }
            readonly property bool acting: dl !== null
            readonly property string actLabel: {
                if(!dl) return "";
                if(dl.phase === "sub") return "Subscribing…";
                if(dl.phase === "rm")  return "Removing…";
                if(dl.target > 0)
                    return "Downloading… " + Math.round(Math.min(1, dl.onDisk / dl.target) * 100) + "%";
                return "Downloading…";
            }

            Button {
                icon.name: "steam"
                enabled: !parent.acting
                text: parent.acting ? parent.actLabel
                    : (detail.installed ? "View in Steam" : "Get on Steam")
                onClicked: {
                    if(detail.installed) workshopPage._openInSteam(detail.itemId);
                    else workshopPage.subscribe(detail.itemId);
                }
            }
            Button {
                visible: detail.installed && !parent.acting
                icon.name: "list-remove"
                text: "Unsubscribe"
                onClicked: workshopPage.unsubscribe(detail.itemId)
            }
            Button {
                icon.name: "internet-web-browser"
                text: "Open in browser"
                onClicked: Qt.openUrlExternally(
                    "https://steamcommunity.com/sharedfiles/filedetails/?id=" + detail.itemId)
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "Close"
                onClicked: detail.close()
            }
        }
    }
}
