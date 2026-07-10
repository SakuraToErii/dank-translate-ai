.pragma library

// Adapted from DankMaterialShell/Common/KeyUtils.js (MIT, Avenge Media LLC).
const KEY_MAP = {
    16777234: "Left",
    16777236: "Right",
    16777235: "Up",
    16777237: "Down",
    44: "Comma",
    46: "Period",
    47: "Slash",
    59: "Semicolon",
    39: "Apostrophe",
    91: "BracketLeft",
    93: "BracketRight",
    92: "Backslash",
    45: "Minus",
    61: "Equal",
    96: "grave",
    32: "space",
    16777225: "Print",
    16777226: "Print",
    16777220: "Return",
    16777221: "Return",
    16777217: "Tab",
    16777219: "BackSpace",
    16777223: "Delete",
    16777222: "Insert",
    16777232: "Home",
    16777233: "End",
    16777238: "Page_Up",
    16777239: "Page_Down",
    16777224: "Pause",
    16777330: "XF86AudioRaiseVolume",
    16777328: "XF86AudioLowerVolume",
    16777329: "XF86AudioMute",
    16842808: "XF86AudioMicMute",
    16777344: "XF86AudioPlay",
    16777345: "XF86AudioStop",
    16777346: "XF86AudioPrev",
    16777347: "XF86AudioNext",
    16777348: "XF86AudioPause",
    16842798: "XF86MonBrightnessUp",
    16777394: "XF86MonBrightnessUp",
    16842797: "XF86MonBrightnessDown",
    16777395: "XF86MonBrightnessDown",
    16842796: "XF86PowerOff",
    16842803: "XF86Sleep",
    16842802: "XF86Eject",
    16842791: "XF86Calculator",
    16777360: "XF86HomePage",
    16842794: "XF86HomePage",
    16777362: "XF86Search",
    16777376: "XF86Mail",
    16777442: "XF86Launch0",
    16777443: "XF86Launch1"
};

const SYMBOL_KEYSYM = {
    33: "exclam",
    34: "quotedbl",
    35: "numbersign",
    36: "dollar",
    37: "percent",
    38: "ampersand",
    40: "parenleft",
    41: "parenright",
    42: "asterisk",
    43: "plus",
    58: "colon",
    60: "less",
    62: "greater",
    63: "question",
    64: "at",
    94: "asciicircum",
    95: "underscore",
    123: "braceleft",
    124: "bar",
    125: "braceright",
    126: "asciitilde"
};

const SHIFTED_US_FALLBACK = {
    33: "1",
    34: "Apostrophe",
    35: "3",
    36: "4",
    37: "5",
    38: "7",
    40: "9",
    41: "0",
    42: "8",
    43: "Equal",
    58: "Semicolon",
    60: "Comma",
    62: "Period",
    63: "Slash",
    64: "2",
    94: "6",
    95: "Minus",
    123: "BracketLeft",
    124: "Backslash",
    125: "BracketRight",
    126: "grave"
};

const KP_MAP = {
    16777232: "KP_Home",
    16777235: "KP_Up",
    16777238: "KP_Prior",
    16777234: "KP_Left",
    16777227: "KP_Begin",
    16777236: "KP_Right",
    16777233: "KP_End",
    16777237: "KP_Down",
    16777239: "KP_Next",
    16777222: "KP_Insert",
    16777223: "KP_Delete",
    16777221: "KP_Enter",
    43: "KP_Add",
    45: "KP_Subtract",
    42: "KP_Multiply",
    47: "KP_Divide",
    46: "KP_Decimal"
};

function xkbKeyFromQtKey(qtKey, isKeypad, hasShift) {
    if (isKeypad) {
        if (qtKey >= 48 && qtKey <= 57)
            return "KP_" + (qtKey - 48);
        if (KP_MAP[qtKey])
            return KP_MAP[qtKey];
    }
    if (!hasShift && SYMBOL_KEYSYM[qtKey])
        return SYMBOL_KEYSYM[qtKey];
    if (hasShift && SHIFTED_US_FALLBACK[qtKey])
        return SHIFTED_US_FALLBACK[qtKey];
    if (qtKey >= 65 && qtKey <= 90)
        return String.fromCharCode(qtKey);
    if (qtKey >= 97 && qtKey <= 122)
        return String.fromCharCode(qtKey - 32);
    if (qtKey >= 48 && qtKey <= 57)
        return String.fromCharCode(qtKey);
    if (qtKey >= 16777264 && qtKey <= 16777298)
        return "F" + (qtKey - 16777264 + 1);
    if (qtKey >= 16777378 && qtKey <= 16777387)
        return "XF86Launch" + (qtKey - 16777378);
    return KEY_MAP[qtKey] || "";
}

function modsFromEvent(modifiers) {
    const result = [];
    if (modifiers & 0x10000000)
        result.push("Super");
    if (modifiers & 0x08000000)
        result.push("Alt");
    if (modifiers & 0x04000000)
        result.push("Ctrl");
    if (modifiers & 0x02000000)
        result.push("Shift");
    return result;
}

function withSymbolicMod(modifiers, modKey) {
    const configured = String(modKey || "").toLowerCase();
    return modifiers.map(modifier => {
        const normalized = modifier.toLowerCase();
        return normalized === configured ? "Mod" : modifier;
    });
}

function formatToken(modifiers, key) {
    return (modifiers.length ? modifiers.join("+") + "+" : "") + key;
}

function normalizeKeyCombo(keyCombo, modKey) {
    const configured = String(modKey || "Super").toLowerCase();
    return String(keyCombo || "")
        .toLowerCase()
        .replace(/\bmod\b/g, configured)
        .replace(/\bcontrol\b/g, "ctrl")
        .replace(/\bwin\b/g, "super");
}
