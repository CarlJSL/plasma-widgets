import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var links: []
    property string filter: ""
    property bool adding: false
    property string toast: ""
    readonly property string cli: "python3 $HOME/.local/bin/my-links"

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }
    function hostOf(url) { const m = /^[a-z][a-z0-9+.-]*:\/\/([^\/?#]+)/i.exec(url); return m ? m[1].replace(/^www\./, "") : url }
    function colorOf(text) {
        let h = 0
        for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 360
        return Qt.hsla(h / 360, 0.5, 0.45, 1)
    }

    // Filtrados y ordenados: primero "General" (sin grupo), luego los grupos por nombre.
    readonly property var shown: {
        const words = filter.toLowerCase().split(/\s+/).filter(w => w !== "")
        const out = links
            .filter(l => { const hay = (l.title + " " + l.url + " " + l.group).toLowerCase(); return words.every(w => hay.indexOf(w) >= 0) })
            .map(l => ({ id: l.id, title: l.title, url: l.url, g: l.group || "General" }))
        out.sort((a, b) => (a.g === "General" ? "" : a.g).localeCompare(b.g === "General" ? "" : b.g) || a.title.localeCompare(b.title))
        return out
    }
    readonly property var groupNames: {
        const s = {}
        for (const l of links) if (l.group) s[l.group] = true
        return Object.keys(s).sort()
    }

    function refresh() { src.connectSource(cli + " # " + Date.now()) }
    function showToast(t) { toast = t; toastTimer.restart() }
    Timer { id: toastTimer; interval: 2500; onTriggered: root.toast = "" }
    function copyText(t) { clip.text = t; clip.selectAll(); clip.copy() }
    TextEdit { id: clip; visible: false }

    function openLink(url) { Qt.openUrlExternally(url); root.expanded = false }
    function addLink(url, title, group) {
        runner.connectSource(cli + " add " + q(url) + " " + q(title) + " " + q(group) + " # " + Date.now())
    }
    function removeLink(id) { runner.connectSource(cli + " rm " + q(id) + " # " + Date.now()) }

    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try { root.links = JSON.parse(data["stdout"]).links } catch (e) { root.showToast("No se pudo leer la lista") }
        }
    }
    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            const out = (data["stdout"] || data["stderr"] || "").trim()
            if (source.indexOf(" add ") >= 0) {
                root.showToast(out)
                if (out === "Guardado") root.adding = false
            }
            root.refresh()
        }
    }
    Component.onCompleted: refresh()
    onExpandedChanged: if (expanded) { filter = ""; adding = false; refresh() }

    Plasmoid.icon: Qt.resolvedUrl("icons/links.svg")
    toolTipMainText: "Mis links"
    toolTipSubText: links.length + " guardados"
    preferredRepresentation: compactRepresentation

    compactRepresentation: CompactIcon {
        onClicked: root.expanded = !root.expanded
        icon: Qt.resolvedUrl("icons/links.svg")
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumHeight: Kirigami.Units.gridUnit * 18
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.TextField {
                id: search
                Layout.fillWidth: true
                visible: !root.adding
                placeholderText: "Buscar y pulsar Enter para abrir…"
                text: root.filter
                onTextChanged: { root.filter = text; list.currentIndex = 0 }
                Component.onCompleted: forceActiveFocus()
                Connections { target: root; function onExpandedChanged() { if (root.expanded) { search.text = ""; search.forceActiveFocus() } } }
                Keys.onDownPressed: list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1)
                Keys.onUpPressed: list.currentIndex = Math.max(0, list.currentIndex - 1)
                function openCurrent() { if (list.currentIndex >= 0 && list.currentIndex < root.shown.length) root.openLink(root.shown[list.currentIndex].url) }
                Keys.onReturnPressed: openCurrent()
                Keys.onEnterPressed: openCurrent()
            }
            Kirigami.Heading { visible: root.adding; level: 3; text: "Nuevo link"; Layout.fillWidth: true }
            PlasmaComponents.Button {
                icon.name: root.adding ? "dialog-cancel" : "list-add"
                text: root.adding ? "Cancelar" : "Agregar"
                onClicked: {
                    root.adding = !root.adding
                    if (root.adding) { urlField.text = ""; titleField.text = ""; groupField.editText = ""; urlField.forceActiveFocus(); urlField.paste() }
                    else search.forceActiveFocus()
                }
            }
        }

        // ---------- formulario ----------
        ColumnLayout {
            visible: root.adding
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            PlasmaComponents.TextField { id: urlField; Layout.fillWidth: true; placeholderText: "Link (se pega solo lo que tengas copiado)"
                Keys.onReturnPressed: saveBtn.clicked() }
            PlasmaComponents.TextField { id: titleField; Layout.fillWidth: true; placeholderText: "Título (opcional; si no, usa el dominio)"
                Keys.onReturnPressed: saveBtn.clicked() }
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.ComboBox {
                    id: groupField
                    Layout.fillWidth: true
                    editable: true
                    model: root.groupNames
                    currentIndex: -1
                    editText: ""
                }
                PlasmaComponents.Button {
                    id: saveBtn
                    text: "Guardar"; icon.name: "document-save"
                    enabled: urlField.text.trim() !== ""
                    onClicked: if (enabled) root.addLink(urlField.text, titleField.text, groupField.editText)
                }
            }
            PlasmaComponents.Label { text: "Grupo opcional: elige uno existente o escribe uno nuevo."; opacity: 0.7; font: Kirigami.Theme.smallFont }
        }

        // ---------- lista ----------
        PlasmaComponents.ScrollView {
            visible: !root.adding
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                id: list
                model: root.shown
                spacing: 2
                currentIndex: 0
                clip: true
                section.property: "g"
                section.delegate: PlasmaComponents.Label {
                    required property string section
                    width: ListView.view.width
                    topPadding: Kirigami.Units.smallSpacing
                    text: section.toUpperCase()
                    font.pointSize: Kirigami.Theme.smallFont.pointSize; font.bold: true; opacity: 0.6
                }
                delegate: PlasmaComponents.ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    highlighted: ListView.isCurrentItem
                    onClicked: root.openLink(modelData.url)
                    HoverHandler { id: hh; onHoveredChanged: if (hovered) list.currentIndex = row.index }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                            radius: 6
                            color: root.colorOf(root.hostOf(row.modelData.url))
                            Text { anchors.centerIn: parent; text: root.hostOf(row.modelData.url).charAt(0).toUpperCase()
                                color: "white"; font.bold: true; font.pixelSize: parent.height * 0.55 }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            PlasmaComponents.Label { text: row.modelData.title; elide: Text.ElideRight; Layout.fillWidth: true }
                            PlasmaComponents.Label { text: root.hostOf(row.modelData.url); opacity: 0.7; font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        RowLayout {
                            spacing: 0
                            visible: hh.hovered
                            PlasmaComponents.ToolButton {
                                icon.name: "edit-copy"
                                onClicked: { root.copyText(row.modelData.url); root.showToast("Link copiado") }
                                PlasmaComponents.ToolTip { text: "Copiar link" }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "edit-delete"
                                onClicked: root.removeLink(row.modelData.id)
                                PlasmaComponents.ToolTip { text: "Borrar" }
                            }
                        }
                    }
                }
            }
        }

        PlasmaComponents.Label {
            visible: !root.adding && root.shown.length === 0
            Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            text: root.links.length === 0 ? "Aún no hay links. Pulsa «Agregar» para guardar el primero." : "Ningún link coincide con «" + root.filter + "»"
        }
        PlasmaComponents.Label {
            visible: root.toast !== ""
            Layout.alignment: Qt.AlignHCenter
            text: root.toast; color: Kirigami.Theme.positiveTextColor
        }
    }
}
