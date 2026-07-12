import AppKit
import CoreGraphics
import Foundation
import WDSWhackCore

private struct Options {
    let rect: CGRect
    let duration: TimeInterval
    let debug: Bool
    let reportJSON: Bool
    let motion: MotionSample
    let displayText: String
    let fallbackUsed: Bool

    static let usage = """
    Usage:
      wds-whack --x <points> --y <points> --width <points> --height <points> --duration-ms <milliseconds> [motion options] [--text-stdin] [--geometry-estimated] [--report-json] [--debug]

    Motion options (all optional):
      --motion-direction <stationary|north|northeast|east|southeast|south|southwest|west|northwest>
      --motion-speed <points-per-second>
      --motion-distance <points>

    Coordinates use the macOS global screen space with a top-left origin, matching
    Quartz screenshots and Accessibility bounds. The overlay is visual-only: it is
    transparent, click-through, and never reads or changes another application's UI.

    With --text-stdin, the short UTF-8 phrase to animate is read only from stdin.
    Without it, a fixed non-user sample is rendered. Motion defaults to stationary.
    """

    static func parse(_ arguments: [String]) throws -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            Foundation.exit(EXIT_SUCCESS)
        }

        let required = ["--x", "--y", "--width", "--height", "--duration-ms"]
        let optionalNumeric = ["--motion-speed", "--motion-distance"]
        let numericFlags = required + optionalNumeric
        var values: [String: Double] = [:]
        var debug = false
        var reportJSON = false
        var textFromStandardInput = false
        var geometryEstimated = false
        var motionDirection: MotionDirection?
        var sawMotionDirection = false
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--debug" {
                guard !debug else {
                    throw ArgumentError("Duplicate argument: --debug")
                }
                debug = true
                index += 1
                continue
            }
            if flag == "--report-json" {
                guard !reportJSON else {
                    throw ArgumentError("Duplicate argument: --report-json")
                }
                reportJSON = true
                index += 1
                continue
            }
            if flag == "--text-stdin" {
                guard !textFromStandardInput else {
                    throw ArgumentError("Duplicate argument: --text-stdin")
                }
                textFromStandardInput = true
                index += 1
                continue
            }
            if flag == "--geometry-estimated" {
                guard !geometryEstimated else {
                    throw ArgumentError("Duplicate argument: --geometry-estimated")
                }
                geometryEstimated = true
                index += 1
                continue
            }
            if flag == "--motion-direction" {
                guard !sawMotionDirection else {
                    throw ArgumentError("Duplicate argument: --motion-direction")
                }
                guard index + 1 < arguments.count else {
                    throw ArgumentError("Missing value for --motion-direction")
                }
                let rawValue = arguments[index + 1]
                guard let direction = MotionDirection(rawValue: rawValue) else {
                    let allowed = MotionDirection.allCases.map(\.rawValue).joined(separator: "|")
                    throw ArgumentError("Invalid value for --motion-direction: \(rawValue). Expected one of: \(allowed)")
                }
                motionDirection = direction
                sawMotionDirection = true
                index += 2
                continue
            }
            guard numericFlags.contains(flag) else {
                throw ArgumentError("Unknown argument: \(flag)")
            }
            guard index + 1 < arguments.count else {
                throw ArgumentError("Missing value for \(flag)")
            }
            let rawValue = arguments[index + 1]
            guard let value = Double(rawValue), value.isFinite else {
                throw ArgumentError("Invalid numeric value for \(flag): \(rawValue)")
            }
            guard values[flag] == nil else {
                throw ArgumentError("Duplicate argument: \(flag)")
            }
            values[flag] = value
            index += 2
        }

        for flag in required where values[flag] == nil {
            throw ArgumentError("Missing required argument: \(flag)")
        }

        let width = values["--width"]!
        let height = values["--height"]!
        let milliseconds = values["--duration-ms"]!
        guard width > 0, height > 0 else {
            throw ArgumentError("--width and --height must be greater than zero")
        }
        guard milliseconds >= 100, milliseconds <= 10_000 else {
            throw ArgumentError("--duration-ms must be between 100 and 10000")
        }

        let displayText: String
        let fallbackUsed: Bool
        if textFromStandardInput {
            let input = try readBoundedStandardInput()
            switch GlyphTextInput.parse(input) {
            case .success(let text):
                displayText = text
                fallbackUsed = false
            case .failure:
                throw ArgumentError("Invalid glyph text input")
            }
        } else {
            displayText = "날려!"
            fallbackUsed = true
        }

        return Options(
            rect: CGRect(
                x: values["--x"]!,
                y: values["--y"]!,
                width: width,
                height: height
            ),
            duration: milliseconds / 1_000,
            debug: debug,
            reportJSON: reportJSON,
            motion: MotionSample(
                direction: motionDirection ?? .stationary,
                speed: values["--motion-speed"] ?? 0,
                distance: values["--motion-distance"] ?? 0
            ),
            displayText: displayText,
            fallbackUsed: fallbackUsed || geometryEstimated
        )
    }

    private static func readBoundedStandardInput() throws -> Data {
        var data = Data()
        while true {
            let remaining = GlyphTextInput.maximumBytes - data.count
            let chunk = try FileHandle.standardInput.read(upToCount: min(4_096, remaining + 1)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= GlyphTextInput.maximumBytes else {
                throw ArgumentError("Invalid glyph text input")
            }
        }
        return data
    }
}

