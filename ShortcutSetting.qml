pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "KeyCaptureUtils.js" as KeyUtils

Column {
    id: root

    property bool zh: false
    property string action: "spawn dms ipc call dankTranslateAI translateSelection"
    property string currentKey: ""
    property string pendingKey: ""
    property string candidateKey: ""
    property string conflictText: ""
    property bool recording: false
    property bool waitingForSave: false
    property bool altShiftGhost: false

    width: parent.width
    spacing: Theme.spacingS

    function refresh() {
        const keys = KeybindsService.keysForAction(action);
        currentKey = keys.length > 0 ? keys[0] : "";
    }

    function startRecording() {
        if (!KeybindsService.available) {
            ToastService.showError(zh ? "当前合成器暂不支持快捷键写入" : "Shortcut editing is unavailable for this compositor");
            return;
        }
        if (KeybindsService.readOnly) {
            KeybindsService.showHyprlandReadOnlyWarning();
            return;
        }
        candidateKey = "";
        conflictText = "";
        recording = true;
        altShiftGhost = false;
        captureScope.forceActiveFocus();
    }

    function cancelRecording() {
        recording = false;
        altShiftGhost = false;
        candidateKey = "";
        conflictText = "";
    }

    function conflictingAction(key) {
        const modKey = KeybindsService.currentProvider === "niri" ? KeybindsService.modKey : "Super";
        const normalized = KeyUtils.normalizeKeyCombo(key, modKey);
        const binds = KeybindsService.getFlatBinds();
        for (let i = 0; i < binds.length; i++) {
            const group = binds[i];
            if (!group || group.action === action || !Array.isArray(group.keys))
                continue;
            for (let k = 0; k < group.keys.length; k++) {
                const entry = group.keys[k];
                if (KeyUtils.normalizeKeyCombo(entry?.key || "", modKey) === normalized)
                    return entry?.desc || group.desc || group.action || key;
            }
        }
        return "";
    }

    function acceptCandidate(key) {
        candidateKey = key;
        const conflict = conflictingAction(key);
        if (conflict) {
            conflictText = zh ? "已占用：" + conflict : "Already used: " + conflict;
            captureScope.forceActiveFocus();
            return;
        }
        conflictText = "";
        saveKey(key);
    }

    function saveKey(key) {
        if (!key || key === currentKey) {
            cancelRecording();
            return;
        }
        pendingKey = key;
        waitingForSave = true;
        recording = false;
        KeybindsService.saveBind(currentKey, {
            "key": key,
            "action": action,
            "desc": zh ? "翻译划词或复制" : "Translate selection or copy",
            "repeat": false
        });
    }

    Component.onCompleted: {
        if (KeybindsService._dataVersion === 0)
            KeybindsService.loadBinds();
        Qt.callLater(refresh);
    }

    Connections {
        target: KeybindsService

        function onBindsLoaded() {
            root.refresh();
        }

        function onBindSaveCompleted(success) {
            if (!root.waitingForSave)
                return;
            root.waitingForSave = false;
            if (success) {
                root.currentKey = root.pendingKey;
                ToastService.showInfo(root.zh ? "快捷键已保存" : "Shortcut saved");
            }
            root.pendingKey = "";
        }
    }

    StyledText {
        text: root.zh ? "快捷键" : "Shortcut"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.primary
    }

    StyledText {
        width: parent.width
        text: root.zh ? "点击右侧图标，然后按组合键。Esc 取消。" : "Click the icon, then press a key combo. Esc cancels."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    FocusScope {
        id: captureScope
        width: parent.width
        height: 42
        focus: root.recording

        onActiveFocusChanged: {
            if (!activeFocus && root.recording)
                root.cancelRecording();
        }

        StyledRect {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: root.conflictText
                ? Theme.withAlpha(Theme.error, 0.12)
                : (root.recording ? Theme.primaryContainer : Theme.surfaceContainerHigh)
            border.width: root.recording ? 2 : 1
            border.color: root.conflictText
                ? Theme.error
                : (root.recording ? Theme.primary : Theme.outlineMedium)

            StyledText {
                anchors.left: parent.left
                anchors.right: recordButton.left
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: root.recording
                    ? (root.candidateKey || (root.zh ? "按下快捷键 · Esc 取消" : "Press shortcut · Esc cancels"))
                    : (root.currentKey || (root.zh ? "未设置" : "Unset"))
                color: root.conflictText ? Theme.error : (root.recording ? Theme.primary : Theme.surfaceText)
                font.pixelSize: Theme.fontSizeMedium
                isMonospace: !root.recording
                elide: Text.ElideRight
            }

            DankActionButton {
                id: recordButton
                anchors.right: parent.right
                anchors.rightMargin: 3
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 36
                iconSize: Theme.iconSizeSmall
                iconName: root.recording ? "close" : (root.waitingForSave ? "progress_activity" : "keyboard")
                iconColor: root.recording ? Theme.error : Theme.primary
                tooltipText: root.recording
                    ? (root.zh ? "取消" : "Cancel")
                    : (root.zh ? "录入" : "Record")
                enabled: !root.waitingForSave
                onClicked: root.recording ? root.cancelRecording() : root.startRecording()

                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: root.waitingForSave
                }
            }
        }

        Keys.onPressed: event => {
            if (!root.recording)
                return;
            event.accepted = true;

            if (event.key === Qt.Key_Escape) {
                root.cancelRecording();
                return;
            }

            switch (event.key) {
            case Qt.Key_Control:
            case Qt.Key_Shift:
            case Qt.Key_Alt:
            case Qt.Key_Meta:
            case Qt.Key_NumLock:
            case Qt.Key_CapsLock:
            case Qt.Key_ScrollLock:
                return;
            }

            if (event.key === 0 && (event.modifiers & Qt.AltModifier)) {
                root.altShiftGhost = true;
                return;
            }

            let modifiers = KeyUtils.modsFromEvent(event.modifiers);
            let qtKey = event.key;
            if (root.altShiftGhost && (event.modifiers & Qt.AltModifier) && !modifiers.includes("Shift"))
                modifiers.push("Shift");
            root.altShiftGhost = false;

            if (qtKey === Qt.Key_Backtab) {
                qtKey = Qt.Key_Tab;
                if (!modifiers.includes("Shift"))
                    modifiers.push("Shift");
            }
            if (KeybindsService.currentProvider === "niri")
                modifiers = KeyUtils.withSymbolicMod(modifiers, KeybindsService.modKey);

            const key = KeyUtils.xkbKeyFromQtKey(
                qtKey,
                !!(event.modifiers & Qt.KeypadModifier),
                modifiers.includes("Shift")
            );
            if (key)
                root.acceptCandidate(KeyUtils.formatToken(modifiers, key));
        }
    }

    StyledText {
        width: parent.width
        visible: root.conflictText.length > 0
        text: root.conflictText
        color: Theme.error
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }
}
