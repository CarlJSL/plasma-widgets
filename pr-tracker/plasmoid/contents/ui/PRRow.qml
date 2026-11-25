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
    property bool showConflicts: false
    property string codeReviewTip: ""
    property var reviewInfo: null   // estado del review en lote: {status, draft, error}
    signal openDraft(string path)
    property bool alwaysShowActions: false
    property string extraIcon: ""
    property string extraTip: ""

    // Quién ya revisó el PR (y si su review sigue vigente) y a quién se le pidió y no ha respondido.
    readonly property var chips: {
        const out = [], seen = {}
        const me = pr.account
        const MES = ["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"]
        const fecha = iso => { if (!iso) return ""; const d = new Date(iso); return d.getDate() + " " + MES[d.getMonth()] }
        for (const r of (pr.reviews || [])) {
            seen[r.login] = true
            const quien = r.login === me ? "tú" : "@" + r.login
            const t = ({ APPROVED: ["✓", "aprobó", "#2da44e"], CHANGES_REQUESTED: ["✗", "pidió cambios", "#e5484d"],
                         COMMENTED: ["•", "comentó", "#8b949e"], DISMISSED: ["•", "review descartado", "#8b949e"] })[r.state]
            if (!t) continue
            const tip = quien + " " + t[1] + (r.at ? " el " + fecha(r.at) : "")
                + (r.current ? ", sobre el último commit." : ". Hubo commits después de ese review: ya no cuenta.")
            out.push({ text: t[0] + " " + quien + (r.current ? "" : " · viejo"), color: t[2], faded: !r.current, tip: tip })
        }
        for (const l of (pr.requested || [])) {
            if (!l || seen[l] || l === me) continue
            out.push({ text: "○ " + l + " pendiente", color: "#8b949e", faded: false, tip: "Se le pidió review a " + l + " y todavía no responde." })
        }
        return out
    }

    signal copyLink(string url)
    signal openChecks(string url)
    signal reReview(string account, string url)
    signal extra(string url)
    signal reviewCode(string account, string url)
    signal reviewTerm(string account, string url)
    signal codeReview(string account, string url)
    signal resolveConflicts(string account, string url)

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
                    visible: !!row.reviewInfo
                    text: !row.reviewInfo ? "" : ({ queued: "en cola", running: "revisando…", done: "borrador listo",
                                                     error: "review falló" })[row.reviewInfo.status] || ""
                    color: !row.reviewInfo ? "" : ({ queued: "#8b949e", running: "#2f81f7", done: "#2da44e", error: "#e5484d" })[row.reviewInfo.status] || "#8b949e"
                    font: Kirigami.Theme.smallFont
                }
                PlasmaComponents.Label {
                    visible: row.pr.stale === true
                    text: "sin movimiento " + row.pr.idleDays + " d"
                    color: "#d98e04"; font: Kirigami.Theme.smallFont
                }
            }
            Flow {
                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                visible: row.chips.length > 0
                Repeater {
                    model: row.chips
                    delegate: Rectangle {
                        radius: height / 2
                        height: chipLabel.implicitHeight + 2
                        width: chipLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                        color: Qt.rgba(Qt.color(modelData.color).r, Qt.color(modelData.color).g, Qt.color(modelData.color).b, 0.18)
                        border { width: 1; color: Qt.rgba(Qt.color(modelData.color).r, Qt.color(modelData.color).g, Qt.color(modelData.color).b, 0.55) }
                        opacity: modelData.faded ? 0.6 : 1
                        PlasmaComponents.Label {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: modelData.text; font: Kirigami.Theme.smallFont
                            color: modelData.color
                        }
                        HoverHandler { id: chipHover }
                        PlasmaComponents.ToolTip { visible: chipHover.hovered; text: modelData.tip }
                    }
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
                visible: row.showConflicts
                icon.name: "vcs-merge"; onClicked: row.resolveConflicts(row.pr.account, row.pr.url)
                PlasmaComponents.ToolTip { text: "Resolver conflictos: abre su worktree, VS Code y Claude con las instrucciones" }
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
                visible: !!row.reviewInfo && row.reviewInfo.status === "done"
                icon.name: "document-open"; onClicked: row.openDraft(row.reviewInfo.draft)
                PlasmaComponents.ToolTip { text: "Abrir el borrador del review en VS Code" }
            }
            PlasmaComponents.ToolButton {
                visible: row.codeReviewTip !== ""
                icon.name: "dialog-ok-apply"; onClicked: row.codeReview(row.pr.account, row.pr.url)
                PlasmaComponents.ToolTip { text: row.codeReviewTip }
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
