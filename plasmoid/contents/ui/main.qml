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
    property var reviews: ({})
    property bool batchRunning: false
    property bool batchConfirm: false
    readonly property var batchPending: review.filter(p => {
        const r = reviews[p.url]
        if (r && (r.status === "queued" || r.status === "running")) return false
        return !(r && r.status === "done" && r.sha === p.sha)
    })
    readonly property var batchActive: review.filter(p => reviews[p.url] && (reviews[p.url].status === "queued" || reviews[p.url].status === "running"))
    property var merged: []
    property var reviewed: []
    property int reviewedDays: 14
    property string tlLogin: ""
    property var mineView: []
    property var groups: []
    property var groupById: ({})
    property int mergedDays: 5
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
        + groups.filter(g => g.code === "desync").length

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
    property var prevGroups: ({})
    property bool groupsInit: false

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
        // Cambios con varios PRs (front + back): avisar cuando quedan desalineados o listos para mergear juntos
        const gnext = {}
        for (const g of r.groups || []) {
            const k = g.id + "|" + g.code
            if (g.code) gnext[k] = true
            if (groupsInit && g.code && !prevGroups[k] && ["desync", "mixed", "ready"].includes(g.code))
                notify(g.title, g.warnings.join("\n"), g.code === "ready" ? "normal" : "critical")
        }
        prevGroups = gnext
        groupsInit = true
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
    property string selectedKey: "mine"

    // "Para revisar" solo existe cuando alguien te está esperando. tabKeys cambia solo cuando cambia la
    // composición de pestañas (no en cada refresco), para no reconstruir la barra.
    property var tabKeys: ["mine", "watch", "merged"]
    function refreshTabs() {
        const k = ["mine"]
        if (review.length > 0) k.push("review")
        k.push("watch", "merged")
        if (reviewed.length > 0) k.push("reviewed")
        if (k.join() !== tabKeys.join()) tabKeys = k
    }
    function titleOf(key) {
        if (key === "mine") return "Mis PRs (" + prs.length + ")"
        if (key === "review") return "Para revisar (" + review.length + ")"
        if (key === "watch") return "Seguimiento (" + watching.length + ")"
        if (key === "reviewed") return "Revisados (" + reviewed.length + ")"
        return "Mergeados (" + merged.length + ")"
    }
    // Si la pestaña elegida desaparece, volver a la primera.
    readonly property string activeTab: tabKeys.indexOf(selectedKey) >= 0 ? selectedKey : "mine"

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


    // Estado de aprobaciones frente al TL: regla "si hay commits después del approve del compañero, vuelve primero a él".
    function approvalSummary() {
        const tl = tlLogin.toLowerCase()
        const isTl = r => r.login.toLowerCase() === tl
        const line = (p, extra) => "- " + p.repo + " #" + p.number + " " + p.title + (extra ? " — " + extra : "") + "\n  " + p.url + "\n"
        const sec = (title, items) => items.length ? "\n" + title + " (" + items.length + ")\n" + items.join("") : ""
        const names = rs => rs.map(r => "@" + r.login).join(", ")
        const A = [], B = [], C = [], D = [], E = [], F = []
        let tlOk = 0
        for (const p of prs) {
            if (p.status === "draft") continue
            const rs = p.reviews || []
            if (rs.some(r => isTl(r) && r.state === "APPROVED")) { tlOk++; continue }
            const peers = rs.filter(r => !isTl(r) && r.login !== p.account)
            if (["observado", "conflicto", "ci"].includes(p.status)) { F.push(line(p, p.label)); continue }
            const stale = peers.filter(r => (r.state === "APPROVED" || r.state === "CHANGES_REQUESTED") && !r.current)
            const ok = peers.filter(r => r.state === "APPROVED" && r.current)
            if (stale.length) B.push(line(p, "hubo commits después del review de " + names(stale)))
            else if (ok.length) A.push(line(p, "aprobado por " + names(ok)))
            else C.push(line(p, p.status === "probando" ? "CI en curso, sin approve vigente del compañero" : "sin approve vigente del compañero"))
        }
        for (const p of reviewed) {
            if (p.prState !== "OPEN" || p.isDraft || p.myState !== "APPROVED") continue
            const rs = p.reviews || []
            if (rs.some(r => isTl(r) && r.state === "APPROVED")) continue
            if (p.newCommits) E.push(line(p, "@" + p.author + " subió commits tras mi approve: me toca re-review antes de pedirlo"))
            else D.push(line(p, "@" + p.author + ", ya lo aprobé yo"))
        }
        let out = "Aprobaciones pendientes (" + new Date().toLocaleDateString("es") + ")\n"
        out += sec("Mis PRs listos para pedirle la aprobación al TL", A)
        out += sec("Mis PRs: vuelven primero al compañero (commits después de su approve)", B)
        out += sec("Mis PRs sin approve vigente del compañero", C)
        out += sec("Mis PRs por atender antes (observados, conflictos o CI)", F)
        out += sec("PRs que revisé y aprobé: falta la aprobación del TL", D)
        out += sec("PRs que revisé pero tuvieron commits nuevos: me toca re-review primero", E)
        if (tlOk) out += "\n(" + tlOk + " de mis PRs ya tienen la aprobación del TL y no se listan)\n"
        return out.trim()
    }
    function copyApprovals() {
        if (tlLogin === "") { showToast("Pon el login de GitHub de tu TL en \"tlLogin\" de ~/.config/pr-tracker/config.json"); return }
        clip.text = approvalSummary(); clip.selectAll(); clip.copy()
        showToast("Resumen de aprobaciones copiado")
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
    function reviewCode(account, url, mode) {
        showToast("Preparando el código…")
        runner.connectSource(cli + " review " + q(account) + " " + q(url) + " " + mode + " # " + Date.now())
    }
    function codeReview(account, url, who) {
        showToast("Abriendo la sesión de Claude…")
        runner.connectSource(cli + " codereview " + q(account) + " " + q(url) + " " + who + " # " + Date.now())
    }
    function resolveConflicts(account, url) {
        showToast("Preparando el merge…")
        runner.connectSource(cli + " resolve " + q(account) + " " + q(url) + " # " + Date.now())
    }
    function startBatch(count) {
        const list = batchPending.slice().reverse().slice(0, count)   // primero los que más esperan
        if (list.length === 0) return
        batchConfirm = false
        runner.connectSource(cli + " batch " + list.map(p => q(p.account) + " " + q(p.url)).join(" ") + " # " + Date.now())
    }
    function stopBatch() { runner.connectSource(cli + " batch-stop # " + Date.now()) }
    function openDraft(path) { runner.connectSource("code " + q(path) + " # " + Date.now()) }
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
            else if (source.indexOf(" review ") >= 0) { root.showToast(out); }
            else if (source.indexOf(" codereview ") >= 0) { root.showToast(out); }
            else if (source.indexOf(" resolve ") >= 0) { root.showToast(out); }
            else if (source.indexOf(" batch ") >= 0) { root.showToast(out); root.refresh() }
            else if (source.indexOf(" batch-stop ") >= 0) { root.showToast(out); root.refresh() }
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
                root.reviews = r.reviews || ({})
                root.batchRunning = r.batchRunning === true
                root.merged = r.merged || []
                root.reviewed = r.reviewed || []
                root.reviewedDays = r.reviewedDays || 14
                root.tlLogin = r.tlLogin || ""
                root.mineView = r.mineView || []
                root.groups = r.groups || []
                const gm = {}
                for (const g of root.groups) gm[g.id] = g
                root.groupById = gm
                root.mergedDays = r.mergedDays || 5
                root.watching = r.watching || []
                root.jiraOn = r.jira === true
                root.accountCount = r.accounts ? r.accounts.length : 1
                root.failedAccounts = r.failed ? r.failed : []
                root.notifyChanges(r.prs)
                root.notifyExtras(r)
                root.refreshTabs()
                root.errorMsg = r.error ? r.error : ""
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }

    Timer { interval: 150000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    // Mientras corre un lote, el progreso se actualiza cada 15 s
    Timer { interval: 15000; running: root.batchRunning; repeat: true; onTriggered: root.refresh() }

    function subtitleOf(p) {
        let parts = []
        if (p.role) parts.push(p.role)
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
                Repeater {
                    model: root.tabKeys
                    delegate: PlasmaComponents.TabButton {
                        text: root.titleOf(modelData)
                        onClicked: root.selectedKey = modelData
                    }
                }
                // Al cambiar las pestañas, la barra se reconstruye: volver a marcar la activa.
                Connections {
                    target: root
                    function onTabKeysChanged() {
                        Qt.callLater(() => { tabs.currentIndex = root.tabKeys.indexOf(root.activeTab) })
                    }
                }
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

        Item {
            Layout.fillWidth: true; Layout.fillHeight: true

            // ---------- Mis PRs ----------
            ColumnLayout {
                anchors.fill: parent
                visible: root.activeTab === "mine"
                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Button {
                        icon.name: "emblem-approved"
                        text: "Pendientes de aprobación"
                        enabled: root.prs.length > 0 || root.reviewed.length > 0
                        onClicked: root.copyApprovals()
                        PlasmaComponents.ToolTip { text: "Copia qué PRs (míos y los que revisé) esperan re-review del compañero o la aprobación del TL" }
                    }
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
                        model: root.mineView
                        spacing: Kirigami.Units.smallSpacing
                        section.property: "sec"
                        section.delegate: Item {
                            id: sec
                            required property string section
                            readonly property var g: section.startsWith("g:") ? root.groupById[section.substring(2)] : null
                            width: ListView.view ? ListView.view.width : 0
                            implicitHeight: secCol.implicitHeight + Kirigami.Units.smallSpacing * 3
                            height: implicitHeight
                            Rectangle {
                                visible: sec.g !== null && sec.g !== undefined
                                anchors.fill: parent; anchors.topMargin: Kirigami.Units.smallSpacing
                                radius: Kirigami.Units.cornerRadius
                                color: sec.g ? (sec.g.tone === "bad" ? "#e5484d" : sec.g.tone === "ok" ? "#2da44e" : "#d98e04") : "transparent"
                                opacity: 0.14
                            }
                            ColumnLayout {
                                id: secCol
                                anchors { left: parent.left; right: parent.right; top: parent.top
                                    leftMargin: Kirigami.Units.smallSpacing; topMargin: Kirigami.Units.smallSpacing * 1.5 }
                                spacing: 0
                                Kirigami.Heading {
                                    level: 5; Layout.fillWidth: true; elide: Text.ElideRight
                                    text: sec.g ? "Cambio: " + sec.g.title + (sec.g.tickets.length ? "  (" + sec.g.tickets.join(", ") + ")" : "") : sec.section
                                    opacity: sec.g ? 1 : 0.7
                                }
                                Repeater {
                                    model: sec.g ? sec.g.warnings : []
                                    delegate: PlasmaComponents.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; font: Kirigami.Theme.smallFont
                                        text: modelData
                                        color: sec.g.tone === "bad" ? "#e5484d" : sec.g.tone === "ok" ? "#2da44e" : "#d98e04"
                                    }
                                }
                            }
                        }
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: root.subtitleOf(modelData)
                            showReReview: modelData.label.indexOf("re-review") >= 0 || modelData.status === "observado"
                            showReview: true
                            showConflicts: modelData.status === "conflicto"
                            onResolveConflicts: (account, url) => root.resolveConflicts(account, url)
                            codeReviewTip: "Autorreview con IA en el worktree de tu rama (no publica nada)"
                            onCodeReview: (account, url) => root.codeReview(account, url, "mio")
                            onReviewCode: (account, url) => root.reviewCode(account, url, "git")
                            onReviewTerm: (account, url) => root.reviewCode(account, url, "term")
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
                anchors.fill: parent
                visible: root.activeTab === "review"
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        Layout.fillWidth: true; elide: Text.ElideRight; opacity: 0.8; font: Kirigami.Theme.smallFont
                        text: root.batchRunning ? "Lote en curso: " + root.batchActive.length + " pendientes de " + root.review.length
                              : root.batchPending.length + " sin borrador al día"
                    }
                    PlasmaComponents.Button {
                        visible: !root.batchRunning
                        enabled: root.batchPending.length > 0
                        icon.name: "view-list-details"; text: "Review en lote…"
                        onClicked: { batchCount.value = root.batchPending.length; root.batchConfirm = !root.batchConfirm }
                    }
                    PlasmaComponents.Button {
                        visible: root.batchRunning
                        icon.name: "process-stop"; text: "Detener lote"
                        onClicked: root.stopBatch()
                    }
                }
                Rectangle {
                    visible: root.batchConfirm && !root.batchRunning
                    Layout.fillWidth: true
                    implicitHeight: batchBox.implicitHeight + Kirigami.Units.largeSpacing * 2
                    radius: Kirigami.Units.cornerRadius
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.07)
                    ColumnLayout {
                        id: batchBox
                        anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            text: "Se hace una primera pasada de code review de cada PR, en segundo plano y de a pocos a la vez. "
                                + "Deja un borrador por PR (sin build ni tests); no publica nada. Cada review consume tu uso de Claude: "
                                + "con muchos PRs puede ser bastante. Conviene probar primero con 2 o 3."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            PlasmaComponents.Label { text: "Cantidad (los que más llevan esperando primero):" }
                            PlasmaComponents.SpinBox { id: batchCount; from: 1; to: Math.max(1, root.batchPending.length); value: 3 }
                            Item { Layout.fillWidth: true }
                            PlasmaComponents.Button { text: "Cancelar"; onClicked: root.batchConfirm = false }
                            PlasmaComponents.Button { text: "Iniciar"; icon.name: "media-playback-start"; onClicked: root.startBatch(batchCount.value) }
                        }
                    }
                }
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.review
                        spacing: Kirigami.Units.smallSpacing
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: "de " + modelData.author + "  ·  " + modelData.repo + "  ·  hace " + modelData.ageDays + " d"
                                + (modelData.filesTotal > 0 ? "  ·  visto " + modelData.filesViewed + "/" + modelData.filesTotal : "")
                            showReview: true
                            reviewInfo: root.reviews[modelData.url] || null
                            onOpenDraft: path => root.openDraft(path)
                            codeReviewTip: "Code review con IA en una sesión de Claude (el borrador lo apruebas tú; no publica nada solo)"
                            onCodeReview: (account, url) => root.codeReview(account, url, "otros")
                            onReviewCode: (account, url) => root.reviewCode(account, url, "code")
                            onReviewTerm: (account, url) => root.reviewCode(account, url, "term")
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
                anchors.fill: parent
                visible: root.activeTab === "watch"
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

            // ---------- Revisados por mí ----------
            ColumnLayout {
                anchors.fill: parent
                visible: root.activeTab === "reviewed"
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.reviewed
                        spacing: Kirigami.Units.smallSpacing
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: (modelData.reviewedDaysAgo === 0 ? "hoy" : "hace " + modelData.reviewedDaysAgo + " d")
                                + "  ·  " + modelData.repo + " · @" + modelData.author
                                + (modelData.prState === "MERGED" ? "  ·  mergeado" : modelData.prState === "CLOSED" ? "  ·  cerrado" : "")
                                + (modelData.newCommits ? "  ·  hay commits nuevos desde tu review" : "")
                            onCopyLink: url => root.copyLink(url)
                            onOpenChecks: url => root.openChecks(url)
                        }
                    }
                }
            }

            // ---------- Mergeados (últimos días) ----------
            ColumnLayout {
                anchors.fill: parent
                visible: root.activeTab === "merged"
                PlasmaComponents.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.merged
                        spacing: Kirigami.Units.smallSpacing
                        delegate: PRRow {
                            width: ListView.view.width
                            pr: modelData; colors: root.colors; glyphs: root.glyphs
                            subtitle: (modelData.mergedDaysAgo === 0 ? "hoy" : "hace " + modelData.mergedDaysAgo + " d")
                                + "  ·  " + modelData.repo + " → " + modelData.base
                                + (modelData.ticket ? "  ·  " + modelData.ticket + (modelData.ticketStatus ? " · " + modelData.ticketStatus : "") : "")
                            onCopyLink: url => root.copyLink(url)
                            onOpenChecks: url => root.openChecks(url)
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.merged.length === 0
                    Layout.alignment: Qt.AlignHCenter
                    text: root.loading ? "Cargando…" : "Ningún PR mergeado en los últimos " + root.mergedDays + " días"
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
