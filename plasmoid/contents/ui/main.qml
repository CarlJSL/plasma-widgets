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
    property var review: []
    property var watching: []
    property bool jiraOn: false
    property string toast: ""
    property int accountCount: 1
    property string errorMsg: ""
    property bool loading: false
    readonly property string cmd: "python3 $HOME/.local/bin/my-prs --widget"
    readonly property string cli: "python3 $HOME/.local/bin/my-prs"

    // Colores fijos (no del tema): el tema los deja apagados/grises. Tonos medios que se leen en claro y oscuro.
    readonly property var colors: ({
        "observado": "#e5484d",
        "conflicto": "#e5484d",
        "ci": "#e5484d",
        "probando": "#2f81f7",
        "aprobado": "#2da44e",
        "review": "#d98e04",
        "draft": "#8b949e",
        "mergeado": "#8957e5",
        "cerrado": "#8b949e",
        "error": "#e5484d"
    })
    readonly property var glyphs: ({
        "observado": "!", "conflicto": "×", "ci": "×", "probando": "↻", "aprobado": "✓", "review": "…", "draft": "–", "mergeado": "✓", "cerrado": "×", "error": "!"
    })
    readonly property int watchDone: watching.filter(w => w.state !== "OPEN" && w.state !== "UNKNOWN").length
    readonly property int pending: review.length + watchDone
    readonly property int attention: prs.filter(p => ["observado", "conflicto", "ci"].includes(p.status)).length

    property var failedAccounts: []
    property var prevStatus: ({})
    property bool initialized: false
    readonly property var notifyOn: ({
        "observado": "Observado", "conflicto": "Tiene conflictos", "ci": "CI fallando", "aprobado": "Aprobado ✓"
    })

    function q(t) { return "'" + String(t).replace(/'/g, "'\\''") + "'" }

    function notify(title, body, urgency) {
        notifier.connectSource("notify-send -a 'Mis PRs' -i dialog-information -u " + urgency + " "
            + q(title) + " " + q(body) + " # " + Date.now() + Math.random())
    }

    property var prevReview: ({})
    property bool reviewInit: false
    property var ackedLocal: []

    function notifyExtras(r) {
        // Nuevos PRs que piden mi review
        const next = {}
        for (const p of r.review) {
            const k = p.owner + "#" + p.number
            next[k] = true
            if (reviewInit && !prevReview[k])
                notify(p.repo + " #" + p.number + ": te piden review", p.title + (p.author ? " (de " + p.author + ")" : ""), "normal")
        }
        prevReview = next
        reviewInit = true
        // PRs en seguimiento que ya se mergearon o cerraron (se avisa una sola vez, queda marcado en disco)
        for (const w of r.watching) {
            if ((w.state === "MERGED" || w.state === "CLOSED") && !w.acked && !ackedLocal.includes(w.url)) {
                ackedLocal = ackedLocal.concat([w.url])
                notify(w.repo + " #" + w.number + (w.state === "MERGED" ? ": ya se hizo merge" : ": se cerró sin merge"),
                       (w.note ? "Tu nota: " + w.note + "\n" : "") + w.title, "critical")
                runner.connectSource(cli + " watch ack " + q(w.url) + " # " + Date.now())
            }
        }
        // Recordatorio diario de PRs estancados
        if (r.remind && r.remind.length > 0)
            notify("PRs sin movimiento (" + r.remind.length + ")",
                   r.remind.map(x => x.repo + " #" + x.number + " (" + x.idleDays + " d)").join("\n"), "normal")
    }

    function notifyChanges(list) {
        const next = {}
        // Cuentas que fallaron: conservar su estado previo para no perder ni repetir avisos al volver.
        for (const k in prevStatus) if (failedAccounts.includes(prevStatus[k].account)) next[k] = prevStatus[k]
        for (const p of list) {
            const k = p.owner + "#" + p.number
            next[k] = { status: p.status, account: p.account }
            if (initialized && (!prevStatus[k] || prevStatus[k].status !== p.status) && notifyOn[p.status]) {
                const urgency = p.status === "aprobado" ? "normal" : "critical"
                notify(p.repo + " #" + p.number + ": " + notifyOn[p.status], p.title, urgency)
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

    function showToast(t) { toast = t; toastTimer.restart() }
    Timer { id: toastTimer; interval: 2500; onTriggered: root.toast = "" }

    function copyText(t) { clip.text = t; clip.selectAll(); clip.copy() }
    function copyLink(url) { copyText(url); showToast("Link copiado") }
    function openChecks(url) { Qt.openUrlExternally(url + "/checks") }
    function reReview(account, url) {
        showToast("Pidiendo re-review…")
        runner.connectSource(cli + " rereview " + q(account) + " " + q(url) + " # " + Date.now())
    }
    function follow(url, note) {
        runner.connectSource(cli + " watch add " + q(url) + " " + q(note) + " # " + Date.now())
    }
    function unfollow(url) {
        runner.connectSource(cli + " watch rm " + q(url) + " # " + Date.now())
    }

    // Comandos de acción (seguir, dejar de seguir, re-review, ack)
    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            const out = (data["stdout"] || data["stderr"] || "").trim()
            if (source.indexOf(" rereview ") >= 0) { root.showToast(out); }
            else if (source.indexOf(" watch add ") >= 0) { root.showToast(out.startsWith("Siguiendo") ? "Siguiendo PR" : (out || "No se pudo seguir")); root.refresh() }
            else if (source.indexOf(" watch rm ") >= 0) root.refresh()
        }
    }

    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            root.loading = false
            try {
                const r = JSON.parse(data["stdout"])
                root.prs = r.prs
                root.review = r.review || []
                root.watching = r.watching || []
                root.jiraOn = r.jira === true
                root.accountCount = r.accounts ? r.accounts.length : 1
                root.failedAccounts = r.failed ? r.failed : []
                root.notifyChanges(r.prs)
                root.notifyExtras(r)
                root.errorMsg = r.error ? r.error : ""
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }

    Timer { interval: 150000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    function subtitleOf(p) {
        let parts = []
        if (p.ticket) parts.push(p.ticket + (p.ticketStatus ? " · " + p.ticketStatus : ""))
        if (p.author) parts.push("de " + p.author)
        parts.push(p.branch + " → " + p.base)
        if (accountCount > 1) parts.push("@" + p.account)
        return parts.join("  ·  ")
    }

    Plasmoid.icon: Qt.resolvedUrl("github.svg")
    toolTipMainText: "Mis PRs"
    toolTipSubText: errorMsg !== "" ? "⚠ " + errorMsg
        : prs.length + " abiertos, " + attention + " requieren atención\n"
          + review.length + " esperan tu review, " + watchDone + " en seguimiento listos"

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
        // Pendientes de mí: PRs que piden mi review + PRs en seguimiento ya mergeados
        Rectangle {
            visible: root.pending > 0
            anchors { left: parent.left; bottom: parent.bottom }
            height: Math.max(14, parent.height * 0.5)
            width: Math.max(height, pendingText.implicitWidth + 4)
            radius: height / 2
            color: "#d98e04"
            Text { id: pendingText; anchors.centerIn: parent; text: root.pending
                color: "white"; font.pixelSize: Math.max(10, parent.height * 0.72); font.bold: true; font.family: "DejaVu Sans" }
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
        Layout.minimumWidth: Kirigami.Units.gridUnit * 28
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.TabBar {
                id: tabs
                Layout.fillWidth: true
                PlasmaComponents.TabButton { text: "Mis PRs (" + root.prs.length + ")" }
                PlasmaComponents.TabButton { text: "Para revisar (" + root.review.length + ")" }
                PlasmaComponents.TabButton { text: "Seguimiento (" + root.watching.length + ")" }
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

        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // ---------- Mis PRs ----------
            ColumnLayout {
                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Button {
                        icon.name: root.copied ? "dialog-ok" : "edit-copy"
                        text: root.copied ? "¡Copiado!" : "Copiar resumen"
                        enabled: root.prs.length > 0
                        onClicked: root.copySummary()
                        PlasmaComponents.ToolTip { text: "Copia al portapapeles un resumen de mis PRs para el revisor o el TL" }
                    }
                }
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.prs
                        spacing: Kirigami.Units.smallSpacing
                        section.property: "repo"
                        section.delegate: Kirigami.Heading { level: 5; text: section; opacity: 0.7; topPadding: Kirigami.Units.smallSpacing }
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: root.subtitleOf(modelData)
                            showReReview: modelData.label.indexOf("re-review") >= 0 || modelData.status === "observado"
                            onCopyLink: url => root.copyLink(url)
                            onOpenChecks: url => root.openChecks(url)
                            onReReview: (account, url) => root.reReview(account, url)
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.prs.length === 0
                    Layout.alignment: Qt.AlignHCenter; text: root.loading ? "Cargando…" : "Sin PRs abiertos"
                }
            }

            // ---------- Para revisar ----------
            ColumnLayout {
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.review
                        spacing: Kirigami.Units.smallSpacing
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: "de " + modelData.author + "  ·  " + modelData.repo + "  ·  hace " + modelData.ageDays + " d"
                            onCopyLink: url => root.copyLink(url)
                            onOpenChecks: url => root.openChecks(url)
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.review.length === 0
                    Layout.alignment: Qt.AlignHCenter; text: root.loading ? "Cargando…" : "Nadie te está esperando"
                }
            }

            // ---------- Seguimiento ----------
            ColumnLayout {
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.TextField { id: followUrl; Layout.fillWidth: true; Layout.preferredWidth: 3
                        placeholderText: "Link del PR a seguir" }
                    PlasmaComponents.TextField { id: followNote; Layout.fillWidth: true; Layout.preferredWidth: 2
                        placeholderText: "Nota (por qué lo sigues)"
                        onAccepted: followBtn.clicked() }
                    PlasmaComponents.Button {
                        id: followBtn
                        text: "Seguir"; icon.name: "bookmark-new"
                        enabled: followUrl.text.indexOf("github.com") >= 0
                        onClicked: { root.follow(followUrl.text, followNote.text); followUrl.text = ""; followNote.text = "" }
                    }
                }
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.watching
                        spacing: Kirigami.Units.smallSpacing
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            alwaysShowActions: true
                            extraIcon: "edit-delete"; extraTip: "Dejar de seguir"
                            subtitle: (modelData.note ? "Nota: " + modelData.note + "  ·  " : "") + modelData.repo + " · de " + modelData.author
                            onCopyLink: url => root.copyLink(url)
                            onOpenChecks: url => root.openChecks(url)
                            onExtra: url => root.unfollow(url)
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.watching.length === 0
                    Layout.alignment: Qt.AlignHCenter; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true; wrapMode: Text.Wrap
                    text: "Pega el link de un PR ajeno del que dependes. Te aviso cuando se haga merge."
                }
            }
        }

        PlasmaComponents.Label {
            visible: root.toast !== ""
            Layout.alignment: Qt.AlignHCenter
            text: root.toast; opacity: 0.85
        }
    }
}
