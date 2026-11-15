import Cocoa
import OpenGL.GL3

/// Risolve i simboli OpenGL per il renderer di mpv.
private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?,
                               _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name = name else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// Layer OpenGL in cui mpv disegna il video (API di rendering di libmpv).
final class VideoLayer: CAOpenGLLayer {
    private weak var player: MPVPlayer?
    private var renderContext: OpaquePointer?
    private let cglPixelFormat: CGLPixelFormatObj
    private let cglContext: CGLContextObj
    private let renderQueue = DispatchQueue(label: "tc.mpv.render")
    private var needsMPVRender = false
    private let lock = NSLock()
    private(set) var hdrActive = false

    init(player: MPVPlayer) {
        self.player = player

        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(64),
            kCGLPFAColorFloat,
            CGLPixelFormatAttribute(0)
        ]
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        CGLChoosePixelFormat(attributes, &pix, &npix)
        if pix == nil {
            // Ripiego senza colore a virgola mobile (niente HDR).
            let fallback: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
                CGLPixelFormatAttribute(0)
            ]
            CGLChoosePixelFormat(fallback, &pix, &npix)
        }
        if pix == nil {
            // Ultimo ripiego: qualunque renderer, anche software.
            let minimal: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFADoubleBuffer,
                CGLPixelFormatAttribute(0)
            ]
            CGLChoosePixelFormat(minimal, &pix, &npix)
        }
        guard let pixelFormat = pix else { fatalError("Nessun formato OpenGL disponibile") }
        cglPixelFormat = pixelFormat

        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let context = ctx else { fatalError("Impossibile creare il contesto OpenGL") }
        cglContext = context
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(context, kCGLCEMPEngine)

        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor

        createRenderContext()
    }

    override init(layer: Any) {
        // Usato da Core Animation per le copie di presentazione.
        let other = layer as! VideoLayer
        player = other.player
        cglPixelFormat = other.cglPixelFormat
        cglContext = other.cglContext
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("non supportato") }

    private func createRenderContext() {
        guard let handle = player?.handle else { return }
        CGLLockContext(cglContext)
        CGLSetCurrentContext(cglContext)
        defer { CGLUnlockContext(cglContext) }

        let apiType = UnsafeMutableRawPointer(strdup("opengl"))  // resta valido per tutta la vita del layer
        var initParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress,
                                                get_proc_address_ctx: nil)
        var advanced: CInt = 1
        withUnsafeMutablePointer(to: &initParams) { initPtr in
            withUnsafeMutablePointer(to: &advanced) { advPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advPtr),
                    mpv_render_param()
                ]
                let r = mpv_render_context_create(&renderContext, handle, &params)
                if r < 0 {
                    fatalError("mpv_render_context_create fallito: \(String(cString: mpv_error_string(r)))")
                }
            }
        }

        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(renderContext, { ctx in
            guard let ctx = ctx else { return }
            let layer = Unmanaged<VideoLayer>.fromOpaque(ctx).takeUnretainedValue()
            layer.renderQueue.async { layer.update() }
        }, me)
    }

    private func update() {
        guard let rc = renderContext else { return }
        let flags = mpv_render_context_update(rc)
        if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            lock.lock(); needsMPVRender = true; lock.unlock()
            display()
            CATransaction.flush()
        }
    }

    /// Ridisegna subito (es. dopo un ridimensionamento).
    func forceDraw() {
        lock.lock(); needsMPVRender = true; lock.unlock()
        renderQueue.async {
            self.display()
            CATransaction.flush()
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return needsMPVRender
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        lock.lock(); needsMPVRender = false; lock.unlock()
        CGLLockContext(ctx)
        CGLSetCurrentContext(ctx)
        defer { CGLUnlockContext(ctx) }

        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        guard let rc = renderContext else { glFlush(); return }

        var fboBinding: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fboBinding)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var fbo = mpv_opengl_fbo(fbo: Int32(fboBinding), w: Int32(viewport[2]), h: Int32(viewport[3]),
                                 internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param()
                ]
                mpv_render_context_render(rc, &params)
            }
        }
        glFlush()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(cglPixelFormat)
        return cglPixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(cglContext)
        return cglContext
    }

    override func display() {
        super.display()
        if let rc = renderContext {
            mpv_render_context_report_swap(rc)
        }
    }

    /// Attiva o disattiva l'uscita HDR (EDR) del layer.
    func setHDR(_ on: Bool, peakNits: Double) {
        guard on != hdrActive, let player = player else { return }
        hdrActive = on
        if on {
            wantsExtendedDynamicRangeContent = true
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            player.setString("target-prim", "bt.2020")
            player.setString("target-trc", "pq")
            player.setString("target-peak", String(Int(peakNits)))
            player.setString("tone-mapping", "auto")
        } else {
            wantsExtendedDynamicRangeContent = false
            colorspace = nil
            player.setString("target-prim", "auto")
            player.setString("target-trc", "auto")
            player.setString("target-peak", "auto")
        }
        forceDraw()
    }

    /// Libera il contesto di rendering (va fatto prima di distruggere mpv).
    func uninit() {
        renderQueue.sync {
            if let rc = renderContext {
                mpv_render_context_set_update_callback(rc, nil, nil)
                mpv_render_context_free(rc)
                renderContext = nil
            }
        }
    }
}

/// Vista che ospita il layer video e accetta file trascinati.
final class VideoView: NSView {
    let videoLayer: VideoLayer
    var onDropFiles: (([URL]) -> Void)?
    var onMouseMoved: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(player: MPVPlayer) {
        videoLayer = VideoLayer(player: player)
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("non supportato") }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    // Trascinamento di file
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
