import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var prs: []
    property int accountCount: 1
    property string errorMsg: ""
    property bool loading: false
    readonly property string cmd: "python3 $HOME/.local/bin/my-prs"

    // Colores fijos (no del tema): el tema los deja apagados/grises. Tonos medios que se leen en claro y oscuro.
    readonly property var colors: ({
        "observado": "#e5484d",
        "conflicto": "#e5484d",
        "ci": "#e5484d",
        "probando": "#2f81f7",
        "aprobado": "#2da44e",
        "review": "#d98e04",
        "draft": "#8b949e"
    })
    readonly property var glyphs: ({
        "observado": "!", "conflicto": "×", "ci": "×", "probando": "↻", "aprobado": "✓", "review": "…", "draft": "–"
    })
    readonly property int attention: prs.filter(p => ["observado", "conflicto", "ci"].includes(p.status)).length

    property var failedAccounts: []
    property var prevStatus: ({})
    property bool initialized: false
    readonly property var notifyOn: ({
        "observado": "Observado", "conflicto": "Tiene conflictos", "ci": "CI fallando", "aprobado": "Aprobado ✓"
    })

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }

    function notifyChanges(list) {
        const next = {}
        // Cuentas que fallaron: conservar su estado previo para no perder ni repetir avisos al volver.
        for (const k in prevStatus) if (failedAccounts.includes(prevStatus[k].account)) next[k] = prevStatus[k]
        for (const p of list) {
            const k = p.owner + "#" + p.number
            next[k] = { status: p.status, account: p.account }
            if (initialized && (!prevStatus[k] || prevStatus[k].status !== p.status) && notifyOn[p.status]) {
                const urgency = p.status === "aprobado" ? "normal" : "critical"
                notifier.connectSource("notify-send -a 'Mis PRs' -i dialog-information -u " + urgency + " "
                    + q(p.repo + " #" + p.number + ": " + notifyOn[p.status]) + " " + q(p.title) + " # " + Date.now() + k)
            }
        }
        prevStatus = next
        initialized = true
    }

    P5Support.DataSource {
        id: notifier
        engine: "executable"
        onNewData: (source, data) => disconnectSource(source)
    }

    property bool copied: false

    // Texto para pasarle a un revisor o al TL: qué necesita su review y qué ya está listo.
    function buildSummary() {
        const sections = [
            ["Necesitan review", p => p.status === "review" && p.label === "Esperando review"],
            ["Esperando re-review (ya subí los cambios de la observación)", p => p.status === "review" && p.label !== "Esperando review"],
            ["Aprobados, listos para merge", p => p.status === "aprobado"],
            ["CI en curso", p => p.status === "probando"],
            ["Por atender de mi lado (observados, conflictos o CI fallando)", p => ["observado", "conflicto", "ci"].includes(p.status)],
            ["Drafts", p => p.status === "draft"]
        ]
        let out = "Resumen de mis PRs abiertos (" + (d => d.getDate() + " de " + ["enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre","octubre","noviembre","diciembre"][d.getMonth()])(new Date()) + "): " + prs.length + "\n"
        for (const [title, test] of sections) {
            const list = prs.filter(test)
            if (list.length === 0) continue
            out += "\n" + title + " (" + list.length + ")\n"
            for (const p of list)
                out += "- " + p.repo + " #" + p.number + " " + p.title + "\n  " + p.url + "\n"
        }
        return out.trim()
    }

    function copySummary() {
        clip.text = buildSummary()
        clip.selectAll()
        clip.copy()
        copied = true
        copiedTimer.restart()
    }

    TextEdit { id: clip; visible: false }
    Timer { id: copiedTimer; interval: 2000; onTriggered: root.copied = false }

    function refresh() { loading = true; src.connectSource(cmd) }

    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            root.loading = false
            try {
                const r = JSON.parse(data["stdout"])
                root.prs = r.prs
                root.accountCount = r.accounts ? r.accounts.length : 1
                root.failedAccounts = r.failed ? r.failed : []
                root.notifyChanges(r.prs)
                root.errorMsg = r.error ? r.error : ""
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }

    Timer { interval: 150000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    Plasmoid.icon: Qt.resolvedUrl("github.svg")
    toolTipMainText: "Mis PRs abiertos"
    toolTipSubText: errorMsg !== "" ? "⚠ " + errorMsg : prs.length + " abiertos, " + attention + " requieren atención"

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            width: parent.width * 0.82; height: width
            anchors { left: parent.left; top: parent.top }
            source: Qt.resolvedUrl("github.svg")
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
            visible: root.prs.length > 0
            anchors { right: parent.right; bottom: parent.bottom }
            height: Math.max(14, parent.height * 0.5)
            width: Math.max(height, badge.implicitWidth + 4)
            radius: height / 2
            color: root.attention > 0 ? "#e5484d" : "#2f81f7"
            Text { id: badge; anchors.centerIn: parent; text: root.prs.length
                color: "white"; font.pixelSize: Math.max(10, parent.height * 0.72); font.bold: true }
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Heading { level: 3; text: "Mis PRs abiertos (" + root.prs.length + ")"; Layout.fillWidth: true }
            PlasmaComponents.Button {
                icon.name: root.copied ? "dialog-ok" : "edit-copy"
                text: root.copied ? "¡Copiado!" : "Copiar resumen"
                enabled: root.prs.length > 0
                onClicked: root.copySummary()
                PlasmaComponents.ToolTip { text: "Copia al portapapeles un resumen de mis PRs para el revisor o el TL" }
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

        PlasmaComponents.ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                model: root.prs
                spacing: Kirigami.Units.smallSpacing
                section.property: "repo"
                section.delegate: Kirigami.Heading { level: 5; text: section; opacity: 0.7; topPadding: Kirigami.Units.smallSpacing }
                delegate: PlasmaComponents.ItemDelegate {
                    width: ListView.view.width
                    onClicked: Qt.openUrlExternally(modelData.url)
                    contentItem: RowLayout {
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            radius: width / 2
                            color: root.colors[modelData.status]
                            Text { anchors.centerIn: parent; text: root.glyphs[modelData.status]
                                color: "white"; font.bold: true; font.pixelSize: parent.height * 0.7; font.family: "DejaVu Sans" }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            PlasmaComponents.Label { text: "#" + modelData.number + "  " + modelData.title; elide: Text.ElideRight; Layout.fillWidth: true }
                            PlasmaComponents.Label {
                                text: modelData.label + "  ·  " + modelData.branch + " → " + modelData.base + (root.accountCount > 1 ? "  ·  @" + modelData.account : "")
                                color: root.colors[modelData.status]; font: Kirigami.Theme.smallFont; elide: Text.ElideRight; Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }
        PlasmaComponents.Label {
            visible: root.prs.length === 0 && root.errorMsg === ""
            Layout.alignment: Qt.AlignHCenter; text: root.loading ? "Cargando…" : "Sin PRs abiertos 🎉"
        }
    }
}
