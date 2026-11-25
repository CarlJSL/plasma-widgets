import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var sessions: []
    property var commands: []
    property bool logExists: true
    property string tab: "sessions"
    property string filter: ""
    property string toast: ""
    readonly property string cli: "python3 $HOME/.local/bin/kitty-historial"

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function dayLabel(ts) {
        const d = new Date(ts * 1000), n = new Date()
        const same = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
        if (same(d, n)) return "Hoy"
        const y = new Date(n.getTime() - 86400000)
        if (same(d, y)) return "Ayer"
        return pad(d.getDate()) + "/" + pad(d.getMonth() + 1) + "/" + d.getFullYear()
    }
    function hour(ts) { const d = new Date(ts * 1000); return pad(d.getHours()) + ":" + pad(d.getMinutes()) }
    function dur(sec) {
        if (sec === null || sec === undefined) return ""
        sec = Math.max(0, Math.round(sec))
        if (sec < 60) return sec + " s"
        if (sec < 3600) return Math.round(sec / 60) + " min"
        return Math.floor(sec / 3600) + " h " + pad(Math.round((sec % 3600) / 60)) + " min"
    }
    function short(p) {
        if (!p) return "(sin carpeta)"
        const m = /^\/home\/[^\/]+(\/.*)?$/.exec(p)
        return m ? "~" + (m[1] || "") : p
    }

    // Filtrado y agrupado por día
    function match(text) {
        const words = filter.toLowerCase().split(/\s+/).filter(w => w !== "")
        const t = text.toLowerCase()
        return words.every(w => t.indexOf(w) >= 0)
    }
    readonly property var rows: {
        const src = tab === "sessions" ? sessions : commands
        const out = []
        let last = ""
        for (const x of src) {
            const hay = tab === "sessions" ? (x.cwd + " " + x.branch + " " + x.last.join(" ") + " " + x.title) : (x.cmd + " " + x.cwd)
            if (!match(hay)) continue
            const day = dayLabel(tab === "sessions" ? x.start : x.t)
            if (day !== last) { out.push({ header: day }); last = day }
            out.push({ header: "", item: x })
        }
        return out
    }

    function refresh() { src.connectSource(cli + " # " + Date.now()) }
    function showToast(t) { toast = t; toastTimer.restart() }
    Timer { id: toastTimer; interval: 2500; onTriggered: root.toast = "" }
    TextEdit { id: clipboard; visible: false }
    function copyText(t) { clipboard.text = t; clipboard.selectAll(); clipboard.copy(); showToast("Copiado") }
    function openHere(dir) { runner.connectSource(cli + " open " + q(dir) + " # " + Date.now()); root.expanded = false }

    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try {
                const r = JSON.parse(data["stdout"])
                root.sessions = r.sessions; root.commands = r.commands; root.logExists = r.logExists
            } catch (e) { root.showToast("No se pudo leer el historial") }
        }
    }
    P5Support.DataSource { id: runner; engine: "executable"; onNewData: (s, d) => disconnectSource(s) }

    Component.onCompleted: refresh()
    onExpandedChanged: if (expanded) { filter = ""; refresh() }
    Timer { interval: 30000; running: root.expanded; repeat: true; onTriggered: root.refresh() }

    Plasmoid.icon: Qt.resolvedUrl("icons/terminales.svg")
    toolTipMainText: "Historial de terminales"
    toolTipSubText: sessions.filter(s => s.open).length + " abiertas · " + sessions.length + " registradas"
    preferredRepresentation: compactRepresentation

compactRepresentation: CompactIcon {
        onClicked: root.expanded = !root.expanded
        icon: Qt.resolvedUrl("icons/terminales.svg")
        count: root.sessions.filter(s => s.open).length
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 28
        Layout.minimumHeight: Kirigami.Units.gridUnit * 28
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.TabBar {
                PlasmaComponents.TabButton { text: "Terminales (" + root.sessions.length + ")"; checked: root.tab === "sessions"; onClicked: root.tab = "sessions" }
                PlasmaComponents.TabButton { text: "Comandos (" + root.commands.length + ")"; checked: root.tab === "commands"; onClicked: root.tab = "commands" }
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.ToolButton { icon.name: "view-refresh"; onClicked: root.refresh(); PlasmaComponents.ToolTip { text: "Actualizar" } }
        }
        PlasmaComponents.TextField {
            Layout.fillWidth: true
            placeholderText: root.tab === "sessions" ? "Filtrar por carpeta, rama o comando…" : "Filtrar comandos…"
            text: root.filter
            onTextChanged: root.filter = text
        }
        PlasmaComponents.Label {
            visible: !root.logExists || (root.sessions.length === 0)
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: "Todavía no hay registros. Corre ./install.sh, reinicia kitty y las terminales nuevas empezarán a anotarse."
        }
        PlasmaComponents.ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                id: list
                model: root.rows
                clip: true
                spacing: 2
                delegate: Item {
                    width: list.width
                    height: modelData.header !== "" ? headerLabel.implicitHeight + Kirigami.Units.largeSpacing : row.implicitHeight + Kirigami.Units.smallSpacing * 2
                    PlasmaComponents.Label {
                        id: headerLabel
                        visible: modelData.header !== ""
                        anchors { left: parent.left; bottom: parent.bottom; leftMargin: Kirigami.Units.smallSpacing }
                        text: modelData.header
                        font.bold: true
                        opacity: 0.7
                    }
                    RowLayout {
                        id: row
                        visible: modelData.header === ""
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Kirigami.Units.smallSpacing }
                        Rectangle {
                            visible: root.tab === "sessions"
                            width: 8; height: 8; radius: 4
                            color: (modelData.item && modelData.item.open) ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                font.family: root.tab === "commands" ? "monospace" : ""
                                text: !modelData.item ? "" : root.tab === "sessions" ? root.short(modelData.item.cwd) : modelData.item.cmd
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                opacity: 0.65
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: {
                                    const x = modelData.item
                                    if (!x) return ""
                                    if (root.tab === "commands")
                                        return root.hour(x.t) + " · " + root.short(x.cwd) + (x.dur !== null ? " · " + root.dur(x.dur) : "")
                                    const end = x.open ? (Date.now() / 1000) : x.end
                                    return root.hour(x.start) + " · " + (x.open ? "abierta, " : "") + root.dur(end - x.start)
                                        + (x.branch ? " · " + x.branch : "") + (x.ncmds ? " · " + x.ncmds + " comandos" : "")
                                        + (x.last.length ? " · último: " + x.last[x.last.length - 1] : "")
                                }
                            }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "edit-copy"
                            onClicked: root.copyText(root.tab === "commands" ? modelData.item.cmd : modelData.item.cwd)
                            PlasmaComponents.ToolTip { text: root.tab === "commands" ? "Copiar comando" : "Copiar carpeta" }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "utilities-terminal"
                            onClicked: root.openHere(modelData.item.cwd)
                            PlasmaComponents.ToolTip { text: "Abrir una terminal kitty en esa carpeta" }
                        }
                    }
                }
            }
        }
        PlasmaComponents.Label {
            visible: root.toast !== ""
            text: root.toast
            Layout.alignment: Qt.AlignHCenter
            opacity: 0.8
        }
    }
}
