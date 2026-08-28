#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cornerRadius: CGFloat = 13
let paths = CommandLine.arguments.dropFirst()

guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("Usage: mask_screenshot_corners.swift <png> [...]\n".utf8))
    exit(2)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        FileHandle.standardError.write(Data("Cannot read PNG: \(path)\n".utf8))
        exit(1)
    }

    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.clear(bounds)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let cleanBounds = bounds.insetBy(dx: 1, dy: 1)
    context.addPath(CGPath(
        roundedRect: cleanBounds,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    ))
    context.clip()
    context.draw(image, in: bounds)

    guard let maskedImage = context.makeImage() else {
        FileHandle.standardError.write(Data("Cannot mask PNG: \(path)\n".utf8))
        exit(1)
    }

    let temporaryURL = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).masked-\(UUID().uuidString)")
    guard
        let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        FileHandle.standardError.write(Data("Cannot create PNG: \(path)\n".utf8))
        exit(1)
    }

    CGImageDestinationAddImage(destination, maskedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        try? FileManager.default.removeItem(at: temporaryURL)
        FileHandle.standardError.write(Data("Cannot write PNG: \(path)\n".utf8))
        exit(1)
    }

    do {
        let data = try Data(contentsOf: temporaryURL)
        try data.write(to: url, options: .atomic)
        try FileManager.default.removeItem(at: temporaryURL)
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        FileHandle.standardError.write(Data("Cannot replace PNG \(path): \(error)\n".utf8))
        exit(1)
    }
}
