import AppKit
import CoreGraphics
import CoreText
import SwiftUI

extension FolioBrandIcon {
    /// Draws the Folio squircle icon into a CoreGraphics context.
    public static func drawSquircleIcon(
        in cg: CGContext,
        canvasSize: CGFloat,
        includeMacOSMargin: Bool = true,
        isDark: Bool = false,
        isDevBuild: Bool = false
    ) {
        cg.saveGState()
        cg.translateBy(x: 0, y: canvasSize)
        cg.scaleBy(x: 1, y: -1)

        let marginRatio: CGFloat = includeMacOSMargin
            ? (canvasSize <= 32 ? (56.0 / 1024.0) : (100.0 / 1024.0))
            : 0.0
        let squircleOrigin = canvasSize * marginRatio
        let squircleSize = canvasSize - (squircleOrigin * 2.0)
        let squircleRadius = squircleSize * 0.225

        let squircleRect = CGRect(x: squircleOrigin, y: squircleOrigin, width: squircleSize, height: squircleSize)
        let squirclePath = CGPath(
            roundedRect: squircleRect,
            cornerWidth: squircleRadius,
            cornerHeight: squircleRadius,
            transform: nil
        )

        // Outer squircle drop shadow
        if includeMacOSMargin {
            cg.saveGState()
            let shadowOffsetY = canvasSize * (10.0 / 1024.0)
            let shadowBlur = canvasSize * (26.0 / 1024.0)
            cg.setShadow(
                offset: CGSize(width: 0, height: -shadowOffsetY),
                blur: shadowBlur,
                color: srgb(15, 23, 42, 0.22).cgColor
            )
            cg.setFillColor((isDark ? srgb(30, 36, 43, 1.0) : srgb(245, 242, 235, 1.0)).cgColor)
            cg.addPath(squirclePath)
            cg.fillPath()
            cg.restoreGState()
        }

        // Squircle linear gradient background
        cg.saveGState()
        cg.addPath(squirclePath)
        cg.clip()

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bgColors = (isDark
            ? [srgb(30, 36, 43, 1.0).cgColor, srgb(17, 20, 25, 1.0).cgColor]
            : [srgb(245, 242, 235, 1.0).cgColor, srgb(226, 221, 208, 1.0).cgColor]) as CFArray
        let locations: [CGFloat] = [0.0, 1.0]
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: locations) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: squircleRect.minX, y: squircleRect.minY),
                end: CGPoint(x: squircleRect.maxX, y: squircleRect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let unit = squircleSize / 120.0
        cg.translateBy(x: squircleOrigin, y: squircleOrigin)
        cg.scaleBy(x: unit, y: unit)

        func roundedPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }

        // Bottom card
        let bottomPath = roundedPath(28, 71, 26, 23, 6)
        cg.addPath(bottomPath)
        cg.setFillColor((isDark ? srgb(56, 189, 248, 0.32) : srgb(0, 118, 223, 0.22)).cgColor)
        cg.fillPath()
        cg.addPath(bottomPath)
        cg.setStrokeColor((isDark ? srgb(56, 189, 248, 0.80) : srgb(0, 118, 223, 0.72)).cgColor)
        cg.setLineWidth(isDark ? 1.4 : 1.5)
        cg.strokePath()

        // Middle card
        let middlePath = roundedPath(28, 47.5, 49, 21, 6)
        cg.addPath(middlePath)
        cg.setFillColor((isDark ? srgb(147, 197, 253, 0.62) : srgb(147, 197, 253, 0.76)).cgColor)
        cg.fillPath()
        cg.addPath(middlePath)
        cg.setStrokeColor((isDark ? srgb(191, 219, 254, 0.75) : srgb(37, 99, 235, 0.58)).cgColor)
        cg.setLineWidth(1.3)
        cg.strokePath()

        // Top card
        let topPath = roundedPath(28, 24, 64, 21, 6)
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -3.0 * unit),
            blur: 7.0 * unit,
            color: (isDark ? srgb(0, 0, 0, 0.45) : srgb(15, 23, 42, 0.14)).cgColor
        )
        cg.addPath(topPath)
        cg.setFillColor((isDark ? srgb(250, 249, 245, 1.0) : srgb(255, 255, 255, 1.0)).cgColor)
        cg.fillPath()
        cg.restoreGState()

        if !isDark {
            cg.addPath(topPath)
            cg.setStrokeColor(srgb(15, 23, 42, 0.09).cgColor)
            cg.setLineWidth(1.0)
            cg.strokePath()
        }

        // Top card details
        let dotRect = CGRect(x: 41.0 - 4.5, y: 34.5 - 4.5, width: 9.0, height: 9.0)
        cg.setFillColor(srgb(234, 88, 12, 1.0).cgColor)
        cg.fillEllipse(in: dotRect)

        let barPath = roundedPath(50, 32, 28, 5, 2.5)
        cg.addPath(barPath)
        cg.setFillColor((isDark ? srgb(24, 28, 34, 0.78) : srgb(51, 65, 85, 0.78)).cgColor)
        cg.fillPath()

        if isDevBuild {
            drawDevBanner(in: cg, unit: unit, colorSpace: colorSpace)
        }

        cg.restoreGState()

        // Outer squircle border
        cg.saveGState()
        cg.addPath(squirclePath)
        cg.setStrokeColor((isDark ? srgb(255, 255, 255, 0.10) : srgb(15, 23, 42, 0.10)).cgColor)
        cg.setLineWidth(max(1.0, canvasSize * (1.5 / 1024.0)))
        cg.strokePath()
        cg.restoreGState()

        cg.restoreGState()
    }

    /// Draws a high-contrast `DEV` pill badge in the 120x120 squircle coordinate space.
    static func drawDevBanner(
        in cg: CGContext,
        unit: CGFloat,
        colorSpace: CGColorSpace
    ) {
        let badgeRect = CGRect(x: 34, y: 76, width: 78, height: 32)
        let badgePath = CGPath(
            roundedRect: badgeRect,
            cornerWidth: 9.5,
            cornerHeight: 9.5,
            transform: nil
        )

        // Drop shadow behind the DEV pill
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -3.5 * unit),
            blur: 8.0 * unit,
            color: srgb(15, 23, 42, 0.38).cgColor
        )
        cg.addPath(badgePath)
        cg.setFillColor(srgb(234, 88, 12, 1.0).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // Vibrant orange-red fill gradient
        cg.saveGState()
        cg.addPath(badgePath)
        cg.clip()
        let badgeColors = [
            srgb(249, 115, 22, 1.0).cgColor,
            srgb(217, 56, 15, 1.0).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: badgeColors, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: badgeRect.minX, y: badgeRect.minY),
                end: CGPoint(x: badgeRect.minX, y: badgeRect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        cg.restoreGState()

        // Crisp high-contrast border around the DEV pill
        cg.saveGState()
        cg.addPath(badgePath)
        cg.setStrokeColor(srgb(255, 255, 255, 0.94).cgColor)
        cg.setLineWidth(2.2)
        cg.strokePath()
        cg.restoreGState()

        // Bold "DEV" label centered inside the pill (unflip Y locally for CoreText)
        cg.saveGState()
        cg.translateBy(x: badgeRect.midX, y: badgeRect.midY)
        cg.scaleBy(x: 1, y: -1)

        let font = NSFont.systemFont(ofSize: 20.5, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: srgb(255, 255, 255, 1.0),
            .kern: 1.2,
        ]
        let attrString = NSAttributedString(string: "DEV", attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: -glyphBounds.midX, y: -glyphBounds.midY)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
