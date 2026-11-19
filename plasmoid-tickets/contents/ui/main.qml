import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
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
    // Buscador de la lista: tus tickets que coinciden + resultados del resto de Jira
    property string findQuery: ""
    property string findSearched: ""
    property var findResults: []
    property bool finding: false
    readonly property var visibleTickets: {
        const t = findQuery.trim().toLowerCase()
        if (t === "") return showBacklog ? tickets : active
        const mine = tickets.filter(x => (x.key + " " + x.summary).toLowerCase().indexOf(t) >= 0)
        const have = {}
        mine.forEach(x => have[x.key] = true)
        const more = findSearched === findQuery.trim() ? findResults.filter(r => !have[r.key]).map(r => ({
            key: r.key, summary: r.summary, status: r.status, type: "", cat: "", url: r.url, idleDays: -1, priority: "",
            stale: false, blockedBy: "", sec: "Jira › Otros resultados", remote: true })) : []
        return mine.concat(more)
    }
    readonly property int staleCount: active.filter(t => t.stale).length
    readonly property var statusCount: {
        const m = {}
        for (const t of visibleTickets) m[t.sec] = (m[t.sec] || 0) + 1
        return m
    }

    // Prefijo que comparten varios títulos ("[App] Lista de Difusión:"): se muestra una vez y se quita de las filas.
    readonly property string commonPrefix: {
        const c = {}
        for (const t of visibleTickets) {
            const i = t.summary.indexOf(":")
            if (i > 0 && i <= 45) { const k = t.summary.substring(0, i); c[k] = (c[k] || 0) + 1 }
        }
        let best = "", n = 0
        for (const k in c) if (c[k] > n) { best = k; n = c[k] }
        return n >= 3 ? best : ""
    }
    function stripPrefix(text) {
        if (commonPrefix !== "" && text.startsWith(commonPrefix + ":")) {
            const r = text.substring(commonPrefix.length + 1).trim()
            return r.charAt(0).toUpperCase() + r.substring(1)
        }
        return text
    }
    function cleanSummary(t) {
        if (commonPrefix !== "" && t.summary.startsWith(commonPrefix + ":")) {
            const r = t.summary.substring(commonPrefix.length + 1).trim()
            return r.charAt(0).toUpperCase() + r.substring(1)
        }
        return t.summary
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
                if (!r.error) { root.tickets = r.tickets; root.blocks = r.blocks || []; root.notifyNew(r.tickets); root.notifyReady(root.blocks) }
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }
    Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    // ---- bloqueos: "no puedo avanzar KEY hasta terminar OTRO" ----
    property var blocks: []
    property string tab: "tickets"
    property string blockingKey: ""
    property var ackedLocal: []
    readonly property int readyCount: blocks.filter(b => b.blockerDone).length
    readonly property string cli: "python3 $HOME/.local/bin/my-tickets"
    // Worktrees por ticket (carpetas <repo>-<CLAVE>[-sufijo]) y búsqueda en Jira de la lista
    property var worktrees: ({})
    function loadWts() { wtSrc.connectSource(cli + " worktrees # " + Date.now()) }
    P5Support.DataSource {
        id: wtSrc
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try { root.worktrees = JSON.parse(data["stdout"]).worktrees } catch (e) {}
        }
    }
    function queueFind(text) {
        findQuery = text
        if (text.trim().length >= 2) { finding = true; findTimer.restart() } else { finding = false; findResults = []; findSearched = "" }
    }
    Timer { id: findTimer; interval: 400; onTriggered: finder.connectSource(root.cli + " search " + root.q(root.findQuery.trim()) + " # " + Date.now()) }
    P5Support.DataSource {
        id: finder
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try {
                const r = JSON.parse(data["stdout"])
                if (r.q === root.findQuery.trim()) { root.findResults = r.results; root.findSearched = r.q; root.finding = false }
            } catch (e) { root.finding = false }
        }
    }
    function openWt(repo, name) { runner.connectSource(cli + " open-wt " + q(repo) + " " + q(name) + " # " + Date.now()); showToast("Abriendo " + repo + "-" + name + "…") }
    function wtCommand(repo, name) { return "wt " + repo + " " + name }
    Component.onCompleted: loadWts()
    onExpandedChanged: if (expanded) loadWts()

    // Buscador del ticket que bloquea: tus tickets al instante + resultados de Jira
    property string blockerKey: ""
    property string blockerLabel: ""
    property string blockerQuery: ""
    property string searchedFor: ""
    property var remoteResults: []
    property bool searching: false
    readonly property var suggestions: {
        const t = blockerQuery.trim().toLowerCase()
        const seen = {}
        const out = []
        const add = x => { if (x.key !== blockingKey && !seen[x.key]) { seen[x.key] = true; out.push(x) } }
        tickets.filter(x => t === "" || (x.key + " " + x.summary).toLowerCase().indexOf(t) >= 0)
               .forEach(x => add({ key: x.key, summary: x.summary, status: x.status, mine: true }))
        if (searchedFor === blockerQuery.trim()) remoteResults.forEach(add)
        return out.slice(0, 7)
    }
    function queueSearch(text) {
        blockerQuery = text
        if (text.trim().length >= 2) { searching = true; searchTimer.restart() } else { searching = false; remoteResults = []; searchedFor = "" }
    }
    Timer {
        id: searchTimer; interval: 400
        onTriggered: searcher.connectSource(root.cli + " search " + root.q(root.blockerQuery.trim()) + " # " + Date.now())
    }
    P5Support.DataSource {
        id: searcher
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try {
                const r = JSON.parse(data["stdout"])
                if (r.q === root.blockerQuery.trim()) { root.remoteResults = r.results; root.searchedFor = r.q; root.searching = false }
            } catch (e) { root.searching = false }
        }
    }
    function pickBlocker(x) { blockerKey = x.key; blockerLabel = x.key + "   " + x.summary }
    function resetBlocker() { blockerKey = ""; blockerLabel = ""; blockerQuery = ""; searchedFor = ""; remoteResults = []; searching = false }

    function startBlock(key) { resetBlocker(); blockingKey = key; tab = "tickets" }
    function saveBlock(note) {
        const text = blockerKey !== "" ? blockerKey : blockerQuery
        const m = String(text).toUpperCase().match(/[A-Z][A-Z0-9]+-\d+/)
        if (!m) { showToast("Elige un ticket de la lista o escribe su clave (por ejemplo IN-1700)"); return }
        runner.connectSource(cli + " block add " + q(blockingKey) + " " + q(m[0]) + " " + q(note) + " # " + Date.now())
        blockingKey = ""; resetBlocker()
    }
    function unblock(key) { runner.connectSource(cli + " block rm " + q(key) + " # " + Date.now()) }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            const out = (data["stdout"] || "").trim()
            if (source.indexOf(" open-wt ") >= 0) { if (!out.startsWith("Abierto")) root.showToast(out || data["stderr"] || "No se pudo abrir"); return }
            if (source.indexOf(" block add ") >= 0) root.showToast(out || (data["stderr"] || "No se pudo guardar"))
            if (source.indexOf(" block ack ") < 0) root.refresh()
        }
    }

    function notifyReady(list) {
        for (const b of list) {
            if (b.blockerDone && !b.acked && !ackedLocal.includes(b.key)) {
                ackedLocal = ackedLocal.concat([b.key])
                notify("Ya puedes avanzar " + b.key, b.blocker + " terminó" + (b.note ? ". Tu nota: " + b.note : ""))
                runner.connectSource(cli + " block ack " + q(b.key) + " # " + Date.now())
            }
        }
    }

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
        if (blocks.length > 0) {
            out += "\nBloqueados (" + blocks.length + ")\n"
            for (const b of blocks)
                out += "- " + b.key + " espera a " + b.blocker + " (" + b.blockerStatus + ")" + (b.note ? ": " + b.note : "") + "\n"
        }
        return out.trim()
    }

    Plasmoid.icon: "view-task"
    toolTipMainText: "Mis tickets"
    toolTipSubText: errorMsg !== "" ? "⚠ " + errorMsg : active.length + " activos, " + staleCount + " sin movimiento\n" + blocks.length + " bloqueados, " + readyCount + " ya se pueden avanzar"

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
        // Tickets bloqueados cuyo bloqueo ya se resolvió: ya puedes avanzarlos
        Rectangle {
            visible: root.readyCount > 0
            anchors { left: parent.left; bottom: parent.bottom }
            height: Math.max(14, parent.height * 0.5)
            width: Math.max(height, readyText.implicitWidth + 4)
            radius: height / 2
            color: "#2da44e"
            Text { id: readyText; anchors.centerIn: parent; text: root.readyCount
                color: "white"; font.pixelSize: Math.max(10, parent.height * 0.72); font.bold: true; font.family: "DejaVu Sans" }
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

        PlasmaComponents.TabBar {
            Layout.fillWidth: true
            PlasmaComponents.TabButton { text: "Mis tickets (" + root.active.length + ")"; onClicked: root.tab = "tickets" }
            PlasmaComponents.TabButton { text: "Bloqueados (" + root.blocks.length + ")"; onClicked: root.tab = "blocked" }
        }

        // Formulario: marcar un ticket como bloqueado por otro
        Rectangle {
            visible: root.tab === "tickets" && root.blockingKey !== ""
            Layout.fillWidth: true
            implicitHeight: blockForm.implicitHeight + Kirigami.Units.largeSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.07)
            ColumnLayout {
                id: blockForm
                anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Heading { level: 5; Layout.fillWidth: true; elide: Text.ElideRight
                    text: "No puedo avanzar " + root.blockingKey + " hasta terminar:" }
                PlasmaComponents.TextField {
                    id: blockerSearch
                    visible: root.blockerKey === ""
                    Layout.fillWidth: true
                    placeholderText: "Buscar ticket por clave o texto (ej.: IN-1700 o «lista difusión»)"
                    text: root.blockerQuery
                    onTextChanged: if (text !== root.blockerQuery) root.queueSearch(text)
                    onVisibleChanged: if (visible) forceActiveFocus()
                    Connections { target: root; function onBlockerQueryChanged() { if (blockerSearch.text !== root.blockerQuery) blockerSearch.text = root.blockerQuery } }
                    Keys.onReturnPressed: if (root.suggestions.length > 0) root.pickBlocker(root.suggestions[0])
                    Keys.onEnterPressed: if (root.suggestions.length > 0) root.pickBlocker(root.suggestions[0])
                }
                RowLayout {
                    visible: root.blockerKey !== ""
                    Layout.fillWidth: true
                    PlasmaComponents.Label { Layout.fillWidth: true; elide: Text.ElideRight; font.bold: true; text: root.blockerLabel }
                    PlasmaComponents.ToolButton {
                        icon.name: "edit-clear"
                        onClicked: root.resetBlocker()
                        PlasmaComponents.ToolTip { text: "Elegir otro ticket" }
                    }
                }
                Repeater {
                    model: root.blockerKey === "" ? root.suggestions : []
                    delegate: PlasmaComponents.ItemDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        onClicked: root.pickBlocker(modelData)
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents.Label { text: modelData.key; font.bold: true; Layout.preferredWidth: Kirigami.Units.gridUnit * 4.5 }
                            PlasmaComponents.Label { text: modelData.summary; elide: Text.ElideRight; Layout.fillWidth: true }
                            PlasmaComponents.Label { text: modelData.status; opacity: 0.6; font: Kirigami.Theme.smallFont }
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.blockerKey === "" && root.searching
                    opacity: 0.6; font: Kirigami.Theme.smallFont; text: "Buscando en Jira…"
                }
                PlasmaComponents.Label {
                    visible: root.blockerKey === "" && !root.searching && root.blockerQuery.trim().length >= 2 && root.suggestions.length === 0
                    opacity: 0.6; font: Kirigami.Theme.smallFont; text: "Sin resultados. Prueba con la clave completa (IN-1700)."
                }
                PlasmaComponents.TextField {
                    id: blockNote
                    Layout.fillWidth: true
                    placeholderText: "Nota (por qué depende)"
                    onAccepted: saveBtn.clicked()
                }
                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Button { text: "Cancelar"; onClicked: { root.blockingKey = ""; root.resetBlocker(); blockNote.text = "" } }
                    PlasmaComponents.Button {
                        id: saveBtn
                        text: "Guardar"; icon.name: "object-locked"
                        onClicked: { root.saveBlock(blockNote.text); blockNote.text = "" }
                    }
                }
            }
        }

        PlasmaComponents.Label {
            visible: root.tab === "tickets" && root.commonPrefix !== ""
            Layout.fillWidth: true; elide: Text.ElideRight; opacity: 0.6; font: Kirigami.Theme.smallFont
            text: root.commonPrefix + "  ·  prefijo omitido en los títulos"
        }

        PlasmaComponents.CheckBox {
            visible: root.tab === "tickets"
            text: "Incluir backlog y por hacer (" + (root.tickets.length - root.active.length) + ")"
            checked: root.showBacklog
            onToggled: root.showBacklog = checked
        }

        QQC2.Popup {
            id: wtPopup
            property string key: ""
            readonly property var items: root.worktrees[key] || []
            x: parent ? parent.width - width : 0
            function openFor(k, anchor) { key = k; parent = anchor; y = anchor.height; open() }
            padding: Kirigami.Units.smallSpacing
            closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutside
            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { text: "Worktrees de " + wtPopup.key; font.bold: true }
                Repeater {
                    model: wtPopup.items
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents.Label { Layout.fillWidth: true; Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                            text: modelData.repo + "  ·  " + modelData.name; elide: Text.ElideRight }
                        PlasmaComponents.ToolButton {
                            icon.name: "utilities-terminal"; text: "Abrir"
                            onClicked: { root.openWt(modelData.repo, modelData.name); wtPopup.close() }
                            PlasmaComponents.ToolTip { text: "Abrir VS Code y una terminal con Claude en este worktree" }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "edit-copy"
                            onClicked: { root.copyText(root.wtCommand(modelData.repo, modelData.name)); root.showToast("Comando copiado"); wtPopup.close() }
                            PlasmaComponents.ToolTip { text: "Copiar: " + root.wtCommand(modelData.repo, modelData.name) }
                        }
                    }
                }
            }
        }

        PlasmaComponents.TextField {
            id: findField
            visible: root.tab === "tickets"
            Layout.fillWidth: true
            placeholderText: "Buscar ticket por clave o texto (también en el resto de Jira)…"
            text: root.findQuery
            onTextChanged: if (text !== root.findQuery) root.queueFind(text)
            Keys.onEscapePressed: root.queueFind("")
        }
        PlasmaComponents.Label {
            visible: root.tab === "tickets" && root.finding
            opacity: 0.6; font: Kirigami.Theme.smallFont; text: "Buscando en Jira…"
        }

        PlasmaComponents.ScrollView {
            visible: root.tab === "tickets"
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                model: root.visibleTickets
                spacing: 0
                section.property: "sec"
                // "Tablero › Columna": la columna destacada y el tablero como contexto
                section.delegate: RowLayout {
                    required property string section
                    width: ListView.view ? ListView.view.width : 0
                    Kirigami.Heading {
                        level: 4; topPadding: Kirigami.Units.gridUnit * 0.7; bottomPadding: Kirigami.Units.smallSpacing
                        text: section.split(" › ")[1] + "  " + (root.statusCount[section] || 0)
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        Layout.topMargin: Kirigami.Units.gridUnit * 0.7
                        text: section.split(" › ")[0]; opacity: 0.55; font: Kirigami.Theme.smallFont
                    }
                }
                delegate: PlasmaComponents.ItemDelegate {
                    id: row
                    width: ListView.view.width
                    topPadding: 6; bottomPadding: 6
                    onClicked: Qt.openUrlExternally(modelData.url)
                    HoverHandler { id: hh }
                    // Filete fino entre filas
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: Kirigami.Theme.textColor; opacity: 0.08
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing * 1.5
                        // Barra de color por tipo: más discreta que un círculo por fila
                        Rectangle {
                            Layout.fillHeight: true; Layout.preferredWidth: 3; radius: 2
                            color: root.typeColor[modelData.type] || "#8b949e"
                        }
                        // Columna 1: clave, alineada en todas las filas
                        PlasmaComponents.Label {
                            Layout.alignment: Qt.AlignTop
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4.6
                            text: modelData.key; font.bold: true; opacity: 0.9
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        }
                        // Columna 2: título
                        PlasmaComponents.Label {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignTop
                            text: root.cleanSummary(modelData)
                            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                        }
                        // Columna 3: lo que merece atención, a la derecha
                        ColumnLayout {
                            Layout.alignment: Qt.AlignTop; spacing: 2
                            PlasmaComponents.Label {
                                Layout.alignment: Qt.AlignRight
                                visible: modelData.idleDays >= 0
                                text: (modelData.idleDays === 0 ? "hoy" : "hace " + modelData.idleDays + " d")
                                opacity: 0.55; font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                Layout.alignment: Qt.AlignRight
                                visible: !!modelData.remote
                                text: modelData.status; opacity: 0.55; font: Kirigami.Theme.smallFont
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignRight
                                visible: !!root.worktrees[modelData.key]
                                radius: 3; color: Kirigami.Theme.textColor; opacity: 0.55
                                implicitWidth: wtText.implicitWidth + 8; implicitHeight: wtText.implicitHeight + 2
                                Text { id: wtText; anchors.centerIn: parent; text: "worktree " + (root.worktrees[modelData.key] || []).length
                                    color: Kirigami.Theme.backgroundColor; font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignRight
                                visible: modelData.priority === "Highest" || modelData.priority === "High"
                                radius: 3; color: root.prioColor(modelData.priority)
                                implicitWidth: prioText.implicitWidth + 8; implicitHeight: prioText.implicitHeight + 2
                                Text { id: prioText; anchors.centerIn: parent; text: modelData.priority; color: "white"
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignRight
                                visible: !!modelData.blockedBy
                                radius: 3; color: "#8957e5"
                                implicitWidth: blockedText.implicitWidth + 8; implicitHeight: blockedText.implicitHeight + 2
                                Text { id: blockedText; anchors.centerIn: parent; text: "espera " + modelData.blockedBy; color: "white"
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignRight
                                visible: modelData.stale
                                radius: 3; color: "#d98e04"
                                implicitWidth: staleText.implicitWidth + 8; implicitHeight: staleText.implicitHeight + 2
                                Text { id: staleText; anchors.centerIn: parent; text: "sin movimiento"; color: "white"
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.9; font.bold: true }
                            }
                        }
                        RowLayout {
                            spacing: 0
                            visible: hh.hovered
                            Layout.alignment: Qt.AlignTop
                            PlasmaComponents.ToolButton {
                                visible: !!root.worktrees[modelData.key]
                                icon.name: "folder-open"
                                onClicked: wtPopup.openFor(modelData.key, this)
                                PlasmaComponents.ToolTip { text: "Worktrees de este ticket (" + (root.worktrees[modelData.key] || []).length + ")" }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "edit-copy"
                                onClicked: { root.copyText(modelData.url); root.showToast("Link copiado") }
                                PlasmaComponents.ToolTip { text: "Copiar link del ticket" }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "object-locked"
                                onClicked: root.startBlock(modelData.key)
                                PlasmaComponents.ToolTip { text: "Marcar como bloqueado por otro ticket" }
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
            visible: root.tab === "tickets" && root.visibleTickets.length === 0
            Layout.alignment: Qt.AlignHCenter; text: root.loading ? "Cargando…" : (root.findQuery.trim() !== "" ? "Sin resultados" : "Sin tickets asignados")
        }
        // ---------- Bloqueados ----------
        PlasmaComponents.ScrollView {
            visible: root.tab === "blocked"
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
                model: root.blocks
                spacing: 0
                delegate: PlasmaComponents.ItemDelegate {
                    id: brow
                    width: ListView.view.width
                    topPadding: 8; bottomPadding: 8
                    onClicked: Qt.openUrlExternally(modelData.blockerUrl)
                    HoverHandler { id: bh }
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: Kirigami.Theme.textColor; opacity: 0.08
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing * 1.5
                        Rectangle {
                            Layout.fillHeight: true; Layout.preferredWidth: 3; radius: 2
                            color: modelData.blockerDone ? "#2da44e" : "#8957e5"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents.Label { text: modelData.key; font.bold: true }
                                PlasmaComponents.Label { text: "espera a"; opacity: 0.6 }
                                PlasmaComponents.Label { text: modelData.blocker; font.bold: true }
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    radius: 3; color: modelData.blockerDone ? "#2da44e" : "#8b949e"
                                    implicitWidth: bstText.implicitWidth + 8; implicitHeight: bstText.implicitHeight + 2
                                    Text { id: bstText; anchors.centerIn: parent; color: "white"; font.bold: true
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize * 0.95
                                        text: modelData.blockerDone ? "Terminado: ya puedes avanzar" : modelData.blockerStatus }
                                }
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                text: root.stripPrefix(modelData.blockerSummary)
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true; elide: Text.ElideRight; opacity: 0.6; font: Kirigami.Theme.smallFont
                                text: (modelData.note ? "Nota: " + modelData.note + "  ·  " : "")
                                    + (modelData.daysBlocked === 0 ? "desde hoy" : "hace " + modelData.daysBlocked + " d")
                            }
                        }
                        RowLayout {
                            spacing: 0; visible: bh.hovered
                            Layout.alignment: Qt.AlignTop
                            PlasmaComponents.ToolButton {
                                icon.name: "document-open"
                                onClicked: Qt.openUrlExternally(modelData.url)
                                PlasmaComponents.ToolTip { text: "Abrir " + modelData.key }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "edit-delete"
                                onClicked: root.unblock(modelData.key)
                                PlasmaComponents.ToolTip { text: "Ya no está bloqueado" }
                            }
                        }
                    }
                }
            }
        }
        PlasmaComponents.Label {
            visible: root.tab === "blocked" && root.blocks.length === 0
            Layout.alignment: Qt.AlignHCenter; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true; wrapMode: Text.Wrap
            text: "Nada bloqueado. En «Mis tickets», pasa el mouse sobre uno y usa el candado para marcar de qué depende."
        }

        PlasmaComponents.Label {
            visible: root.toast !== ""
            Layout.alignment: Qt.AlignHCenter; text: root.toast; opacity: 0.85
        }
    }
}
