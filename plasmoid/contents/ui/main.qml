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

    property var prevStatus: ({})
    property bool initialized: false
    readonly property var notifyOn: ({
        "observado": "Observado", "conflicto": "Tiene conflictos", "ci": "CI fallando", "aprobado": "Aprobado ✓"
    })

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }

    function notifyChanges(list) {
        const next = {}
        for (const p of list) {
            const k = p.owner + "#" + p.number
            next[k] = p.status
            if (initialized && prevStatus[k] !== p.status && notifyOn[p.status]) {
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
                if (!r.error) root.notifyChanges(r.prs)
                root.errorMsg = r.error ? r.error : ""
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }

    Timer { interval: 150000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    Plasmoid.icon: Qt.resolvedUrl("github.svg")
    toolTipMainText: "Mis PRs abiertos"
    toolTipSubText: errorMsg !== "" ? errorMsg : prs.length + " abiertos, " + attention + " requieren atención"

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
