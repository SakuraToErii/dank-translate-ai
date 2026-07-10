import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property bool uiZh: String(pluginData?.uiLanguage ?? "en") === "zh"
    readonly property string defaultPrompt: "Translate the user's text into ${target_lang}. Preserve meaning, tone, paragraphs, Markdown, code, names, and numbers. Output only the translation."
    readonly property string pluginPath: pluginService ? pluginService.getPluginPath(pluginId) : ""
    readonly property string helperPath: pluginPath ? pluginPath + "/translate_stream.py" : ""
    readonly property string captureHelperPath: pluginPath ? pluginPath + "/capture_selection.py" : ""
    readonly property int maxInputChars: 100000
    readonly property int clipboardFreshnessMs: 60000
    readonly property int selfCopyMatchMs: 3000

    property bool initialized: false
    property bool popupVisible: false
    property var popupScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    property var activeCapture: null
    property var activeProcess: null
    property string currentOriginal: ""
    property string currentTranslation: ""
    property string currentError: ""
    property string currentStatus: "idle"
    property string currentLanguage: "Chinese (Simplified)"
    property int inputRequestSerial: 0
    property bool inputBaselineReady: false
    property string lastClipboardEntryId: ""
    property string lastPrimarySnapshot: ""
    property string pendingInputMode: "selection"

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
        id: globalOriginal
        varName: "original"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: globalTranslation
        varName: "translation"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: globalError
        varName: "error"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: globalClipboardWriteAt
        varName: "clipboardWriteAt"
        defaultValue: 0
    }

    Timer {
        id: inputDebounceTimer
        interval: 250
        repeat: false
        onTriggered: {
            const requestSerial = root.inputRequestSerial;
            if (root.pendingInputMode === "clipboard")
                root.resolveClipboardInput(requestSerial);
            else
                root.resolveSelectionInput(requestSerial);
        }
    }

    function initialize() {
        if (initialized || !pluginService || !pluginId)
            return;
        let saved = pluginService.loadPluginState(pluginId, "history", []);
        if (!Array.isArray(saved))
            saved = [];
        saved = saved.slice().sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0));
        globalHistory.set(saved);
        globalStatus.set("idle");
        globalOriginal.set("");
        globalTranslation.set("");
        globalError.set("");
        initialized = true;
        trimHistory();
    }

    Component.onCompleted: Qt.callLater(initialize)
    onPluginServiceChanged: Qt.callLater(initialize)

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.trimHistory();
        }
    }

    function historyLimit() {
        const parsed = Number(pluginData?.historyLimit ?? 100);
        return Math.max(20, Math.min(isNaN(parsed) ? 100 : Math.round(parsed), 500));
    }

    function trimHistory() {
        if (!initialized)
            return;
        const history = Array.isArray(globalHistory.value) ? globalHistory.value.slice() : [];
        const trimmed = history.slice(0, historyLimit());
        if (trimmed.length !== history.length) {
            globalHistory.set(trimmed);
            pluginService.savePluginState(pluginId, "history", trimmed);
        }
    }

    function syncCurrentState() {
        globalStatus.set(currentStatus);
        globalOriginal.set(currentOriginal);
        globalTranslation.set(currentTranslation);
        globalError.set(currentError);
    }

    function showPopup() {
        popupScreen = CompositorService.getFocusedScreen();
        popupVisible = true;
    }

    function closePopup() {
        popupVisible = false;
    }

    function presentError(message, originalText) {
        currentOriginal = originalText || "";
        currentTranslation = "";
        currentError = String(message || t("Translation failed", "翻译失败"));
        currentStatus = "error";
        syncCurrentState();
        showPopup();
    }

    function beginSelectionTranslation() {
        scheduleInput("selection");
    }

    function beginClipboardTranslation() {
        scheduleInput("clipboard");
    }

    function scheduleInput(mode) {
        ++inputRequestSerial;
        pendingInputMode = mode;
        if (activeCapture) {
            activeCapture.signal(15);
            activeCapture = null;
        }
        inputDebounceTimer.restart();
    }

    function resolveSelectionInput(requestSerial) {
        resolveClipboardState(state => {
            if (requestSerial !== inputRequestSerial)
                return;
            const clipboardChanged = state.entry
                && (!inputBaselineReady || state.currentId !== lastClipboardEntryId);
            if (clipboardChanged) {
                captureText(false, true, state.currentId, "input", "");
                return;
            }
            captureText(true, true, state.currentId, "input", "");
        });
    }

    function resolveClipboardInput(requestSerial) {
        resolveClipboardState(state => {
            if (requestSerial !== inputRequestSerial)
                return;
            const clipboardChanged = state.entry
                && (!inputBaselineReady || state.currentId !== lastClipboardEntryId);
            if (clipboardChanged) {
                captureText(false, true, state.currentId, "input", "");
                return;
            }
            if (inputBaselineReady)
                return;
            presentError(
                t("Select or copy text first.", "请先划词或复制文本。"),
                ""
            );
        });
    }

    function isTextClipboardEntry(entry) {
        if (!entry || entry.isImage)
            return false;
        const mime = String(entry.mimeType || "").toLowerCase();
        return mime.startsWith("text/plain")
            || mime === "text"
            || mime === "string"
            || mime === "utf8_string";
    }

    function isOwnClipboardWrite(timestamp) {
        const writtenAt = Number(globalClipboardWriteAt.value || 0);
        return writtenAt > 0 && Math.abs(timestamp - writtenAt) <= selfCopyMatchMs;
    }

    function resolveClipboardState(callback) {
        if (!DMSService.isConnected) {
            callback({ entry: null, currentId: "" });
            return;
        }
        DMSService.sendRequest("clipboard.search", {
            query: "",
            limit: 1,
            offset: 0
        }, response => {
            if (response.error) {
                callback({ entry: null, currentId: "" });
                return;
            }
            const entries = response.result?.entries || [];
            const entry = entries.length > 0 ? entries[0] : null;
            const currentId = entry ? String(entry.id ?? "") : "";
            const timestamp = entry ? Date.parse(String(entry.timestamp || "")) : NaN;
            const age = Date.now() - timestamp;
            const fresh = !isNaN(timestamp)
                && age >= -selfCopyMatchMs
                && age <= clipboardFreshnessMs;
            callback({
                entry: fresh && isTextClipboardEntry(entry) && !isOwnClipboardWrite(timestamp)
                    ? entry
                    : null,
                currentId: currentId
            });
        });
    }

    function captureText(primarySelection, smartInput, clipboardEntryId, captureRole, pendingText) {
        if (activeCapture) {
            activeCapture.signal(15);
            activeCapture = null;
        }
        const reader = selectionReaderComponent.createObject(root, {
            primarySelection: primarySelection,
            smartInput: !!smartInput,
            clipboardEntryId: String(clipboardEntryId || ""),
            captureRole: String(captureRole || "input"),
            pendingText: String(pendingText || "")
        });
        activeCapture = reader;
        reader.running = true;
    }

    function onCaptured(reader, exitCode) {
        if (reader !== activeCapture)
            return;
        activeCapture = null;
        const text = String(reader.capturedText || "").trim();
        console.info("[DankTranslateAI] selection capture:", reader.primarySelection ? "primary" : "clipboard", "exit", exitCode, "chars", text.length);

        if (reader.captureRole === "clipboardBaseline") {
            lastPrimarySnapshot = exitCode === 0 ? text : "";
            lastClipboardEntryId = reader.clipboardEntryId;
            inputBaselineReady = true;
            startTranslation(reader.pendingText);
            return;
        }

        if (exitCode === 0 && text.length > 0) {
            if (!reader.primarySelection) {
                captureText(
                    true,
                    true,
                    reader.clipboardEntryId,
                    "clipboardBaseline",
                    text
                );
                return;
            }

            const unchanged = inputBaselineReady
                && text === lastPrimarySnapshot
                && reader.clipboardEntryId === lastClipboardEntryId;
            lastPrimarySnapshot = text;
            lastClipboardEntryId = reader.clipboardEntryId;
            if (unchanged)
                return;
            inputBaselineReady = true;
            startTranslation(text);
            return;
        }

        if (reader.primarySelection && reader.smartInput && inputBaselineReady) {
            lastPrimarySnapshot = "";
            lastClipboardEntryId = reader.clipboardEntryId;
            return;
        }
        if (exitCode === 6) {
            presentError(
                t(
                    "Clipboard may contain a password or key. Automatic translation was blocked.",
                    "剪贴板疑似包含密码或密钥，已阻止自动翻译。"
                ),
                ""
            );
            return;
        }
        if (exitCode === 2) {
            if (reader.smartInput) {
                presentError(
                    t(
                        "No translatable text in the selection or clipboard.",
                        "鼠标选区和剪贴板中没有可翻译文本。"
                    ),
                    ""
                );
            } else {
                presentError(
                    reader.primarySelection
                        ? t("Selection is not plain text.", "选区不是纯文本。")
                        : t("Clipboard is not plain text.", "剪贴板不是纯文本。"),
                    ""
                );
            }
            return;
        }
        if (exitCode === 3) {
            presentError(t("Text exceeds 100k characters.", "文本超过 10 万字符。"), "");
            return;
        }
        if (reader.smartInput) {
            presentError(
                t("Select or copy text first.", "请先划词或复制文本。"),
                ""
            );
            return;
        }
        const sourceName = reader.primarySelection ? t("selection", "鼠标主选区") : t("clipboard", "剪贴板");
        presentError(t("No text in " + sourceName + ".", "未读取到" + sourceName + "文本。"), "");
    }

    function resolvedTargetLanguage() {
        const selected = String(pluginData?.targetLanguage ?? "Chinese (Simplified)");
        if (selected === "__custom__")
            return String(pluginData?.customTargetLanguage ?? "").trim();
        return selected;
    }

    function startTranslation(sourceText) {
        const text = String(sourceText || "").trim();
        if (!text) {
            presentError(t("Selection is empty.", "划词内容为空。"), "");
            return;
        }
        if (text.length > maxInputChars) {
            presentError(t("Text exceeds 100k characters.", "文本超过 10 万字符。"), "");
            return;
        }

        const targetLanguage = resolvedTargetLanguage();
        if (!targetLanguage) {
            presentError(t("Set a custom target language.", "请填写自定义目标语言。"), text);
            return;
        }

        cancelActive(false);
        currentOriginal = text;
        currentTranslation = "";
        currentError = "";
        currentStatus = "running";
        currentLanguage = targetLanguage;
        syncCurrentState();
        showPopup();

        const request = {
            base_url: String(pluginData?.baseUrl ?? "http://127.0.0.1:8080/v1"),
            endpoint: String(pluginData?.endpoint ?? "/chat/completions"),
            api_key: String(pluginData?.apiKey ?? ""),
            model: String(pluginData?.model ?? "tencent/Hy-MT2-1.8B-GGUF").trim(),
            target_lang: targetLanguage,
            prompt: String(pluginData?.prompt ?? defaultPrompt),
            stream: pluginData?.streaming ?? true,
            timeout: Number(pluginData?.timeoutSeconds ?? 120),
            ui_language: uiZh ? "zh" : "en",
            text: text
        };

        const process = translateProcessComponent.createObject(root, {
            requestData: request
        });
        activeProcess = process;
        process.running = true;
    }

    function handleProtocolLine(process, line) {
        if (process !== activeProcess || !line || !String(line).trim())
            return;

        let event;
        try {
            event = JSON.parse(String(line));
        } catch (error) {
            process.protocolNoise += String(line) + "\n";
            return;
        }

        switch (event.type) {
        case "delta":
            currentTranslation += String(event.text || "");
            globalTranslation.set(currentTranslation);
            break;
        case "done":
            process.gotDone = true;
            finishSuccess(process);
            break;
        case "error":
            process.protocolError = true;
            currentError = String(event.message || t("Translation failed", "翻译失败"));
            currentStatus = "error";
            syncCurrentState();
            break;
        }
    }

    function finishSuccess(process) {
        if (process.finishedHandled)
            return;
        process.finishedHandled = true;
        const translated = currentTranslation.trim();
        if (!translated) {
            process.protocolError = true;
            currentError = t("Empty translation.", "译文为空。")
            currentStatus = "error";
            syncCurrentState();
            return;
        }

        currentTranslation = translated;
        currentStatus = "done";
        currentError = "";
        syncCurrentState();
        addHistory(currentOriginal, currentTranslation, currentLanguage);
    }

    function onTranslationExited(process, exitCode) {
        const isCurrent = process === activeProcess;
        if (isCurrent)
            activeProcess = null;
        if (!isCurrent || process.cancelled)
            return;
        if (process.gotDone || process.finishedHandled || process.protocolError)
            return;
        if (exitCode === 0 && currentTranslation.trim()) {
            finishSuccess(process);
            return;
        }

        const details = (process.stderrText || process.protocolNoise || t("Translation process ended early.", "翻译进程提前结束。")).trim();
        currentError = details;
        currentStatus = "error";
        syncCurrentState();
    }

    function cancelActive(showStatus) {
        const process = activeProcess;
        if (!process)
            return;
        activeProcess = null;
        process.cancelled = true;
        process.signal(15);
        if (showStatus) {
            currentStatus = "cancelled";
            currentError = t("Stopped", "已停止");
            syncCurrentState();
        }
    }

    function addHistory(original, translated, language) {
        const now = Date.now();
        const entry = {
            id: String(now) + "-" + String(Math.floor(Math.random() * 1000000)),
            original: original,
            translated: translated,
            language: language,
            model: String(pluginData?.model ?? "tencent/Hy-MT2-1.8B-GGUF"),
            createdAt: now
        };
        let history = Array.isArray(globalHistory.value) ? globalHistory.value.slice() : [];
        history.unshift(entry);
        history = history.slice(0, historyLimit());
        globalHistory.set(history);
        pluginService.savePluginState(pluginId, "history", history);
    }

    function clearHistory() {
        globalHistory.set([]);
        if (pluginService)
            pluginService.savePluginState(pluginId, "history", []);
    }

    function removeHistoryEntry(entryId) {
        const history = Array.isArray(globalHistory.value) ? globalHistory.value : [];
        const filtered = history.filter(entry => String(entry.id) !== String(entryId));
        globalHistory.set(filtered);
        if (pluginService)
            pluginService.savePluginState(pluginId, "history", filtered);
    }

    function updateBarPlacement(section, shouldAdd) {
        const normalizedSection = ["left", "center", "right"].includes(section) ? section : "right";
        const propertyName = normalizedSection + "Widgets";
        const configs = Array.isArray(SettingsData.barConfigs) ? SettingsData.barConfigs : [];
        let changed = 0;

        for (const config of configs) {
            if (!(config?.enabled ?? true))
                continue;
            let widgets = Array.isArray(config[propertyName]) ? config[propertyName].slice() : [];
            const widgetId = widget => typeof widget === "string" ? widget : String(widget?.id || "");
            const existingIndex = widgets.findIndex(widget => widgetId(widget) === pluginId);

            if (shouldAdd && existingIndex < 0) {
                const entry = { id: pluginId, enabled: true };
                const clipboardIndex = widgets.findIndex(widget => widgetId(widget) === "clipboard");
                if (normalizedSection === "right" && clipboardIndex >= 0)
                    widgets.splice(clipboardIndex, 0, entry);
                else
                    widgets.push(entry);
            } else if (!shouldAdd && existingIndex >= 0) {
                widgets = widgets.filter(widget => widgetId(widget) !== pluginId);
            } else {
                continue;
            }

            const update = {};
            update[propertyName] = widgets;
            SettingsData.updateBarConfig(config.id, update);
            changed++;
        }
        return changed;
    }

    function copyTranslation() {
        if (!currentTranslation.trim())
            return;
        globalClipboardWriteAt.set(Date.now());
        Quickshell.execDetached(["dms", "cl", "copy", currentTranslation]);
        ToastService.showInfo(t("Copied", "已复制"));
    }

    Component {
        id: selectionReaderComponent

        Process {
            id: reader
            property bool primarySelection: true
            property bool smartInput: false
            property string clipboardEntryId: ""
            property string captureRole: "input"
            property string pendingText: ""
            property string capturedText: ""

            environment: {
                "UV_NO_PROGRESS": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUNBUFFERED": "1"
            }
            command: [
                "uv", "run",
                "--project", root.pluginPath,
                "--offline",
                "--frozen",
                root.captureHelperPath,
                primarySelection ? "primary" : "clipboard",
                String(root.maxInputChars),
                primarySelection ? "allow-sensitive" : "protect-sensitive"
            ]

            stdout: StdioCollector {
                onStreamFinished: reader.capturedText = text
            }

            stderr: StdioCollector {}

            onExited: (exitCode, exitStatus) => {
                Qt.callLater(() => {
                    root.onCaptured(reader, exitCode);
                    reader.destroy();
                });
            }
        }
    }

    Component {
        id: translateProcessComponent

        Process {
            id: translateProcess
            property var requestData: ({})
            property bool gotDone: false
            property bool finishedHandled: false
            property bool protocolError: false
            property bool cancelled: false
            property string stderrText: ""
            property string protocolNoise: ""

            stdinEnabled: true
            environment: {
                "UV_NO_PROGRESS": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUNBUFFERED": "1"
            }
            command: [
                "uv", "run",
                "--project", root.pluginPath,
                "--offline",
                "--frozen",
                root.helperPath
            ]

            stdout: SplitParser {
                splitMarker: "\n"
                onRead: line => root.handleProtocolLine(translateProcess, line)
            }

            stderr: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    if (line)
                        translateProcess.stderrText += String(line) + "\n";
                }
            }

            onStarted: write(JSON.stringify(requestData) + "\n")

            onExited: (exitCode, exitStatus) => {
                root.onTranslationExited(translateProcess, exitCode);
                translateProcess.destroy();
            }
        }
    }

    IpcHandler {
        target: "dankTranslateAI"

        function translateSelection(): string {
            root.beginSelectionTranslation();
            return "TRANSLATE_SELECTION_STARTED";
        }

        function translateClipboard(): string {
            root.beginClipboardTranslation();
            return "TRANSLATE_CLIPBOARD_STARTED";
        }

        function translateText(text: string): string {
            root.startTranslation(text);
            return "TRANSLATE_TEXT_STARTED";
        }

        function show(): string {
            root.showPopup();
            return "TRANSLATE_POPUP_SHOWN";
        }

        function open(): string {
            root.showPopup();
            return "TRANSLATE_POPUP_SHOWN";
        }

        function close(): string {
            root.closePopup();
            return "TRANSLATE_POPUP_CLOSED";
        }

        function cancel(): string {
            root.cancelActive(true);
            return "TRANSLATE_CANCELLED";
        }

        function clearHistory(): string {
            root.clearHistory();
            return "TRANSLATE_HISTORY_CLEARED";
        }

        function removeHistory(entryId: string): string {
            root.removeHistoryEntry(entryId);
            return "TRANSLATE_HISTORY_ENTRY_REMOVED";
        }

        function status(): string {
            return JSON.stringify({
                state: root.currentStatus,
                original: root.currentOriginal,
                translation: root.currentTranslation,
                error: root.currentError,
                language: root.currentLanguage,
                popupVisible: root.popupVisible
            });
        }

        function addToBar(section: string): string {
            const changed = root.updateBarPlacement(section || "right", true);
            return "TRANSLATE_BAR_ADDED: " + changed;
        }

        function removeFromBar(section: string): string {
            const changed = root.updateBarPlacement(section || "right", false);
            return "TRANSLATE_BAR_REMOVED: " + changed;
        }
    }

    PanelWindow {
        id: popupWindow

        readonly property real contentWidth: screen
            ? Math.min(760, Math.max(360, screen.width - 32))
            : 680
        readonly property real topOffset: Theme.barHeight + Theme.spacingL
        readonly property real maxCardHeight: screen
            ? Math.max(1, Math.floor(screen.height * 0.5 - topOffset))
            : 400
        readonly property real cardChromeHeight: Theme.spacingM * 2
            + 30
            + 30
            + Theme.spacingS * 2
        readonly property real maxTranslationHeight: Math.max(0, maxCardHeight - cardChromeHeight)

        screen: root.popupScreen
        visible: root.popupVisible
        color: "transparent"
        implicitWidth: contentWidth
        implicitHeight: popupCard.height

        anchors {
            top: true
            left: true
        }

        WlrLayershell.namespace: "dms:dank-translate-ai"
        WlrLayershell.layer: WlrLayershell.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.margins {
            left: popupWindow.screen
                ? Math.max(0, Math.round(popupWindow.screen.width / 2 - popupWindow.implicitWidth / 2))
                : 0
            top: popupWindow.topOffset
        }

        StyledRect {
            id: popupCard
            x: 0
            y: 0
            width: popupWindow.contentWidth
            height: popupColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
            border.width: 1
            border.color: Theme.outlineMedium

            Column {
                id: popupColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                Item {
                    width: parent.width
                    height: 30

                    DankIcon {
                        id: headerIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.currentStatus === "error" ? "error" : "translate"
                        size: Theme.iconSize
                        color: root.currentStatus === "error" ? Theme.error : Theme.primary
                    }

                    StyledText {
                        id: popupTitle
                        anchors.left: headerIcon.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.t("Translate", "翻译")
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                    }

                    StyledText {
                        anchors.left: popupTitle.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.right: progressIcon.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            switch (root.currentStatus) {
                            case "running": return root.t("· To ", "· 翻译为 ") + root.currentLanguage;
                            case "done": return root.t("· Done · ", "· 完成 · ") + root.currentLanguage;
                            case "cancelled": return root.t("· Stopped", "· 已停止");
                            case "error": return root.t("· Error", "· 错误");
                            default: return "· " + root.currentLanguage;
                            }
                        }
                        color: root.currentStatus === "error" ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }

                    DankIcon {
                        id: progressIcon
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.currentStatus === "running"
                        name: "progress_activity"
                        size: Theme.iconSizeSmall
                        color: Theme.primary

                        RotationAnimation on rotation {
                            from: 0
                            to: 360
                            duration: 900
                            loops: Animation.Infinite
                            running: progressIcon.visible
                        }
                    }
                }

                StyledRect {
                    id: translationBox
                    width: parent.width
                    height: Math.min(popupWindow.maxTranslationHeight, Math.max(112, translationText.implicitHeight + Theme.spacingS * 2))
                    radius: Theme.cornerRadius
                    color: root.currentStatus === "error"
                        ? Theme.withAlpha(Theme.error, 0.10)
                        : Theme.surfaceContainerHigh

                    DankFlickable {
                        id: translationScroll
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        contentWidth: width
                        contentHeight: Math.max(height, translationText.implicitHeight)
                        clip: true
                        verticalScrollBar.visible: contentHeight > height
                        verticalScrollBar.opacity: contentHeight > height ? 1 : 0

                        StyledText {
                            id: translationText
                            width: Math.max(0, translationScroll.width - Theme.spacingM)
                            height: implicitHeight
                            text: root.currentStatus === "error"
                                ? root.currentError
                                : (root.currentTranslation || root.t("Connecting…", "连接中…"))
                            color: root.currentStatus === "error" ? Theme.error : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            elide: Text.ElideNone
                            verticalAlignment: Text.AlignTop
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: 30

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        DankActionButton {
                            id: stopButton
                            visible: root.currentStatus === "running"
                            buttonSize: 30
                            iconName: "stop_circle"
                            iconColor: Theme.surfaceText
                            backgroundColor: Theme.surfaceContainerHighest
                            onClicked: root.cancelActive(true)
                        }

                        DankActionButton {
                            id: closeButton
                            buttonSize: 30
                            iconName: "close"
                            iconColor: Theme.surfaceText
                            backgroundColor: Theme.surfaceContainerHighest
                            onClicked: root.closePopup()
                        }

                        DankActionButton {
                            id: copyButton
                            buttonSize: 30
                            iconName: "content_copy"
                            iconColor: Theme.primaryText
                            backgroundColor: Theme.primary
                            enabled: root.currentTranslation.trim().length > 0
                            onClicked: root.copyTranslation()
                        }
                    }
                }
            }
        }

        mask: Region {
            item: popupCard
        }
    }
}