private struct ArgumentError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct CrackRay {
    let angle: CGFloat
    let reach: CGFloat
    let bend: CGFloat
    let branchAt: CGFloat
    let branchDirection: CGFloat
}

private struct Shard {
    let angle: CGFloat
    let distance: CGFloat
    let size: CGSize
    let spin: CGFloat
    let delay: CGFloat
}

private struct RenderMetrics {
    let framesDrawn: Int
    let glyphFramesDrawn: Int
    let timerTicks: Int
    let elapsedMilliseconds: Int
}

private struct GlyphParticle {
    let image: CGImage?
    let size: CGSize
    let center: CGPoint
    let drift: CGFloat
    let rise: CGFloat
    let rotation: CGFloat
    let delay: CGFloat
    let isVisibleGlyph: Bool
}

private final class SmashView: NSView {
    private let duration: TimeInterval
    private let impactPoint: CGPoint
    private let targetRect: CGRect
    private let rays: [CrackRay]
    private let shards: [Shard]
    private let motionVector: CGPoint
    private let motionInfluence: CGFloat
    private let motionShardDrift: CGFloat
    private let glyphParticles: [GlyphParticle]
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var progress: CGFloat = 0
    private var framesDrawn = 0
    private var glyphFramesDrawn = 0
    private var timerTicks = 0
    var onFinished: ((RenderMetrics) -> Void)?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    init(
        frame: CGRect,
        targetRect: CGRect,
        duration: TimeInterval,
        motion: MotionSample,
        displayText: String
    ) {
        self.duration = duration
        self.targetRect = targetRect
        impactPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)
        motionVector = CGPoint(
            x: CGFloat(motion.appKitUnitVector.x),
            y: CGFloat(motion.appKitUnitVector.y)
        )
        motionInfluence = CGFloat(motion.visualInfluence)
        motionShardDrift = CGFloat(motion.shardDrift)

        var generator = SeededGenerator(seed: 0x5744_5357_4841_434B)
        rays = (0..<18).map { index in
            let base = (CGFloat(index) / 18) * .pi * 2
            return CrackRay(
                angle: base + CGFloat.random(in: -0.12...0.12, using: &generator),
                reach: CGFloat.random(in: 0.55...1.0, using: &generator),
                bend: CGFloat.random(in: -0.32...0.32, using: &generator),
                branchAt: CGFloat.random(in: 0.38...0.74, using: &generator),
                branchDirection: CGFloat.random(in: -0.75...0.75, using: &generator)
            )
        }
        shards = (0..<24).map { _ in
            Shard(
                angle: CGFloat.random(in: 0...(CGFloat.pi * 2), using: &generator),
                distance: CGFloat.random(in: 34...118, using: &generator),
                size: CGSize(
                    width: CGFloat.random(in: 4...13, using: &generator),
                    height: CGFloat.random(in: 6...18, using: &generator)
                ),
                spin: CGFloat.random(in: -3.2...3.2, using: &generator),
                delay: CGFloat.random(in: 0...0.18, using: &generator)
            )
        }

