import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "dank-translate-ai-history"
    readonly property var historyEntries: Array.isArray(globalHistory.value) ? globalHistory.value : []
    readonly property bool translating: globalStatus.value === "running"
    readonly property bool uiZh: String(pluginData?.uiLanguage ?? "en") === "zh"
    readonly property real pillPadding: (barConfig?.removeWidgetPadding ?? false)
        ? 0
        : Theme.snap((barConfig?.widgetPadding ?? 12) * (widgetThickness / 30),
                     parentScreen ? CompositorService.getScreenScale(parentScreen) : 1)

    function t(en, zh) {
        return uiZh ? zh : en;
    }

    PluginGlobalVar {
        id: globalHistory
        varName: "history"
        defaultValue: []
    }

    PluginGlobalVar {
        id: globalStatus
        varName: "status"
        defaultValue: "idle"
    }

    PluginGlobalVar {
        id: globalClipboardWriteAt
        varName: "clipboardWriteAt"
        defaultValue: 0
    }

    function formatTime(timestamp) {
        const date = new Date(Number(timestamp || 0));
        return Qt.formatDateTime(date, "yyyy-MM-dd  HH:mm:ss");
    }

    function copyText(text, label) {
        const content = String(text || "");
        if (!content)
            return;
        globalClipboardWriteAt.set(Date.now());
        Quickshell.execDetached(["dms", "cl", "copy", content]);
        ToastService.showInfo(label || t("Copied", "已复制"));
    }

    function clearHistory() {
        globalHistory.set([]);
        if (pluginService)
            pluginService.savePluginState(pluginId, "history", []);
        ToastService.showInfo(t("History cleared", "历史已清空"));
    }

    function removeHistory(entryId) {
        const filtered = historyEntries.filter(entry => String(entry.id) !== String(entryId));
        globalHistory.set(filtered);
        if (pluginService)
            pluginService.savePluginState(pluginId, "history", filtered);
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: barIcon.width
            implicitHeight: Math.max(0, root.widgetThickness - root.pillPadding * 2)
            width: implicitWidth
            height: implicitHeight

            DankIcon {
                id: barIcon
                anchors.centerIn: parent
                name: root.translating ? "progress_activity" : "translate"
                size: root.iconSize
                color: root.translating ? Theme.primary : Theme.surfaceText
                rotation: 0
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: verticalIcon.width
            implicitHeight: Math.max(0, root.widgetThickness - root.pillPadding * 2)
            width: implicitWidth
            height: implicitHeight

            DankIcon {
                id: verticalIcon
                anchors.centerIn: parent
                name: root.translating ? "progress_activity" : "translate"
                size: root.iconSize
                color: root.translating ? Theme.primary : Theme.surfaceText
                rotation: 0
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: historyPopout
            headerText: root.t("History", "翻译历史")
            detailsText: root.uiZh
                ? root.historyEntries.length + " 条 · 最新优先"
                : root.historyEntries.length + " · newest first"
            showCloseButton: true

            headerActions: Component {
                DankActionButton {
                    visible: root.historyEntries.length > 0
                    iconName: "delete_sweep"
                    iconColor: Theme.surfaceText
                    tooltipText: root.t("Clear", "清空")
                    onClicked: root.clearHistory()
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight
                    - historyPopout.headerHeight
                    - historyPopout.detailsHeight
                    - Theme.spacingXL

                StyledText {
                    anchors.centerIn: parent
                    visible: root.historyEntries.length === 0
                    text: root.t("No history\nSelect text and press the shortcut", "暂无历史\n划词后按快捷键")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                    horizontalAlignment: Text.AlignHCenter
                    lineHeight: 1.4
                }

                DankListView {
                    id: historyList
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    visible: root.historyEntries.length > 0
                    clip: true
                    spacing: Theme.spacingS
                    model: root.historyEntries

                    delegate: StyledRect {
                        id: entryCard
                        required property var modelData

                        width: historyList.width
                        height: entryColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: entryMouse.containsMouse
                            ? Theme.surfaceContainerHighest
                            : Theme.surfaceContainerHigh
                        border.width: 1
                        border.color: Theme.outlineMedium

                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyText(entryCard.modelData.translated, root.t("Copied", "已复制"))
                        }

                        Column {
                            id: entryColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: Math.max(timeText.implicitHeight, actionRow.implicitHeight)

                                StyledText {
                                    id: timeText
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.formatTime(entryCard.modelData.createdAt)
                                        + "  ·  "
                                        + String(entryCard.modelData.language || "")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                    width: Math.max(0, parent.width - actionRow.width - Theme.spacingS)
                                }

                                Row {
                                    id: actionRow
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    z: 2

                                    DankActionButton {
                                        buttonSize: 30
                                        iconSize: Theme.iconSizeSmall
                                        iconName: "content_copy"
                                        tooltipText: root.t("Copy source", "复制原文")
                                        onClicked: root.copyText(entryCard.modelData.original, root.t("Source copied", "原文已复制"))
                                    }

                                    DankActionButton {
                                        buttonSize: 30
                                        iconSize: Theme.iconSizeSmall
                                        iconName: "delete"
                                        tooltipText: root.t("Delete", "删除")
                                        onClicked: root.removeHistory(entryCard.modelData.id)
                                    }
                                }
                            }

                            StyledText {
                                width: parent.width
                                text: String(entryCard.modelData.original || "")
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineMedium
                            }

                            StyledText {
                                width: parent.width
                                text: String(entryCard.modelData.translated || "")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
                                maximumLineCount: 5
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                visible: String(entryCard.modelData.model || "").length > 0
                                text: String(entryCard.modelData.model || "")
                                color: Theme.outlineButton
                                font.pixelSize: Theme.fontSizeSmall
                                elide: Text.ElideMiddle
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 540
    popoutHeight: 580
}
