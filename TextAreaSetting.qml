import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    required property string settingKey
    required property string label
    property string description: ""
    property string placeholder: ""
    property string defaultValue: ""
    property string value: defaultValue
    property int editorHeight: 150
    property bool isInitialized: false

    width: parent.width
    spacing: Theme.spacingS

    function findSettings() {
        let item = parent;
        while (item) {
            if (item.saveValue !== undefined && item.loadValue !== undefined)
                return item;
            item = item.parent;
        }
        return null;
    }

    function loadValue() {
        const settings = findSettings();
        if (!settings?.pluginService)
            return;
        const loadedValue = String(settings.loadValue(settingKey, defaultValue) ?? "");
        if (editor.activeFocus && isInitialized)
            return;
        value = loadedValue;
        editor.text = loadedValue;
        isInitialized = true;
    }

    function commit() {
        if (!isInitialized || editor.text === value)
            return;
        value = editor.text;
        const settings = findSettings();
        if (settings)
            settings.saveValue(settingKey, value);
    }

    Component.onCompleted: Qt.callLater(loadValue)

    StyledText {
        text: root.label
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        visible: root.description.length > 0
        text: root.description
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: root.editorHeight
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: editor.activeFocus ? 2 : 1
        border.color: editor.activeFocus ? Theme.primary : Theme.outlineMedium
        clip: true

        DankFlickable {
            id: editorScroll
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            contentWidth: width
            contentHeight: editor.height
            clip: true

            TextEdit {
                id: editor
                width: editorScroll.width
                height: Math.max(editorScroll.height, contentHeight)
                color: Theme.surfaceText
                selectionColor: Theme.primary
                selectedTextColor: Theme.primaryText
                font.pixelSize: Theme.fontSizeMedium
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                onActiveFocusChanged: {
                    if (!activeFocus)
                        root.commit();
                }
                Keys.onPressed: event => {
                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
                        root.commit();
                        event.accepted = true;
                    }
                }
            }
        }

        StyledText {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            visible: editor.text.length === 0 && !editor.activeFocus
            text: root.placeholder
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
