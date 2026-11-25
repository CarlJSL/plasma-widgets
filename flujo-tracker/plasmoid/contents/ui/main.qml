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
    property string toast: ""
    property string view: "home"          // home | nuevo | pase | seguir | pases
    property string newKey: ""
    property string extraKeys: ""
    property var picked: ({})
    readonly property string cmd: "python3 $HOME/.local/bin/flujo"

    readonly property var phaseColor: ({ 1: "#8b949e", 2: "#8957e5", 3: "#2f81f7", 4: "#d98e04", 5: "#0ea5a5", 6: "#e5484d", 7: "#2da44e" })
    readonly property int observed: tickets.filter(t => t.next === "Aplicar las correcciones del review").length
    readonly property var paseCandidates: tickets.filter(t => t.phase === 6 && !t.prd && t.type !== "Pase a producción")
    readonly property var myPases: tickets.filter(t => t.type === "Pase a producción")
    readonly property var paseKeys: {
        const a = Object.keys(picked).filter(k => picked[k])
        for (const k of extraKeys.split(/[\s,]+/)) if (/^[A-Za-z]+-\d+$/.test(k) && a.indexOf(k.toUpperCase()) < 0) a.push(k.toUpperCase())
        return a
    }

    readonly property string phraseNuevo: "Nuevo ticket " + (newKey.trim() !== "" ? newKey.trim().toUpperCase() : "<CLAVE>") +
        ". Léelo por MCP con descripción, criterios y todos los comentarios. Crea su carpeta en Obsidian (vista previa primero), " +
        "completa el snapshot de Jira y redacta analisis.md en solo lectura."
    readonly property string phrasePase: "Arma el pase a prod de " + (paseKeys.length ? paseKeys.join(", ") : "<CLAVES>") +
        ". Revisa «Antes de armar la card», muéstrame el borrador y espera mi OK antes de crear nada en Jira o Slack."

    function title() {
        return ({ home: "¿Qué quieres hacer?", nuevo: "Empezar un ticket nuevo", pase: "Crear un pase a producción",
                  seguir: "Seguir con un ticket", pases: "Mis pases a producción" })[view]
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
                if (!r.error) root.tickets = r.tickets
            } catch (e) { root.errorMsg = data["stderr"] || String(e) }
        }
    }
    Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    // ---- copiar ----
    TextEdit { id: clip; visible: false }
    function copyText(t, msg) { clip.text = t; clip.selectAll(); clip.copy(); showToast(msg) }
    Timer { id: toastTimer; interval: 3000; onTriggered: root.toast = "" }
    function showToast(t) { toast = t; toastTimer.restart() }

    Plasmoid.icon: "view-list-tree"
    toolTipMainText: "Flujo de tickets"
    toolTipSubText: errorMsg !== "" ? "⚠ " + errorMsg : tickets.length + " tickets · " + observed + " con review observado · " + paseCandidates.length + " listos para pase"

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            width: parent.width * 0.82; height: width
            anchors { left: parent.left; top: parent.top }
            source: "view-list-tree"; isMask: true; color: Kirigami.Theme.textColor
        }
        Rectangle {
            visible: root.tickets.length > 0
            anchors { right: parent.right; bottom: parent.bottom }
            height: Math.max(14, parent.height * 0.5)
            width: Math.max(height, badge.implicitWidth + 4)
            radius: height / 2
            color: root.observed > 0 ? "#e5484d" : "#2f81f7"
            Text { id: badge; anchors.centerIn: parent; text: root.tickets.length
                color: "white"; font.pixelSize: Math.max(10, parent.height * 0.72); font.bold: true; font.family: "DejaVu Sans" }
        }
        Rectangle {
            visible: root.errorMsg !== ""
            anchors { right: parent.right; top: parent.top }
            width: Math.max(12, parent.height * 0.4); height: width; radius: width / 2
            color: "#d98e04"
            Text { anchors.centerIn: parent; text: "!"; color: "white"; font.bold: true; font.pixelSize: parent.height * 0.8; font.family: "DejaVu Sans" }
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 34
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30
        spacing: Kirigami.Units.smallSpacing

        // ---- cabecera ----
        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.ToolButton {
                visible: root.view !== "home"
                icon.name: "go-previous"; text: "Inicio"
                onClicked: root.view = "home"
            }
            Kirigami.Heading { level: 3; text: root.title(); Layout.fillWidth: true; elide: Text.ElideRight }
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

        // ================= INICIO =================
        ColumnLayout {
            visible: root.view === "home"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing
            ActionCard {
                iconName: "document-new"; title: "Empezar un ticket nuevo"
                subtitle: "Claude lee el ticket, crea su carpeta en Obsidian y arma el análisis y el plan. Se detiene antes de tocar código."
                onClicked: root.view = "nuevo"
            }
            ActionCard {
                iconName: "go-up"
                title: "Crear un pase a producción" + (root.paseCandidates.length ? "  (" + root.paseCandidates.length + " listos)" : "")
                subtitle: "Eliges los tickets a liberar y Claude arma la card PRD, la revisa contigo y pide las aprobaciones."
                onClicked: root.view = "pase"
            }
            ActionCard {
                iconName: "view-list-details"
                title: "Seguir con un ticket" + (root.observed ? "  (" + root.observed + " con review observado)" : "")
                subtitle: "Tus tickets por fase, con lo que toca hacer en cada uno."
                onClicked: root.view = "seguir"
            }
            ActionCard {
                iconName: "emblem-ok-symbolic"
                title: "Mis pases a producción" + (root.myPases.length ? "  (" + root.myPases.length + ")" : "")
                subtitle: "Cómo van los pases que pediste: estado y link."
                onClicked: root.view = "pases"
            }
            Item { Layout.fillHeight: true }
            PlasmaComponents.Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.6; font: Kirigami.Theme.smallFont
                text: "Este widget no ejecuta nada: te da el comando y la frase para pegar en la terminal. Claude siempre te muestra lo que va a hacer y espera tu OK antes de publicar."
            }
        }

        // ================= TICKET NUEVO =================
        PlasmaComponents.ScrollView {
            id: svNuevo
            visible: root.view === "nuevo"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            ColumnLayout {
                width: svNuevo.availableWidth - Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing
                PlasmaComponents.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.75
                    text: "Úsalo cuando te asignan un ticket y todavía no tiene carpeta en Obsidian." }
                PlasmaComponents.TextField {
                    Layout.fillWidth: true
                    placeholderText: "Clave del ticket, por ejemplo ASDT-500"
                    text: root.newKey; onTextChanged: root.newKey = text
                }
                Step { number: 1; text: "Abre una terminal y pega este comando:"; code: "ticket --agent nuevo-ticket"
                    buttonText: "Copiar comando"; onCopy: root.copyText("ticket --agent nuevo-ticket", "Comando copiado: pégalo en la terminal") }
                Step { number: 2; text: "Cuando Claude abra, pega esta frase:"; code: root.phraseNuevo
                    buttonText: "Copiar frase"; onCopy: root.copyText(root.phraseNuevo, "Frase copiada: pégala en Claude") }
                Step { number: 3; text: "Qué pasará: Claude lee el ticket y sus comentarios, te muestra la carpeta de Obsidian antes de crearla, redacta el análisis (solo lectura), calcula el peso y arma el plan. Te pide OK en cada acción y se detiene en «OK, pasa a implementación»." }
            }
        }

        // ================= PASE A PRODUCCIÓN =================
        PlasmaComponents.ScrollView {
            id: svPase
            visible: root.view === "pase"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            ColumnLayout {
                width: svPase.availableWidth - Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing
                PlasmaComponents.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.75
                    text: "Un pase puede liberar varios tickets juntos. Marca los que van en este pase." }
                Kirigami.Heading { level: 5; text: root.paseCandidates.length ? "Listos para pase (READY TO DEPLOY, sin pase vinculado)" : "No tienes tickets listos para pase en Jira"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                Repeater {
                    model: root.paseCandidates
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents.CheckBox {
                            Layout.alignment: Qt.AlignTop
                            checked: root.picked[modelData.key] === true
                            onToggled: { const n = Object.assign({}, root.picked); n[modelData.key] = checked; root.picked = n }
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            text: "<b>" + modelData.key + "</b> · " + modelData.summary
                            textFormat: Text.StyledText
                        }
                    }
                }
                PlasmaComponents.TextField {
                    Layout.fillWidth: true
                    placeholderText: "Otras claves a incluir (separadas por coma), por ejemplo MC-1274"
                    text: root.extraKeys; onTextChanged: root.extraKeys = text
                }
                Step { number: 1; text: "Abre una terminal y pega este comando:"; code: "ticket --agent pase"
                    buttonText: "Copiar comando"; onCopy: root.copyText("ticket --agent pase", "Comando copiado: pégalo en la terminal") }
                Step { number: 2; text: "Cuando Claude abra, pega esta frase" + (root.paseKeys.length ? "" : " (marca antes algún ticket)") + ":"; code: root.phrasePase
                    buttonText: "Copiar frase"; onCopy: root.copyText(root.phrasePase, "Frase copiada: pégala en Claude") }
                Step { number: 3; text: "Qué comprobará antes de armar la card: QA aprobado, PRs mergeados en qas, despliegues a qas en verde, feature flag, migraciones y variables nuevas. Si falta algo bloqueante, te lo dice y no crea nada." }
                Step { number: 4; text: "Después te muestra el borrador de las 9 secciones. Con tu OK, y uno por uno: crea el PRD, vincula los tickets con «implements», crea la página de seguridad de Confluence, y pide la aprobación a Jorge y al TL (o a Gian si el desarrollo lo hizo un TL)." }
            }
        }

        // ================= SEGUIR CON UN TICKET =================
        PlasmaComponents.ScrollView {
            id: svSeguir
            visible: root.view === "seguir"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            ListView {
                model: root.tickets
                spacing: Kirigami.Units.smallSpacing
                section.property: "phaseName"
                section.delegate: Kirigami.Heading {
                    required property string section
                    level: 4; topPadding: Kirigami.Units.gridUnit * 0.6
                    text: section
                }
                delegate: ColumnLayout {
                    id: tk
                    required property var modelData
                    width: svSeguir.availableWidth - Kirigami.Units.largeSpacing
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        Rectangle { Layout.fillHeight: true; implicitWidth: 3; radius: 2; color: root.phaseColor[tk.modelData.phase] || "#8b949e" }
                        PlasmaComponents.Label { text: tk.modelData.key; font.bold: true }
                        PlasmaComponents.Label { Layout.fillWidth: true; text: tk.modelData.summary; elide: Text.ElideRight }
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap
                        text: "Ahora: " + tk.modelData.detail + "  ·  Toca: " + tk.modelData.next
                        opacity: 0.7; font: Kirigami.Theme.smallFont
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: tk.modelData.launch.cmds
                            delegate: PlasmaComponents.Button {
                                required property var modelData
                                icon.name: "utilities-terminal"
                                text: tk.modelData.launch.cmds.length > 1 ? "Comando · " + modelData.label.replace(/-io$/, "") : "Comando"
                                onClicked: root.copyText(modelData.cmd, "Terminal: " + modelData.cmd)
                            }
                        }
                        PlasmaComponents.Button {
                            icon.name: "view-conversation-balloon"; text: "Frase"
                            onClicked: root.copyText(tk.modelData.launch.phrase, "Frase copiada: pégala en Claude")
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "internet-services"
                            onClicked: Qt.openUrlExternally(tk.modelData.url)
                            PlasmaComponents.ToolTip { text: "Abrir en Jira" }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Kirigami.Theme.textColor; opacity: 0.08 }
                }
            }
        }

        // ================= MIS PASES =================
        PlasmaComponents.ScrollView {
            id: svPases
            visible: root.view === "pases"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            ColumnLayout {
                width: svPases.availableWidth - Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { visible: root.myPases.length === 0; Layout.fillWidth: true; wrapMode: Text.Wrap
                    text: "No tienes pases abiertos asignados en Jira." }
                Repeater {
                    model: root.myPases
                    delegate: PlasmaComponents.ItemDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        onClicked: Qt.openUrlExternally(modelData.url)
                        contentItem: ColumnLayout {
                            spacing: 1
                            RowLayout {
                                PlasmaComponents.Label { text: modelData.key; font.bold: true }
                                Rectangle { radius: 3; color: "#d98e04"; implicitWidth: st.implicitWidth + 8; implicitHeight: st.implicitHeight + 2
                                    Text { id: st; anchors.centerIn: parent; text: modelData.status; color: "white"; font.bold: true; font.pixelSize: Kirigami.Theme.smallFont.pixelSize } }
                            }
                            PlasmaComponents.Label { Layout.fillWidth: true; text: modelData.summary; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                        }
                    }
                }
                PlasmaComponents.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.6; font: Kirigami.Theme.smallFont
                    text: "Estados: Por hacer → En aprobación → Ready to deploy → Terminado. Clic en un pase para abrirlo en Jira." }
            }
        }

        PlasmaComponents.Label {
            visible: root.toast !== ""
            Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap; text: root.toast; font.bold: true; color: Kirigami.Theme.positiveTextColor
        }
    }
}
