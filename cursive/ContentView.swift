//
//  ContentView.swift
//  cursive
//
//  Created by Sara Abdullahi on 29/07/2026.
//

import SwiftUI
import PencilKit
import CoreText

// MARK: - Vocab model

struct VocabWord: Identifiable {
    let id = UUID()
    let russian: String
    let english: String
}

let sampleWords: [VocabWord] = [
    .init(russian: "привет",  english: "hello"),
    .init(russian: "спасибо", english: "thank you"),
    .init(russian: "вода",    english: "water"),
    .init(russian: "книга",   english: "book"),
    .init(russian: "друг",    english: "friend"),
]

// MARK: - Glyph template (font -> fitted CGPath)

enum Template {

    static func font(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .regular)
    }

    static func path(for word: String, in rect: CGRect, padding: CGFloat = 24) -> CGPath {
        let uiFont = font(size: 150)
        let attr = NSAttributedString(string: word, attributes: [.font: uiFont])
        let line = CTLineCreateWithAttributedString(attr)
        let raw = CGMutablePath()

        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            let runUIFont = (attributes[.font] as? UIFont) ?? uiFont
            let ctFont = CTFontCreateWithName(runUIFont.fontName as CFString,
                                              runUIFont.pointSize, nil)

            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for i in 0..<count {
                guard let gp = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) else { continue }
                let move = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                raw.addPath(gp, transform: move)
            }
        }

        let box = raw.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return raw }

        let availW = rect.width  - 2 * padding
        let availH = rect.height - 2 * padding
        let s = min(availW / box.width, availH / box.height)
        let offsetX = (availW - box.width  * s) / 2
        let offsetY = (availH - box.height * s) / 2

        var t = CGAffineTransform(
            a: s, b: 0, c: 0, d: -s,
            tx: rect.minX + padding + offsetX - box.minX * s,
            ty: rect.minY + padding + offsetY + box.maxY * s
        )
        return raw.copy(using: &t) ?? raw
    }
}

// MARK: - Sampling a CGPath into points

extension CGPath {
    func sampledPoints() -> [CGPoint] {
        var pts: [CGPoint] = []
        var current = CGPoint.zero
        var startPt = CGPoint.zero

        func addLine(_ a: CGPoint, _ b: CGPoint, steps: Int) {
            for k in 1...max(steps, 1) {
                let f = CGFloat(k) / CGFloat(max(steps, 1))
                pts.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        func addQuad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, steps: Int) {
            for k in 1...steps {
                let f = CGFloat(k) / CGFloat(steps), m = 1 - f
                pts.append(CGPoint(x: m*m*a.x + 2*m*f*c.x + f*f*b.x,
                                   y: m*m*a.y + 2*m*f*c.y + f*f*b.y))
            }
        }
        func addCubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, steps: Int) {
            for k in 1...steps {
                let f = CGFloat(k) / CGFloat(steps), m = 1 - f
                pts.append(CGPoint(x: m*m*m*a.x + 3*m*m*f*c1.x + 3*m*f*f*c2.x + f*f*f*b.x,
                                   y: m*m*m*a.y + 3*m*m*f*c1.y + 3*m*f*f*c2.y + f*f*f*b.y))
            }
        }

        applyWithBlock { ptr in
            let e = ptr.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; startPt = current; pts.append(current)
            case .addLineToPoint:
                addLine(current, e.points[0], steps: 6); current = e.points[0]
            case .addQuadCurveToPoint:
                addQuad(current, e.points[0], e.points[1], steps: 12); current = e.points[1]
            case .addCurveToPoint:
                addCubic(current, e.points[0], e.points[1], e.points[2], steps: 14); current = e.points[2]
            case .closeSubpath:
                addLine(current, startPt, steps: 6); current = startPt
            @unknown default:
                break
            }
        }
        return pts
    }
}

// MARK: - Scoring

struct ScoreResult {
    let coverage: Double
    let precision: Double
    var passed: Bool { coverage >= 0.75 && precision >= 0.5 }
}

enum Scorer {
    static func score(template: [CGPoint], user: [CGPoint], tolerance: CGFloat = 26) -> ScoreResult {
        guard !template.isEmpty, !user.isEmpty else { return ScoreResult(coverage: 0, precision: 0) }
        let tol2 = tolerance * tolerance
        func near(_ p: CGPoint, _ cloud: [CGPoint]) -> Bool {
            for q in cloud {
                let dx = p.x - q.x, dy = p.y - q.y
                if dx*dx + dy*dy <= tol2 { return true }
            }
            return false
        }
        let covered = template.reduce(0) { $0 + (near($1, user) ? 1 : 0) }
        let precise = user.reduce(0) { $0 + (near($1, template) ? 1 : 0) }
        return ScoreResult(coverage: Double(covered) / Double(template.count),
                           precision: Double(precise) / Double(user.count))
    }
}

// MARK: - PencilKit canvas

struct PencilCanvas: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor.label, width: 7)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

// MARK: - Main view

struct ContentView: View {
    @State private var canvas = PKCanvasView()
    @State private var words = sampleWords
    @State private var index = 0
    @State private var showOutline = true
    @State private var result: ScoreResult?
    @State private var canvasSize: CGSize = .zero

    private var word: VocabWord { words[index] }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(word.english)
                    .font(.title2).foregroundStyle(.secondary)
                if showOutline {
                    Text(word.russian)
                        .font(.headline).foregroundStyle(.tertiary)
                }
            }
            .padding(.top)

            GeometryReader { geo in
                let rect = CGRect(origin: .zero, size: geo.size)
                let templatePath = Template.path(for: word.russian, in: rect)
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground))
                    if showOutline {
                        Path(templatePath).fill(Color.gray.opacity(0.28))
                    }
                    PencilCanvas(canvas: canvas)
                }
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            }
            .frame(height: 300)
            .padding(.horizontal)

            if let r = result {
                VStack(spacing: 2) {
                    Text(r.passed ? "✓ Correct!" : "Keep going")
                        .font(.headline)
                        .foregroundStyle(r.passed ? .green : .orange)
                    Text(String(format: "coverage %.0f%%  ·  precision %.0f%%",
                                r.coverage * 100, r.precision * 100))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Clear") { clear() }.buttonStyle(.bordered)
                Button("Check") { check() }.buttonStyle(.borderedProminent)
                Button(showOutline ? "Hide outline" : "Show outline") { showOutline.toggle() }
                    .buttonStyle(.bordered)
            }

            Button("Next word →") { nextWord() }
                .buttonStyle(.bordered)
                .disabled(!(result?.passed ?? false))

            Spacer()
        }
        .padding()
    }

    private func clear() {
        canvas.drawing = PKDrawing()
        result = nil
    }

    private func nextWord() {
        index = (index + 1) % words.count
        showOutline = true
        clear()
    }

    private func check() {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let template = Template.path(for: word.russian, in: rect).sampledPoints()
        var user: [CGPoint] = []
        for stroke in canvas.drawing.strokes {
            let t = stroke.transform
            for p in stroke.path.interpolatedPoints(by: .distance(6)) {
                user.append(p.location.applying(t))
            }
        }
        result = Scorer.score(template: template, user: user)
    }
}

#Preview {
    ContentView()
}
