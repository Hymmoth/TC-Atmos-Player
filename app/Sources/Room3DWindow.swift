import Cocoa
import SceneKit

/// Finestra con la vista 3D della stanza: diffusori del layout e oggetti Atmos in tempo reale.
/// Coordinate di Omniphony (x destra, y davanti, z alto) → SceneKit (X destra, Y alto, Z verso chi guarda):
/// X = x, Y = z, Z = -y.
final class Room3DWindowController: NSWindowController, NSWindowDelegate {
    private let osc: OSCClient
    private let scnView = SCNView()
    private let scene = SCNScene()
    private let speakersNode = SCNNode()
    private let objectsNode = SCNNode()
    private var objectNodes: [Int: SCNNode] = [:]
    private var timer: Timer?
    private let statusLabel = NSTextField(labelWithString: "")
    private let showBedCheckbox = NSButton(checkboxWithTitle: "Mostra canali del letto", target: nil, action: nil)
    private let showLabelsCheckbox = NSButton(checkboxWithTitle: "Nomi", target: nil, action: nil)
    private let delaySlider = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let delayLabel = NSTextField(labelWithString: "")
    /// Ritardo della vista rispetto ai dati: le posizioni arrivano quando l'audio è
    /// decodificato, cioè prima di quando lo si sente (buffer audio).
    private var viewDelay: Double {
        get { UserDefaults.standard.object(forKey: "view3DDelay") as? Double ?? 0.25 }
        set { UserDefaults.standard.set(newValue, forKey: "view3DDelay") }
    }

    init(osc: OSCClient) {
        self.osc = osc
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Vista 3D"
        window.setFrameAutosaveName("TCRoom3D")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        buildScene()
    }

    required init?(coder: NSCoder) { fatalError("non supportato") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        scnView.antialiasingMode = .multisampling4X
        content.addSubview(scnView)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 14
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        showBedCheckbox.state = .on
        showLabelsCheckbox.state = .off
        let reset = NSButton(title: "Ripristina vista", target: self, action: #selector(resetCamera))
        reset.bezelStyle = .rounded
        delaySlider.doubleValue = viewDelay
        delaySlider.target = self
        delaySlider.action = #selector(delayChanged(_:))
        delaySlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        delaySlider.toolTip = "Ritarda la vista per allinearla a quello che senti"
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        updateDelayLabel()
        bar.addArrangedSubview(statusLabel)
        bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(NSTextField(labelWithString: "Ritardo"))
        bar.addArrangedSubview(delaySlider)
        bar.addArrangedSubview(delayLabel)
        bar.addArrangedSubview(showBedCheckbox)
        bar.addArrangedSubview(showLabelsCheckbox)
        bar.addArrangedSubview(reset)
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            scnView.topAnchor.constraint(equalTo: content.topAnchor),
            scnView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scnView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func buildScene() {
        let camera = SCNCamera()
        camera.fieldOfView = 50
        camera.zNear = 0.05
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        resetCamera()

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 500
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 700
        key.eulerAngles = SCNVector3(-0.9, 0.4, 0)
        scene.rootNode.addChildNode(key)

        // Stanza: cubo da -1 a 1 in larghezza e profondità, da 0 (orecchie) a 1 (soffitto),
        // con il pavimento a -0.4.
        scene.rootNode.addChildNode(wireBox(min: SCNVector3(-1, -0.4, -1), max: SCNVector3(1, 1, 1)))
        let floor = SCNNode(geometry: SCNPlane(width: 2, height: 2))
        floor.geometry!.firstMaterial!.diffuse.contents = NSColor(calibratedWhite: 0.25, alpha: 0.35)
        floor.geometry!.firstMaterial!.isDoubleSided = true
        floor.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        floor.position = SCNVector3(0, -0.4, 0)
        scene.rootNode.addChildNode(floor)

        // Ascoltatore
        let head = SCNNode(geometry: SCNSphere(radius: 0.06))
        head.geometry!.firstMaterial!.diffuse.contents = NSColor.white
        scene.rootNode.addChildNode(head)
        let nose = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.025, height: 0.07))
        nose.geometry!.firstMaterial!.diffuse.contents = NSColor.white
        nose.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        nose.position = SCNVector3(0, 0, -0.08)
        scene.rootNode.addChildNode(nose)

        // Etichetta "Fronte"
        let front = textNode("FRONTE", size: 0.09, color: .systemYellow)
        front.position = SCNVector3(0, -0.35, -1.05)
        scene.rootNode.addChildNode(front)

        scene.rootNode.addChildNode(speakersNode)
        scene.rootNode.addChildNode(objectsNode)
        showLayout(AppSettings.shared.layout)
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        viewDelay = (sender.doubleValue * 100).rounded() / 100
        updateDelayLabel()
    }

    private func updateDelayLabel() {
        delayLabel.stringValue = "\(Int(viewDelay * 1000)) ms"
    }

    @objc private func resetCamera() {
        guard let cam = scene.rootNode.childNode(withName: "camera", recursively: false) else { return }
        cam.position = SCNVector3(0, 1.9, 2.9)
        cam.look(at: SCNVector3(0, 0.1, -0.1))
        scnView.pointOfView = cam
    }

