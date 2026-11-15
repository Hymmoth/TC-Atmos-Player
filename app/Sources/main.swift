import Cocoa

// mpv richiede il locale numerico "C" (punto decimale), altrimenti rifiuta di partire.
setlocale(LC_NUMERIC, "C")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