        let characters = displayText.map(String.init)
        let availableWidth = max(
            72,
            min(frame.width - 24, max(targetRect.width + 96, 220))
        )
        let baseFontSize = max(18, min(34, targetRect.height * 0.78))
        let makeText: (String, CGFloat) -> NSAttributedString = { character, fontSize in
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.78)
            return NSAttributedString(
                string: character,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 1),
                    .strokeColor: NSColor(calibratedWhite: 0.04, alpha: 0.92),
                    .strokeWidth: -2.4,
                    .shadow: shadow,
                ]
            )
        }
        var glyphTexts = characters.map { makeText($0, baseFontSize) }
        let spacing = max(1, baseFontSize * 0.04)
        let initialWidth = glyphTexts.reduce(CGFloat.zero) { $0 + max(1, ceil($1.size().width)) }
            + spacing * CGFloat(max(0, glyphTexts.count - 1))
        if initialWidth > availableWidth {
            let fittedSize = max(12, baseFontSize * availableWidth / initialWidth)
            glyphTexts = characters.map { makeText($0, fittedSize) }
        }
        let widths = glyphTexts.map { max(1, ceil($0.size().width)) }
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        var cursorX = targetRect.midX - totalWidth / 2
        let centerY = targetRect.midY
        let maximumIndex = max(1, glyphTexts.count - 1)
        let rasterizedGlyph: (NSAttributedString, Bool) -> (CGImage?, CGSize) = { text, isVisible in
            let measured = text.size()
            guard isVisible else {
                return (nil, CGSize(width: max(1, measured.width), height: max(1, measured.height)))
            }
            let padding: CGFloat = 8
            let canvasSize = CGSize(
                width: max(1, ceil(measured.width + padding * 2)),
                height: max(1, ceil(measured.height + padding * 2))
            )
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width),
                pixelsHigh: Int(canvasSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
                return (nil, canvasSize)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.imageInterpolation = .high
            text.draw(at: CGPoint(x: padding, y: padding))
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return (bitmap.cgImage, canvasSize)
        }
        glyphParticles = zip(characters, glyphTexts).enumerated().map { index, pair in
            let character = pair.0
            let text = pair.1
            let width = widths[index]
            let isVisible = GlyphTextInput.isRenderable(character)
            let rasterized = rasterizedGlyph(text, isVisible)
            defer { cursorX += width + spacing }
            return GlyphParticle(
                image: rasterized.0,
                size: rasterized.1,
                center: CGPoint(x: cursorX + width / 2, y: centerY),
                drift: CGFloat.random(in: -12...12, using: &generator),
                rise: CGFloat.random(in: 76...128, using: &generator),
                rotation: CGFloat.random(in: -0.13...0.13, using: &generator),
                delay: CGFloat(index) / CGFloat(maximumIndex) * 0.16,
                isVisibleGlyph: isVisible && rasterized.0 != nil
            )
        }

        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }

    private func tick() {
        timerTicks += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        progress = min(1, CGFloat(elapsed / duration))
        needsDisplay = true
        if progress >= 1 {
            timer?.invalidate()
            timer = nil
            displayIfNeeded()
            onFinished?(RenderMetrics(
                framesDrawn: framesDrawn,
                glyphFramesDrawn: glyphFramesDrawn,
                timerTicks: timerTicks,
                elapsedMilliseconds: max(0, Int((elapsed * 1_000).rounded()))
            ))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        framesDrawn += 1
        context.saveGState()
        context.setAllowsAntialiasing(true)
        drawShockwaves(in: context)
        drawImpact(in: context)
        if drawGlyphParticles(in: context) {
            glyphFramesDrawn += 1
        }
        context.restoreGState()
    }

    private func drawGlyphParticles(in context: CGContext) -> Bool {
        var drewVisibleGlyph = false

        for particle in glyphParticles {
            let local = clamp((progress - particle.delay) / max(0.01, 1 - particle.delay))
            guard local >= 0 else { continue }
            let launch = smoothStep(0.10, 0.88, local)
            let eased = 1 - pow(1 - launch, 2.2)
            let alpha = 1 - smoothStep(0.55, 1, local)
            guard alpha > 0.01 else { continue }

            let impactJitter = sin(local * .pi * 8) * (1 - smoothStep(0, 0.22, local)) * 1.8
            let x = particle.center.x
                + particle.drift * eased
                + motionVector.x * 10 * eased
                + impactJitter
            let y = particle.center.y + particle.rise * eased + motionVector.y * 4 * eased
            let scale = 1 + 0.08 * (1 - smoothStep(0.05, 0.20, local)) - 0.22 * smoothStep(0.72, 1, local)
            let textSize = particle.size

            context.saveGState()
            context.setAlpha(alpha)
            context.translateBy(x: x, y: y)
            context.rotate(by: particle.rotation * eased)
            context.scaleBy(x: scale, y: scale)
            let fracture = smoothStep(0.16, 0.76, local)
            let sliceHeight = max(1, textSize.height / 3)
            if let image = particle.image {
                for slice in 0..<3 {
                let sliceOffset = CGFloat(slice - 1)
                context.saveGState()
                context.translateBy(
                    x: sliceOffset * (3.2 + abs(particle.drift) * 0.18) * fracture,
                    y: -sliceOffset * 2.4 * fracture
                )
                context.rotate(by: sliceOffset * 0.028 * fracture)
                context.clip(to: CGRect(
                    x: -textSize.width / 2 - 3,
                    y: -textSize.height / 2 + CGFloat(slice) * sliceHeight - 1,
                    width: textSize.width + 6,
                    height: sliceHeight + 2
                ))
                    context.draw(image, in: CGRect(
                        x: -textSize.width / 2,
                        y: -textSize.height / 2,
                        width: textSize.width,
                        height: textSize.height
                    ))
                context.restoreGState()
                }
            }
            context.restoreGState()
            drewVisibleGlyph = drewVisibleGlyph || particle.isVisibleGlyph
        }

        return drewVisibleGlyph
    }

    private func drawLiftBeam(in context: CGContext) {
        let appear = smoothStep(0.02, 0.18, progress)
        let disappear = 1 - smoothStep(0.72, 1, progress)
        let alpha = appear * disappear
        guard alpha > 0 else { return }

        let travel = max(120, min(bounds.height * 0.62, 230))
        let beamWidth = max(34, min(92, targetRect.width * 0.72))
        let beamRect = CGRect(
            x: impactPoint.x - beamWidth / 2,
            y: impactPoint.y - 8,
            width: beamWidth,
            height: travel + 24
        )
        let colors = [
            NSColor(calibratedRed: 0.20, green: 0.86, blue: 1, alpha: 0).cgColor,
            NSColor(calibratedRed: 0.35, green: 0.92, blue: 1, alpha: alpha * 0.32).cgColor,
            NSColor(calibratedRed: 1, green: 0.80, blue: 0.24, alpha: alpha * 0.72).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.64, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }

        context.saveGState()
        context.addPath(CGPath(
            roundedRect: beamRect,
            cornerWidth: beamWidth / 2,
            cornerHeight: beamWidth / 2,
            transform: nil
        ))
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: beamRect.midX, y: beamRect.maxY),
            end: CGPoint(x: beamRect.midX, y: beamRect.minY),
            options: []
        )
        context.restoreGState()
    }

    private func drawTargetGhost(in context: CGContext) {
        let lift = 8 + 150 * smoothStep(0.08, 0.88, progress)
        let appear = smoothStep(0, 0.12, progress)
        let disappear = 1 - smoothStep(0.58, 0.94, progress)
        let alpha = appear * disappear
        guard alpha > 0 else { return }

        for echo in stride(from: 3, through: 0, by: -1) {
            let echoProgress = CGFloat(echo) / 3
            let echoRect = targetRect
                .offsetBy(dx: motionVector.x * 12 * echoProgress, dy: lift - 22 * echoProgress)
                .insetBy(dx: -8 + 2 * echoProgress, dy: -5 + echoProgress)
            let echoAlpha = alpha * (0.12 + (1 - echoProgress) * 0.34)
            let path = CGPath(
                roundedRect: echoRect,
                cornerWidth: min(12, echoRect.height / 2),
                cornerHeight: min(12, echoRect.height / 2),
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(NSColor(
                calibratedRed: 0.30,
                green: 0.88,
                blue: 1,
                alpha: echoAlpha
            ).cgColor)
            context.setShadow(
                offset: .zero,
                blur: 12,
                color: NSColor(calibratedRed: 0.18, green: 0.76, blue: 1, alpha: echoAlpha).cgColor
            )
            context.fillPath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func drawShockwaves(in context: CGContext) {
        let local = clamp(progress / 0.34)
        let alpha = (1 - smoothStep(0.18, 1, local)) * 0.72
        guard alpha > 0 else { return }
        let expansion = 5 + 24 * smoothStep(0, 0.82, local)
        let rect = targetRect.insetBy(dx: -expansion, dy: -expansion * 0.48)
        context.setStrokeColor(NSColor(
            calibratedRed: 1,
            green: 0.68,
            blue: 0.16,
            alpha: alpha
        ).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect)
    }

    private func drawTargetPulse(in context: CGContext) {
        let appear = smoothStep(0, 0.13, progress)
        let disappear = 1 - smoothStep(0.46, 0.93, progress)
        let alpha = appear * disappear
        guard alpha > 0 else { return }

        let expansion = 3 + 16 * smoothStep(0, 0.7, progress)
        let pulseRect = targetRect.insetBy(dx: -expansion, dy: -expansion * 0.45)
        context.setStrokeColor(NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.26, alpha: alpha * 0.9).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: pulseRect)
    }

    private func drawCracks(in context: CGContext) {
        let reveal = smoothStep(0.06, 0.46, progress)
        let fade = 1 - smoothStep(0.72, 1, progress)
        let alpha = reveal * fade
        guard alpha > 0 else { return }

        let maxReach = min(bounds.width, bounds.height) * 0.43
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for (index, ray) in rays.enumerated() {
            let individualReveal = clamp(reveal * 1.35 - CGFloat(index % 4) * 0.08)
            guard individualReveal > 0 else { continue }
            let alignment = cos(ray.angle) * motionVector.x + sin(ray.angle) * motionVector.y
            let directionalBias = alignment >= 0 ? alignment * 0.82 : alignment * 0.24
            let reachScale = max(0.65, 1 + motionInfluence * directionalBias)
            let reach = maxReach * ray.reach * individualReveal * reachScale
            let middleAngle = ray.angle + ray.bend * 0.42
            let endAngle = ray.angle + ray.bend
            let middle = point(from: impactPoint, angle: middleAngle, distance: reach * 0.54)
            let end = point(from: impactPoint, angle: endAngle, distance: reach)

            context.beginPath()
            context.move(to: impactPoint)
            context.addLine(to: middle)
            context.addLine(to: end)
            context.setStrokeColor(NSColor(calibratedWhite: 0.96, alpha: alpha * 0.92).cgColor)
            context.setShadow(offset: .zero, blur: 2.5, color: NSColor(calibratedWhite: 0, alpha: alpha * 0.68).cgColor)
            context.setLineWidth(index.isMultiple(of: 3) ? 1.7 : 1.05)
            context.strokePath()

            let branchOrigin = point(from: impactPoint, angle: middleAngle, distance: reach * ray.branchAt)
            let branchEnd = point(
                from: branchOrigin,
                angle: endAngle + ray.branchDirection,
                distance: reach * 0.24
            )
            context.beginPath()
            context.move(to: branchOrigin)
            context.addLine(to: branchEnd)
            context.setLineWidth(0.8)
            context.setStrokeColor(NSColor(calibratedWhite: 0.93, alpha: alpha * 0.72).cgColor)
            context.strokePath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func drawShards(in context: CGContext) {
        let launch = smoothStep(0.12, 0.7, progress)
        let fade = 1 - smoothStep(0.68, 1, progress)
        guard launch > 0, fade > 0 else { return }

        for shard in shards {
            let local = clamp((launch - shard.delay) / max(0.01, 1 - shard.delay))
            guard local > 0 else { continue }

            let eased = 1 - pow(1 - local, 2.4)
            let alignment = cos(shard.angle) * motionVector.x + sin(shard.angle) * motionVector.y
            let radialScale = 1 + motionInfluence * max(0, alignment) * 0.34
            var center = point(
                from: impactPoint,
                angle: shard.angle,
                distance: shard.distance * radialScale * eased
            )
            center.x += motionVector.x * motionShardDrift * eased
            center.y += motionVector.y * motionShardDrift * eased
            center.y -= 24 * local * local

            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: shard.spin * local)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -shard.size.width * 0.5, y: -shard.size.height * 0.35))
            path.addLine(to: CGPoint(x: shard.size.width * 0.55, y: -shard.size.height * 0.5))
            path.addLine(to: CGPoint(x: shard.size.width * 0.15, y: shard.size.height * 0.55))
            path.closeSubpath()

            context.addPath(path)
            context.setFillColor(NSColor(calibratedRed: 0.68, green: 0.88, blue: 1, alpha: fade * 0.25).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: fade * 0.82).cgColor)
            context.setLineWidth(0.8)
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawImpact(in context: CGContext) {
        let flash = 1 - smoothStep(0.03, 0.36, progress)
        guard flash > 0 else { return }

        let radius = 5 + 24 * smoothStep(0, 0.28, progress)
        let colors = [
            NSColor(calibratedWhite: 1, alpha: flash * 0.95).cgColor,
            NSColor(calibratedRed: 1, green: 0.62, blue: 0.12, alpha: flash * 0.62).cgColor,
            NSColor.clear.cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.3, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            context.drawRadialGradient(
                gradient,
                startCenter: impactPoint,
                startRadius: 0,
                endCenter: impactPoint,
                endRadius: radius,
                options: .drawsAfterEndLocation
            )
        }

        context.setStrokeColor(NSColor(calibratedRed: 1, green: 0.74, blue: 0.22, alpha: flash).cgColor)
        context.setLineWidth(2.2)
        context.strokeEllipse(in: CGRect(x: impactPoint.x - radius, y: impactPoint.y - radius, width: radius * 2, height: radius * 2))
    }

    private func point(from origin: CGPoint, angle: CGFloat, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + cos(angle) * distance,
            y: origin.y + sin(angle) * distance
        )
    }

    private func smoothStep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let x = clamp((value - edge0) / (edge1 - edge0))
        return x * x * (3 - 2 * x)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var panel: NSPanel?

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let target = appKitRect(fromTopLeftRect: options.rect)
        let motionPadding = CGFloat(options.motion.extraOverlayPadding)
        let horizontalPadding = max(110, min(220, target.width * 0.85)) + motionPadding
        let verticalPadding = max(180, min(280, target.height * 6.5)) + motionPadding
        let windowFrame = target.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
        let localTarget = CGRect(
            x: target.minX - windowFrame.minX,
            y: target.minY - windowFrame.minY,
            width: target.width,
            height: target.height
        )

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let smashView = SmashView(
            frame: CGRect(origin: .zero, size: windowFrame.size),
            targetRect: localTarget,
            duration: options.duration,
            motion: options.motion,
            displayText: options.displayText
        )
        smashView.autoresizingMask = [.width, .height]
        var windowVisibleAtStart = false
        let targetIntersectsScreen = NSScreen.screens.contains { $0.frame.intersects(target) }
        smashView.onFinished = { [weak self, weak panel] metrics in
            guard let self, let panel else { return }
            self.finish(
                panel: panel,
                metrics: metrics,
                windowVisibleAtStart: windowVisibleAtStart,
                targetIntersectsScreen: targetIntersectsScreen
            )
        }
        panel.contentView = smashView
        panel.orderFrontRegardless()
        panel.contentView?.displayIfNeeded()
        panel.displayIfNeeded()
        windowVisibleAtStart = panel.isVisible
        self.panel = panel
        if options.debug {
            let frame = panel.frame
            debugLog(
                "pid=\(ProcessInfo.processInfo.processIdentifier) " +
                "windowNumber=\(panel.windowNumber) " +
                "isVisible=\(panel.isVisible) " +
                "motionDirection=\(options.motion.direction.rawValue) " +
                "motionSpeed=\(options.motion.speed) " +
                "motionDistance=\(options.motion.distance) " +
                "frame={{\(frame.origin.x), \(frame.origin.y)}, {\(frame.size.width), \(frame.size.height)}}"
            )
        }
        smashView.start()
    }

    private func finish(
        panel: NSPanel,
        metrics: RenderMetrics,
        windowVisibleAtStart: Bool,
        targetIntersectsScreen: Bool
    ) {
        if options.reportJSON {
            do {
                var data = try OverlayRenderReportCodec.encode(OverlayRenderReport(
                    framesDrawn: metrics.framesDrawn,
                    glyphFramesDrawn: metrics.glyphFramesDrawn,
                    timerTicks: metrics.timerTicks,
                    durationMilliseconds: Int((options.duration * 1_000).rounded()),
                    elapsedMilliseconds: metrics.elapsedMilliseconds,
                    windowVisibleAtStart: windowVisibleAtStart,
                    targetIntersectsScreen: targetIntersectsScreen,
                    glyphContentRendered: metrics.glyphFramesDrawn > 0,
                    fallbackUsed: options.fallbackUsed
                ))
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                FileHandle.standardError.write(Data("wds-whack: could not write render report\n".utf8))
                panel.orderOut(nil)
                Foundation.exit(EXIT_FAILURE)
            }
        }
        panel.orderOut(nil)
        NSApplication.shared.terminate(nil)
    }

    private func appKitRect(fromTopLeftRect rect: CGRect) -> CGRect {
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let mainDisplayHeight = mainDisplayBounds.height
        return CGRect(
            x: rect.origin.x,
            y: mainDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

private func debugLog(_ message: String) {
    FileHandle.standardError.write(Data("wds-whack[debug]: \(message)\n".utf8))
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    // NSApplication.delegate is weak. A command-line executable has no app
    // delegate owner, so keep it alive for the entire event loop explicitly.
    withExtendedLifetime(delegate) {
        application.run()
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("wds-whack: \(message)\n\n\(Options.usage)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
