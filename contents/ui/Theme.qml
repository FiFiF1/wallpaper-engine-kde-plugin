pragma Singleton
import QtQuick 2.0
import org.kde.kirigami 2.4 as Kirigami

// Colour scheme for the config dialog.
//
// This used to sample Kirigami.Theme once, imperatively, from a property
// initialiser. That is unreliable: a singleton lives outside the item tree, so
// at the moment it is constructed Kirigami.Theme has no colour set to inherit
// and hands back palette defaults. On a dark colour scheme that meant nearly
// black text drawn on a nearly black panel - every option label in the wallpaper
// settings ("Display", "Mute Audio", "Volume", the "Option" group header) was
// rendered but invisible.
//
// Declaring an explicit colour set and using bindings fixes it, and has the
// bonus of tracking colour-scheme changes instead of freezing whatever was
// current when the dialog first opened.
Item {
    id: root_item

    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    readonly property color textColor:                Kirigami.Theme.textColor
    readonly property color highlightColor:           Kirigami.Theme.highlightColor
    readonly property color highlightedTextColor:     Kirigami.Theme.highlightedTextColor
    readonly property color backgroundColor:          Kirigami.Theme.backgroundColor
    readonly property color activeBackgroundColor:    Kirigami.Theme.activeBackgroundColor
    readonly property color alternateBackgroundColor: Kirigami.Theme.alternateBackgroundColor
    readonly property color linkColor:                Kirigami.Theme.linkColor
    readonly property color visitedLinkColor:         Kirigami.Theme.visitedLinkColor
    readonly property color positiveTextColor:        Kirigami.Theme.positiveTextColor
    readonly property color positiveBackgroundColor:  Kirigami.Theme.positiveBackgroundColor
    readonly property color neutralTextColor:         Kirigami.Theme.neutralTextColor
    readonly property color negativeTextColor:        Kirigami.Theme.negativeTextColor
    readonly property color disabledTextColor:        Kirigami.Theme.disabledTextColor

    readonly property alias view: theme_view

    // The View colour set - used for the wallpaper grid and the details panel,
    // which sit on a view background rather than a window background.
    Item {
        id: theme_view

        Kirigami.Theme.colorSet: Kirigami.Theme.View
        Kirigami.Theme.inherit: false

        readonly property color textColor:                Kirigami.Theme.textColor
        readonly property color highlightColor:           Kirigami.Theme.highlightColor
        readonly property color highlightedTextColor:     Kirigami.Theme.highlightedTextColor
        readonly property color backgroundColor:          Kirigami.Theme.backgroundColor
        readonly property color activeBackgroundColor:    Kirigami.Theme.activeBackgroundColor
        readonly property color alternateBackgroundColor: Kirigami.Theme.alternateBackgroundColor
        readonly property color linkColor:                Kirigami.Theme.linkColor
        readonly property color visitedLinkColor:         Kirigami.Theme.visitedLinkColor
        readonly property color positiveTextColor:        Kirigami.Theme.positiveTextColor
        readonly property color positiveBackgroundColor:  Kirigami.Theme.positiveBackgroundColor
        readonly property color neutralTextColor:         Kirigami.Theme.neutralTextColor
        readonly property color negativeTextColor:        Kirigami.Theme.negativeTextColor
        readonly property color disabledTextColor:        Kirigami.Theme.disabledTextColor
    }
}