    func showLayout(_ layout: SpeakerLayout) {
        speakersNode.childNodes.forEach { $0.removeFromParentNode() }
        for s in layout.speakers {
            let box = SCNBox(width: 0.12, height: 0.12, length: 0.08, chamferRadius: 0.01)
            box.firstMaterial!.diffuse.contents = s.spatialize ? NSColor(calibratedWhite: 0.75, alpha: 1)
                                                               : NSColor.systemPurple
            let node = SCNNode(geometry: box)
            node.position = scenePosition(x: s.x, y: s.y, z: s.z)
            node.look(at: SCNVector3(0, 0, 0))
            speakersNode.addChildNode(node)
            let label = textNode(s.name, size: 0.07, color: .lightGray)
            label.position = SCNVector3(node.position.x, node.position.y + 0.11, node.position.z)
            speakersNode.addChildNode(label)
        }
    }

    private func scenePosition(x: Double, y: Double, z: Double) -> SCNVector3 {
        SCNVector3(CGFloat(x), CGFloat(z), CGFloat(-y))
    }

    private func textNode(_ text: String, size: CGFloat, color: NSColor) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 1, weight: .semibold)
        t.flatness = 0.05
        t.firstMaterial!.diffuse.contents = color
        t.firstMaterial!.lightingModel = .constant
        let node = SCNNode(geometry: t)
        let (minB, maxB) = t.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2 + minB.x, minB.y, 0)
        node.scale = SCNVector3(size, size, size)
        let holder = SCNNode()
        holder.addChildNode(node)
        holder.constraints = [SCNBillboardConstraint()]
        return holder
    }

    private func wireBox(min a: SCNVector3, max b: SCNVector3) -> SCNNode {
        let c = [
            SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, a.y, a.z), SCNVector3(b.x, a.y, b.z), SCNVector3(a.x, a.y, b.z),
            SCNVector3(a.x, b.y, a.z), SCNVector3(b.x, b.y, a.z), SCNVector3(b.x, b.y, b.z), SCNVector3(a.x, b.y, b.z),
        ]
        let idx: [Int32] = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
        let src = SCNGeometrySource(vertices: c)
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        g.firstMaterial!.diffuse.contents = NSColor(calibratedWhite: 0.45, alpha: 1)
        g.firstMaterial!.lightingModel = .constant
        return SCNNode(geometry: g)
    }

    private func color(for id: Int) -> NSColor {
        // Colore stabile per oggetto
        var h = UInt32(truncatingIfNeeded: id &* 2654435761)
        h ^= h >> 13
        let hue = CGFloat(h % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.75, brightness: 1, alpha: 1)
    }

    // MARK: Aggiornamento

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startTimer()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let objects = osc.snapshot
        let displayTime = ProcessInfo.processInfo.systemUptime - viewDelay
        let showBed = showBedCheckbox.state == .on
        let showLabels = showLabelsCheckbox.state == .on
        var visibleIds = Set<Int>()
        var dynamicCount = 0

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for (id, o) in objects {
            if o.fixed && !showBed { continue }
            if !o.fixed { dynamicCount += 1 }
            visibleIds.insert(id)
            let node: SCNNode
            if let existing = objectNodes[id] {
                node = existing
            } else {
                node = SCNNode(geometry: SCNSphere(radius: 1))
                node.geometry!.firstMaterial!.diffuse.contents = o.fixed ? NSColor.systemGray : color(for: id)
                node.geometry!.firstMaterial!.emission.contents = o.fixed ? NSColor.black
                                                                          : color(for: id).withAlphaComponent(0.4)
                let label = textNode(o.label.isEmpty ? (o.name.isEmpty ? "\(id)" : o.name) : o.label,
                                     size: 0.06, color: .white)
                label.name = "label"
                node.addChildNode(label)
                objectsNode.addChildNode(node)
                objectNodes[id] = node
            }
            let pos = o.position(at: displayTime)
            node.position = scenePosition(x: pos.x, y: pos.y, z: pos.z)
            // Raggio in base al livello RMS (da -60 dB a 0 dB)
            let level = max(0, min(1, (o.rmsDB + 60) / 60))
            let r = CGFloat(o.fixed ? 0.025 : 0.03 + 0.05 * level)
            node.scale = SCNVector3(r, r, r)
            if let label = node.childNode(withName: "label", recursively: false) {
                label.isHidden = !showLabels
                // L'etichetta non deve rimpicciolire con la sfera
                let inv = 1 / r
                label.scale = SCNVector3(inv, inv, inv)
                label.position = SCNVector3(0, 0.06 / r, 0)
            }
        }
        for (id, node) in objectNodes where !visibleIds.contains(id) {
            node.removeFromParentNode()
            objectNodes.removeValue(forKey: id)
        }
        SCNTransaction.commit()

        if osc.isConnected {
            statusLabel.stringValue = dynamicCount > 0 ? "\(dynamicCount) oggetti attivi"
                                                        : "Collegato · nessun oggetto"
        } else {
            statusLabel.stringValue = "In attesa di una traccia Atmos…"
        }
    }
}
