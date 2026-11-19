import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Fila de un PR: círculo de estado, título, subtítulo y acciones al pasar el mouse.
PlasmaComponents.ItemDelegate {
    id: row

    property var pr
    property var colors
    property var glyphs
    property string subtitle: ""
    property bool showReReview: false
    property bool showReview: false
    property bool alwaysShowActions: false
    property string extraIcon: ""
    property string extraTip: ""

    signal copyLink(string url)
    signal openChecks(string url)
    signal reReview(string account, string url)
    signal extra(string url)
    signal reviewCode(string account, string url)
    signal reviewTerm(string account, string url)

    onClicked: Qt.openUrlExternally(pr.url)
    HoverHandler { id: hh }

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing
        Rectangle {
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            radius: width / 2
            color: row.colors[row.pr.status] || "#8b949e"
            Text { anchors.centerIn: parent; text: row.glyphs[row.pr.status] || "?"
                color: "white"; font.bold: true; font.pixelSize: parent.height * 0.7; font.family: "DejaVu Sans" }
        }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 0
            PlasmaComponents.Label {
                text: "#" + row.pr.number + "  " + row.pr.title
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label {
                    text: row.pr.label
                    color: row.colors[row.pr.status] || "#8b949e"; font: Kirigami.Theme.smallFont
                }
                PlasmaComponents.Label {
                    text: row.subtitle; opacity: 0.75; font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
                PlasmaComponents.Label {
                    visible: row.pr.stale === true
                    text: "sin movimiento " + row.pr.idleDays + " d"
                    color: "#d98e04"; font: Kirigami.Theme.smallFont
                }
            }
        }
        RowLayout {
            spacing: 0
            visible: hh.hovered || row.alwaysShowActions
            PlasmaComponents.ToolButton {
                icon.name: "edit-copy"; onClicked: row.copyLink(row.pr.url)
                PlasmaComponents.ToolTip { text: "Copiar link del PR" }
            }
            PlasmaComponents.ToolButton {
                icon.name: "run-build"; onClicked: row.openChecks(row.pr.url)
                PlasmaComponents.ToolTip { text: "Abrir checks (CI)" }
            }
            PlasmaComponents.ToolButton {
                visible: row.showReview
                icon.name: "document-edit"; onClicked: row.reviewCode(row.pr.account, row.pr.url)
                PlasmaComponents.ToolTip { text: "Revisar el código en VS Code (archivos en orden de lectura)" }
            }
            PlasmaComponents.ToolButton {
                visible: row.showReview
                icon.name: "utilities-terminal"; onClicked: row.reviewTerm(row.pr.account, row.pr.url)
                PlasmaComponents.ToolTip { text: "Ver el diff en la terminal (delta, en orden de lectura)" }
            }
            PlasmaComponents.ToolButton {
                visible: row.showReReview
                icon.name: "mail-send"; onClicked: row.reReview(row.pr.account, row.pr.url)
                PlasmaComponents.ToolTip { text: "Pedir re-review a quienes ya revisaron" }
            }
            PlasmaComponents.ToolButton {
                visible: row.extraIcon !== ""
                icon.name: row.extraIcon; onClicked: row.extra(row.pr.url)
                PlasmaComponents.ToolTip { text: row.extraTip }
            }
        }
    }
}
