// Icono compacto común de los widgets del panel: icono propio (mismo trazo en todos), una insignia con el
// número principal abajo a la derecha y un punto de aviso arriba a la derecha. Copia sincronizada con tools/sync-shared.sh.
import QtQuick
import org.kde.kirigami as Kirigami

MouseArea {
    id: ctl
    property url icon
    property int count: -1          // número principal; -1 o 0 no muestra insignia
    property bool alert: false      // el número va en rojo (requiere atención); si no, en el color de acento
    property string dot: ""         // aviso secundario arriba a la derecha: "warn" (naranja) o "ok" (verde)
    hoverEnabled: true

    readonly property real side: Math.min(width, height)

    Item {
        id: box
        width: ctl.side; height: ctl.side
        anchors.centerIn: parent

        Kirigami.Icon {
            anchors.fill: parent
            source: ctl.icon
            isMask: true
            color: Kirigami.Theme.textColor
            opacity: ctl.containsMouse ? 1 : 0.88
        }
        Rectangle {
            visible: ctl.count > 0
            anchors { right: parent.right; bottom: parent.bottom }
            height: Math.max(11, box.height * 0.42)
            width: Math.max(height, label.implicitWidth + height * 0.5)
            radius: height / 2
            color: ctl.alert ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor
            border { width: 1; color: Kirigami.Theme.backgroundColor }
            Text {
                id: label
                anchors.centerIn: parent
                text: ctl.count > 99 ? "99+" : ctl.count
                color: "white"
                font { pixelSize: Math.max(8, parent.height * 0.68); bold: true; family: "DejaVu Sans" }
            }
        }
        Rectangle {
            visible: ctl.dot !== ""
            anchors { right: parent.right; top: parent.top }
            width: Math.max(7, box.height * 0.3); height: width; radius: width / 2
            color: ctl.dot === "ok" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
            border { width: 1; color: Kirigami.Theme.backgroundColor }
        }
    }
}
