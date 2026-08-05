import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Controls.Material 2.5 as QSMat
import QtQuick.Layouts 1.5

import ".."
import "../components"
import "../js/utils.mjs" as Utils

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami 2.6 as Kirigami

Flickable {
    id: settingTab
    property alias cfg_Fps: sliderFps.value
    property alias cfg_Volume: sliderVol.value
    property alias cfg_MpvStats: ckbox_mpvStats.checked
    property alias cfg_Speed: spin_speed.dValue
    property alias cfg_MuteAudio: ckbox_muteAudio.checked
    property alias cfg_MouseInput: ckbox_mouseInput.checked
    property alias cfg_ResumeTime: resumeSpin.value
    property alias cfg_SwitchTimer: randomSpin.value
    property alias cfg_RandomizeWallpaper: ckbox_randomizeWallpaper.checked
    property alias cfg_NoRandomWhilePaused: ckbox_noRandomWhilePaused.checked
    property alias cfg_PauseFilterByScreen: ckbox_pauseFilterByScreen.checked

    property alias cfg_PauseOnBatPower: chkbox_pauseOnBatPower.checked
    property alias cfg_PauseBatPercent: spin_pauseBatPercent.value


    // ------------------------------------------------- what this wallpaper is
    // Most of these settings only mean something for one kind of wallpaper: a
    // scene has no video backend, a video has no shader cache, and well over
    // half the library has no sound at all, so a volume slider next to it is
    // just noise. Ask the helper what the selected wallpaper actually is and
    // show the rest accordingly.
    //
    // Every test below defaults to showing the control. Until the answer
    // arrives - or if it cannot be worked out at all - everything is visible,
    // because hiding a setting someone needs is far worse than showing one they
    // do not.
    property var caps: null

    readonly property bool capsKnown: caps !== null && caps.known === true
    readonly property string wpType: capsKnown ? String(caps.type || "") : ""

    readonly property bool hasSound: !capsKnown || caps.sound !== false
    readonly property bool isVideo:  !capsKnown || wpType === "video"
    readonly property bool isScene:  !capsKnown || wpType === "scene"
    readonly property bool isWeb:    !capsKnown || wpType === "web"

    function refreshCaps() {
        if(!pyext || !pyext.ok) return;
        const packed = String(cfg_WallpaperSource || "");
        if(!packed) { settingTab.caps = null; return; }
        // cfg_WallpaperSource is "<path>/<file>+<type>"; the helper wants a path.
        const src = Common.unpackWallpaperSource(packed).path;
        if(!src) { settingTab.caps = null; return; }

        pyext.wallpaper_caps(src).then((res) => {
            // Ignore an answer about a wallpaper that is no longer the one set.
            if(String(cfg_WallpaperSource || "") !== packed) return;
            settingTab.caps = res || null;
        }).catch((reason) => {
            console.error("wallpaper_caps failed", reason);
            settingTab.caps = null;
        });
    }

    Component.onCompleted: refreshCaps()

    Connections {
        target: root
        function onCfg_WallpaperSourceChanged() { settingTab.refreshCaps(); }
    }

    // The helper connects a moment after the dialog is built, so the first
    // attempt can land before it is up.
    Connections {
        target: pyext
        function onOkChanged() { settingTab.refreshCaps(); }
    }

    Layout.fillWidth: true
    ScrollBar.vertical: ScrollBar { id: scrollbar }

    contentWidth: width - (scrollbar.visible ? scrollbar.width : 0)
    contentHeight: contentItem.childrenRect.height
    clip: true
    boundsBehavior: Flickable.OvershootBounds

    // Must live here, not inside the Taskbar OptionGroup: OptionGroup's default
    // property is a children list, which only accepts Items. CmdRunner is a
    // DataSource, so putting it there is a hard "cannot assign to default
    // property of incompatible type" error - which takes down this whole page,
    // and with it the entire wallpaper config dialog, leaving it blank.
    CmdRunner { id: taskbarRunner }

    OptionGroup {
        header.visible: false
        anchors.left: parent.left
        anchors.right: parent.right

        // Say why the page is shorter than it used to be, rather than leaving
        // someone hunting for a setting that has been quietly removed.
        Label {
            Layout.fillWidth: true
            visible: settingTab.capsKnown
            wrapMode: Text.WordWrap
            color: Kirigami.Theme.disabledTextColor
            text: {
                const t = settingTab.wpType;
                const kind = (t === "video" || t === "scene" || t === "web") ? t : "";
                let s = kind ? "This is a " + kind + " wallpaper. " : "";
                s += settingTab.hasSound
                    ? "Settings it does not use are hidden."
                    : "It has no sound, so the audio settings - and anything else "
                      + "it does not use - are hidden.";
                return s;
            }
        }

        OptionGroup {
            Layout.fillWidth: true
            header.text: 'Common Option'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Theme.activeBackgroundColor

            OptionItem {
                text: 'Pause'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/pause.svg'
                actor:  ComboBox {
                    id: pauseMode
                    model: [
                        {
                            text: "Focus or Maximized Window",
                            value: Common.PauseMode.FocusOrMax
                        },
                        {
                            text: "Focus Window",
                            value: Common.PauseMode.Focus
                        },
                        {
                            text: "Maximized Window",
                            value: Common.PauseMode.Max
                        },
                        {
                            text: "FullScreen",
                            value: Common.PauseMode.FullScreen
                        },
                        {
                            text: "Any Window",
                            value: Common.PauseMode.Any
                        },
                        {
                            text: "Never",
                            value: Common.PauseMode.Never
                        }
                    ]
                    textRole: "text"
                    onActivated: cfg_PauseMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_PauseMode)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Automatically pauses playback if any/focus/maximized window detected"
                        wrapMode: Text.Wrap
                    }
               }
            }
            OptionItem {
                text: 'Only check window on current screen'
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_pauseFilterByScreen
                }
            }
            OptionItem {
                text: 'Pause if PC is on battery power'
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: chkbox_pauseOnBatPower
                }
            }
            OptionItem {
                text: 'Pause if battery level is below'
                text_color: Kirigami.Theme.textColor
                actor: SpinBox {
                        id: spin_pauseBatPercent
                        from: 0
                        to: 100
                        stepSize: 1
                }
            }
            OptionItem {
                text: 'Display'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/window.svg'
                actor: ComboBox {
                    id: displayMode
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
                    ]
                    textRole: "text"
                    onActivated: cfg_DisplayMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_DisplayMode)
                }
            }

            OptionItem {
                text: 'Resume Time'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/timer.svg'
                actor: RowLayout {
                    spacing: 0
                    RowLayout {
                        SpinBox {
                            id: resumeSpin
                            from: 1
                            to: 60*1000
                            stepSize: 50
                        }
                        Label { text: " ms" }
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Time to wait to resume playback from pause"
                    }
                }
            }
            OptionItem {
                text: 'Randomize Timer'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/time.svg'
                actor: Switch {
                    id: ckbox_randomizeWallpaper
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Randomize wallpapers filtered in the 'Wallpapers' page"
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label { 
                            id:heightpicker
                            text: "Randomize every " 
                        }
                        SpinBox {
                            id: randomSpin
                            width: font.pixelSize * 4
                            from: 1
                            to: 60*24*30
                            stepSize: 1
                        }
                        Label { text: " min" }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label { 
                            id: randomWhilePausedSetter
                            text: "Skip randomizing while wallpaper is paused  " 
                        }
                        Switch {
                            id: ckbox_noRandomWhilePaused
                        }
                    }
                }
            }

            // Only the video and scene backends have a playback rate; the web
            // one ignores it entirely.
            OptionItem {
                visible: settingTab.isVideo || settingTab.isScene
                text: "Playback Speed"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/fast-forward.svg'
                actor: RowLayout {
                    DoubleSpinBox {
                        id: spin_speed
                        dFrom: 0.1
                        dTo: 16.0
                        dStepSize: 0.1
                    }
                }
            }


            OptionItem {
                visible: settingTab.hasSound
                text: "Mute Audio"
                text_color: Kirigami.Theme.textColor
                icon: ckbox_muteAudio.checked
                    ? '../../images/volume-off.svg'
                    : '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_muteAudio
                }
            }
            OptionItem {
                text: "Volume"
                text_color: Kirigami.Theme.textColor
                visible: settingTab.hasSound && !cfg_MuteAudio
                actor: RowLayout {
                    Layout.preferredWidth: displayMode.width
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderVol.value.toString()
                    }
                    Slider {
                        id: sliderVol
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 5.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
            }
 
            // Hooking the mouse goes through the native scene library, so this
            // does nothing for a video or a web page.
            OptionItem {
                visible: libcheck.wallpaper && settingTab.isScene
                text_color: Kirigami.Theme.textColor
                text: "Mouse Input"
                icon: '../../images/mouse.svg'
                actor: Switch {
                    id: ckbox_mouseInput
                }
            }
       }

        OptionGroup {
            Layout.fillWidth: true
            visible: settingTab.isVideo

            header.text: 'Video Option'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Theme.activeBackgroundColor

            OptionItem {
                text: 'Video Backend'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/plugin.svg'
                actor: ComboBox {
                    model: [
                        {
                            text: "QtMultimedia",
                            value: Common.VideoBackend.QtMultimedia,
                            enabled: true
                        },
                        {
                            text: "Mpv",
                            value: Common.VideoBackend.Mpv,
                            enabled: libcheck.wallpaper
                        }
                    ].filter(el => el.enabled)
                    textRole: "text"
                    onActivated: cfg_VideoBackend = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_VideoBackend)
                }
            }
            
            OptionItem {
                text: 'Show Mpv Stats'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                visible: cfg_VideoBackend == Common.VideoBackend.Mpv
                actor: Switch {
                    id: ckbox_mpvStats
                }
            }
        }
        OptionGroup {
            Layout.fillWidth: true

            // Fps drives the scene renderer and the web view both; the shader
            // cache belongs to the scene renderer alone.
            header.text: (settingTab.isWeb && !settingTab.isScene)
                ? 'Web Option' : 'Scene Option'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Theme.activeBackgroundColor
            visible: (settingTab.isScene && libcheck.wallpaper) || settingTab.isWeb

            OptionItem {
                visible: settingTab.isScene || settingTab.isWeb
                text: 'Fps'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/tuning.svg'
                actor: RowLayout {
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderFps.value.toString()
                    }
                    Slider {
                        id: sliderFps
                        Layout.fillWidth: true
                        from: 5
                        to: 60
                        stepSize: 1.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Low: 10, Medium: 15, High: 25, Ultra High: 30"
                    }
                }

            }
            OptionItem {
                visible: settingTab.isScene && libcheck.wallpaper
                text: 'Shader cache'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                actor: Kirigami.ActionToolBar {
                    Layout.fillWidth: true
                    alignment: Qt.AlignRight
                    flat: false
                    actions: [
                        Kirigami.Action {
                            text: 'Show'
                            tooltip: 'Show in file manager'
                            onTriggered: {
                                if(plugin_info.cache_path)
                                    Qt.openUrlExternally(plugin_info.cache_path);
                            }
                        }
                    ]
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        property string cache_path: Common.urlNative(plugin_info.cache_path)

                        color: Kirigami.Theme.disabledTextColor
                        text: plugin_info.cache_path
                        ? `${cache_path} - ${cache_size}`
                        : `Not available`

                        property string cache_size: {
                            if(pyext) {
                                pyext.get_dir_size(this.cache_path).then(res => {
                                    this.cache_size = Utils.prettyBytes(res);
                                }).catch(reason => console.error(reason));
                            }
                            return "? MB";
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------ taskbar
        // Wallpaper Engine tints the Windows taskbar with the wallpaper's
        // scheme colour. Plasma has no panel-colour setting of any kind, so the
        // work is done by wallpaper-engine-taskbar-color: it derives a Plasma
        // Style from the one in use, overriding only the panel background, and
        // symlinks every other asset so the desktop keeps its current look.
        OptionGroup {
            id: taskbarGroup
            Layout.fillWidth: true
            header.text: 'Taskbar'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Theme.activeBackgroundColor

            // Wallpaper Engine's own colour-picker presets, taken from the
            // spectrum config in its ui/dist/scripts/scripts.js - five rows of
            // three, in that order.
            readonly property var presetRows: [
                [ { name: "White",      hex: "#ffffff" },
                  { name: "Silver",     hex: "#c0c0c0" },
                  { name: "Black",      hex: "#000000" } ],
                [ { name: "Red",        hex: "#ff0000" },
                  { name: "Orange",     hex: "#ffa500" },
                  { name: "Yellow",     hex: "#ffff00" } ],
                [ { name: "Lime",       hex: "#00ff00" },
                  { name: "Green",      hex: "#008000" },
                  { name: "Dark green", hex: "#254117" } ],
                [ { name: "Light blue", hex: "#add8e6" },
                  { name: "Blue",       hex: "#0000ff" },
                  { name: "Dark blue",  hex: "#00008b" } ],
                [ { name: "Cyan",       hex: "#00ffff" },
                  { name: "Purple",     hex: "#800080" },
                  { name: "Magenta",    hex: "#ff00ff" } ]
            ]

            property string currentColor: ""
            property bool busy: false

            readonly property string tool: "\"$HOME/.local/bin/wallpaper-engine-taskbar-color\""

            function applyColor(hex) {
                if(!/^#[0-9a-fA-F]{6}$/.test(hex)) return;
                taskbarGroup.busy = true;
                taskbarRunner.exec(taskbarGroup.tool + " '" + hex + "'", () => {
                    taskbarGroup.currentColor = hex;
                    taskbarGroup.busy = false;
                });
            }
            function clearColor() {
                taskbarGroup.busy = true;
                taskbarRunner.exec(taskbarGroup.tool + " --off", () => {
                    taskbarGroup.currentColor = "";
                    taskbarGroup.busy = false;
                });
            }
            // Reflect whatever is already applied when the page opens.
            Component.onCompleted: {
                taskbarRunner.exec(taskbarGroup.tool + " --status", (code, out) => {
                    const m = String(out).match(/colour\s*:\s*(#[0-9a-fA-F]{6})/);
                    taskbarGroup.currentColor = m ? m[1] : "";
                });
            }

            OptionItem {
                text: 'Panel color'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/filter.svg'

                actor: RowLayout {
                    spacing: 8
                    Rectangle {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        radius: 3
                        color: taskbarGroup.currentColor ? taskbarGroup.currentColor : "transparent"
                        border.width: 1
                        border.color: Kirigami.Theme.disabledTextColor
                    }
                    Label {
                        color: Kirigami.Theme.textColor
                        text: taskbarGroup.busy
                            ? "applying…"
                            : (taskbarGroup.currentColor ? taskbarGroup.currentColor : "Default")
                    }
                    Button {
                        text: "Off"
                        enabled: !taskbarGroup.busy && taskbarGroup.currentColor !== ""
                        onClicked: taskbarGroup.clearColor()
                    }
                }

                contentBottom: ColumnLayout {
                    spacing: 6

                    Repeater {
                        model: taskbarGroup.presetRows
                        delegate: RowLayout {
                            id: presetRow
                            required property var modelData
                            spacing: 6
                            Repeater {
                                model: presetRow.modelData
                                delegate: Rectangle {
                                    id: swatch
                                    required property var modelData
                                    width: 30
                                    height: 22
                                    radius: 3
                                    color: swatch.modelData.hex
                                    border.width: taskbarGroup.currentColor === swatch.modelData.hex ? 3 : 1
                                    border.color: taskbarGroup.currentColor === swatch.modelData.hex
                                        ? Theme.highlightColor : Kirigami.Theme.disabledTextColor

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: taskbarGroup.applyColor(swatch.modelData.hex)
                                        ToolTip.visible: containsMouse
                                        ToolTip.text: swatch.modelData.name + "  " + swatch.modelData.hex
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }

                    RowLayout {
                        spacing: 6
                        Label { text: "Custom"; color: Kirigami.Theme.textColor }
                        TextField {
                            id: customHex
                            Layout.preferredWidth: 110
                            placeholderText: "#rrggbb"
                            onAccepted: taskbarGroup.applyColor(text)
                        }
                        Button {
                            text: "Apply"
                            enabled: !taskbarGroup.busy && /^#[0-9a-fA-F]{6}$/.test(customHex.text)
                            onClicked: taskbarGroup.applyColor(customHex.text)
                        }
                        Item { Layout.fillWidth: true }
                    }

                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        color: Kirigami.Theme.disabledTextColor
                        text: "Switches to a generated Plasma Style that copies your current one "
                            + "and changes only the panel colour. \"Off\" puts the original style back."
                    }
                }
            }
        }
    }


}

