import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var tickets: []
    property string errorMsg: ""
    property bool loading: false
    property bool showBacklog: false
    property string toast: ""
    property bool copied: false
    readonly property string cmd: "python3 $HOME/.local/bin/my-tickets"

    readonly property var active: tickets.filter(t => t.cat !== "new")
    readonly property var visibleTickets: showBacklog ? tickets : active
    readonly property int staleCount: active.filter(t => t.stale).length
    readonly property var statusCount: {
        const m = {}
        for (const t of visibleTickets) m[t.sec] = (m[t.sec] || 0) + 1
        return m
    }

    readonly property var typeColor: ({ "Bug": "#e5484d", "Story": "#2da44e", "Epic": "#8957e5", "Pase a producción": "#2f81f7" })
    readonly property var typeGlyph: ({ "Bug": "!", "Story": "+", "Epic": "E", "Pase a producción": "↗" })
    function prioColor(p) {
        return (p === "Highest" || p === "High") ? "#e5484d" : p === "Medium" ? "#d98e04" : "#8b949e"
    }

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }

    // ---- notificaciones: tickets recién asignados ----
    property var prevKeys: ({})
    property bool initialized: false
    P5Support.DataSource {
        id: notifier
        engine: "executable"
        onNewData: (source, data) => disconnectSource(source)
    }
    function notify(title, body) {
        notifier.connectSource("notify-send -a 'Mis tickets' -i view-task -u normal " + q(title) + " " + q(body) + " # " + Date.now() + Math.random())
    }
    function notifyNew(list) {
        const next = {}
        for (const t of list) {
            next[t.key] = true
            if (initialized && !prevKeys[t.key]) notify("Te asignaron " + t.key, t.summary)
        }
        prevKeys = next
        initialized = true
    }

    // ---- datos ----
    function refresh() { loading = true; src.connectSource(cmd) }
    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            root.loading = false
            try {
                const r = JSON.parse(data["stdout"])
                root.errorMsg = r.error ? r.error : ""
                if (!r.error) { root.tickets = r.tickets; root.notifyNew(r.tickets) }
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }
    Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    // ---- copiar ----
    TextEdit { id: clip; visible: false }
    function copyText(t) { clip.text = t; clip.selectAll(); clip.copy() }
    Timer { id: toastTimer; interval: 2200; onTriggered: root.toast = "" }
    function showToast(t) { toast = t; toastTimer.restart() }
    Timer { id: copiedTimer; interval: 2000; onTriggered: root.copied = false }

    function buildSummary() {
        const meses = ["enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre","octubre","noviembre","diciembre"]
        const d = new Date()
        let out = "Mis tickets (" + d.getDate() + " de " + meses[d.getMonth()] + "): " + active.length + "\n"
        let last = ""
        for (const t of active) {
            if (t.sec !== last) {
                out += "\n" + t.sec + " (" + active.filter(x => x.sec === t.sec).length + ")\n"
                last = t.sec
            }
            out += "- " + t.key + " " + t.summary + "\n  " + t.url + "\n"
        }
        return out.trim()
    }

    Plasmoid.icon: "view-task"
    toolTipMainText: "Mis tickets"
    toolTipSubText: errorMsg !== "" ? "⚠ " + errorMsg : active.length + " activos, " + staleCount + " sin movimiento"

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            width: parent.width * 0.82; height: width
            anchors { left: parent.left; top: parent.top }
            source: "view-task"
            isMask: true
            color: Kirigami.Theme.textColor
        }
        Rectangle {
            visible: root.errorMsg !== ""
            anchors { right: parent.right; top: parent.top }
            width: Math.max(12, parent.height * 0.4); height: width; radius: width / 2
            color: "#d98e04"
            Text { anchors.centerIn: parent; text: "!"; color: "white"; font.bold: true
                font.pixelSize: parent.height * 0.8; font.family: "DejaVu Sans" }
        }
        Rectangle {
            visible: root.active.length > 0
            anchors { right: parent.right; bottom: parent.bottom }
            height: Math.max(14, parent.height * 0.5)
            width: Math.max(height, badge.implicitWidth + 4)
            radius: height / 2
            color: root.staleCount > 0 ? "#e5484d" : "#2f81f7"
            Text { id: badge; anchors.centerIn: parent; text: root.active.length
                color: "white"; font.pixelSize: Math.max(10, parent.height * 0.72); font.bold: true; font.family: "DejaVu Sans" }
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 28
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Heading { level: 3; text: "Mis tickets (" + root.active.length + ")"; Layout.fillWidth: true }
            PlasmaComponents.Button {
                icon.name: root.copied ? "dialog-ok" : "edit-copy"
                text: root.copied ? "¡Copiado!" : "Copiar resumen"
                enabled: root.active.length > 0
                onClicked: { root.copyText(root.buildSummary()); root.copied = true; copiedTimer.restart() }
                PlasmaComponents.ToolTip { text: "Copia mis tickets activos por estado, para el daily" }
            }
            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"; enabled: !root.loading
                onClicked: root.refresh()
                PlasmaComponents.ToolTip { text: "Actualizar" }
            }
        }

        PlasmaComponents.Label {
            visible: root.errorMsg !== ""
            Layout.fillWidth: true; wrapMode: Text.Wrap
            color: Kirigami.Theme.negativeTextColor; text: root.errorMsg
        }

        PlasmaComponents.CheckBox {
            text: "Incluir backlog y por hacer (" + (root.tickets.length - root.active.length) + ")"
            checked: root.showBacklog
            onToggled: root.showBacklog = checked
        }

        PlasmaComponents.ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                model: root.visibleTickets
                spacing: Kirigami.Units.smallSpacing
                section.property: "sec"
                // "Tablero › Columna": la columna destacada y el tablero como contexto
                section.delegate: RowLayout {
                    required property string section
                    width: ListView.view ? ListView.view.width : 0
                    Kirigami.Heading {
                        level: 5; topPadding: Kirigami.Units.gridUnit * 0.6
                        text: section.split(" › ")[1] + " (" + (root.statusCount[section] || 0) + ")"
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        Layout.topMargin: Kirigami.Units.gridUnit * 0.6
                        text: section.split(" › ")[0]; opacity: 0.6; font: Kirigami.Theme.smallFont
                    }
                }
                delegate: PlasmaComponents.ItemDelegate {
                    id: row
                    width: ListView.view.width
                    onClicked: Qt.openUrlExternally(modelData.url)
                    HoverHandler { id: hh }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 2
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            radius: width / 2
                            color: root.typeColor[modelData.type] || "#8b949e"
                            Text { anchors.centerIn: parent; text: root.typeGlyph[modelData.type] || "·"
                                color: "white"; font.bold: true; font.pixelSize: parent.height * 0.7; font.family: "DejaVu Sans" }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            // Línea de contexto: clave, antigüedad y solo lo que merece atención
                            RowLayout {
                                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents.Label {
                                    text: modelData.key; font.bold: true; font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    opacity: 0.85
                                }
                                PlasmaComponents.Label {
                                    text: (modelData.idleDays === 0 ? "hoy" : "hace " + modelData.idleDays + " d")
                                    opacity: 0.6; font: Kirigami.Theme.smallFont
                                }
                                Rectangle {
                                    visible: modelData.priority === "Highest" || modelData.priority === "High"
                                    radius: 3; color: root.prioColor(modelData.priority)
                                    implicitWidth: prioText.implicitWidth + 8; implicitHeight: prioText.implicitHeight + 2
                                    Text { id: prioText; anchors.centerIn: parent; text: modelData.priority; color: "white"
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                                }
                                Rectangle {
                                    visible: modelData.stale
                                    radius: 3; color: "#d98e04"
                                    implicitWidth: staleText.implicitWidth + 8; implicitHeight: staleText.implicitHeight + 2
                                    Text { id: staleText; anchors.centerIn: parent; text: "sin movimiento"; color: "white"
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            PlasmaComponents.Label {
                                text: modelData.summary
                                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        RowLayout {
                            spacing: 0
                            visible: hh.hovered
                            PlasmaComponents.ToolButton {
                                icon.name: "edit-copy"
                                onClicked: { root.copyText(modelData.url); root.showToast("Link copiado") }
                                PlasmaComponents.ToolTip { text: "Copiar link del ticket" }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "tag"
                                onClicked: { root.copyText(modelData.key); root.showToast("Clave copiada") }
                                PlasmaComponents.ToolTip { text: "Copiar clave (" + modelData.key + ")" }
                            }
                        }
                    }
                }
            }
        }
        PlasmaComponents.Label {
            visible: root.visibleTickets.length === 0
            Layout.alignment: Qt.AlignHCenter; text: root.loading ? "Cargando…" : "Sin tickets asignados"
        }
        PlasmaComponents.Label {
            visible: root.toast !== ""
            Layout.alignment: Qt.AlignHCenter; text: root.toast; opacity: 0.85
        }
    }
}
