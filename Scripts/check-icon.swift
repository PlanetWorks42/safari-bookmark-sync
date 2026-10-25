import AppKit

let appPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let icon = NSWorkspace.shared.icon(forFile: appPath)
icon.size = NSSize(width: 512, height: 512)
guard let data = icon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to read system app icon")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("System icon preview saved to: \(outputPath)")
