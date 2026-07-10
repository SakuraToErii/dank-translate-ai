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
        if (secretField.activeFocus && isInitialized)
            return;
        value = loadedValue;
        secretField.text = loadedValue;
        isInitialized = true;
    }

    function commit() {
        if (!isInitialized || secretField.text === value)
            return;
        value = secretField.text;
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

    DankTextField {
        id: secretField
        width: parent.width
        placeholderText: root.placeholder
        echoMode: TextInput.Password
        showPasswordToggle: true
        onEditingFinished: root.commit()
        onActiveFocusChanged: {
            if (!activeFocus)
                root.commit();
        }
    }
}
