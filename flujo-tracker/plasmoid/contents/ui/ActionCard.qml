import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Botón grande de la pantalla de inicio: ícono, título y una línea que explica qué hace.
PlasmaComponents.ItemDelegate {
    id: card
    property string title: ""
    property string subtitle: ""
    property string iconName: "go-next"
    Layout.fillWidth: true
    topPadding: 10; bottomPadding: 10

    background: Rectangle {
        radius: 6
        color: card.hovered ? Kirigami.Theme.highlightColor : Kirigami.Theme.alternateBackgroundColor
        opacity: card.hovered ? 0.25 : 1
        border.width: 1; border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
    }
    contentItem: RowLayout {
        spacing: Kirigami.Units.largeSpacing
        Kirigami.Icon { source: card.iconName; Layout.preferredWidth: Kirigami.Units.iconSizes.medium; Layout.preferredHeight: Kirigami.Units.iconSizes.medium }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 1
            PlasmaComponents.Label { text: card.title; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
            PlasmaComponents.Label { text: card.subtitle; opacity: 0.7; wrapMode: Text.Wrap; Layout.fillWidth: true; font: Kirigami.Theme.smallFont }
        }
    }
}
