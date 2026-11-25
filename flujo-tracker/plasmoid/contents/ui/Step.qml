import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Un paso numerado: texto, opcionalmente el texto exacto a copiar y su botón.
RowLayout {
    id: step
    property int number: 1
    property string text: ""
    property string code: ""
    property string buttonText: ""
    signal copy()

    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing * 1.5

    Rectangle {
        Layout.alignment: Qt.AlignTop
        implicitWidth: 22; implicitHeight: 22; radius: 11
        color: Kirigami.Theme.highlightColor
        Text { anchors.centerIn: parent; text: step.number; font.bold: true; color: Kirigami.Theme.highlightedTextColor }
    }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 3
        PlasmaComponents.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: step.text }
        Rectangle {
            visible: step.code !== ""
            Layout.fillWidth: true
            Layout.preferredHeight: codeLabel.contentHeight + 12
            radius: 4
            color: Kirigami.Theme.alternateBackgroundColor
            PlasmaComponents.Label {
                id: codeLabel
                x: 6; y: 6
                width: parent.width - 12
                text: step.code; wrapMode: Text.Wrap
                font.family: "monospace"; font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }
        }
        PlasmaComponents.Button {
            visible: step.buttonText !== ""
            icon.name: "edit-copy"
            text: step.buttonText
            onClicked: step.copy()
        }
    }
}
