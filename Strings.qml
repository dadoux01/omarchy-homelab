import QtQuick
import Quickshell.Io

// The plugin's own strings, in the language picked in the widget settings
// (English by default) rather than the system language. Catalogs are flat
// JSON files in i18n/; a key missing from French falls back to English, then
// to the key itself. Bindings that call t() re-render when the language or a
// catalog changes.
QtObject {
  id: root

  property string language: "en"      // "en" | "fr"
  property var directory: ""

  readonly property string directoryPath: String(directory).replace(/^file:\/\//, "").replace(/\/+$/, "")
  readonly property var english: parse(englishFile.text())
  readonly property var localized: language === "en" ? ({}) : parse(localizedFile.text())

  function parse(text) {
    try {
      var data = JSON.parse(text || "{}")
      return data && typeof data === "object" ? data : {}
    } catch (e) {
      return {}
    }
  }

  function t(key) {
    var v = localized[key]
    if (typeof v !== "string") v = english[key]
    return typeof v === "string" ? v : key
  }

  // Settings store the display name of the enum option.
  function codeFor(setting) {
    var s = String(setting || "").toLowerCase()
    return s === "français" || s === "francais" || s === "french" || s === "fr" ? "fr" : "en"
  }

  property FileView englishFile: FileView {
    path: root.directoryPath + "/en.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  property FileView localizedFile: FileView {
    path: root.language === "en" ? "" : root.directoryPath + "/" + root.language + ".json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }
}
