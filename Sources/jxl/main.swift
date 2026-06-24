// jxl — command-line front-end for JXLCore.
//
// Usage:
//   jxl info  <file.jxl>     Print dimensions and container layout.
//   jxl boxes <file.jxl>     List ISOBMFF boxes (container files only).

import Foundation
import JXLCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    let text = """
    jxl — pure-Swift JPEG XL tools

    USAGE:
      jxl info  <file.jxl>    Print dimensions and container layout
      jxl boxes <file.jxl>    List ISOBMFF container boxes

    """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

let command = args[1]
let path = args[2]
let url = URL(fileURLWithPath: path)

guard let data = try? Data(contentsOf: url) else {
    fail("error: cannot read \(path)")
}
let bytes = [UInt8](data)

do {
    switch command {
    case "info":
        let info = try JXL.readInfo(from: bytes)
        let kind = info.isContainer ? "container" : "bare codestream"
        print("\(info.width) x \(info.height)  (\(kind))")
        if !info.boxTypes.isEmpty {
            print("boxes: \(info.boxTypes.joined(separator: ", "))")
        }

    case "boxes":
        let parsed = try JXLContainer.parse(bytes)
        if !parsed.isContainer {
            print("bare codestream (no boxes), \(bytes.count) bytes")
        } else {
            for box in parsed.boxes {
                print("'\(box.type)'  \(box.totalSize) bytes  (payload \(box.payload.count))")
            }
        }

    default:
        usage()
    }
} catch {
    fail("error: \(error)")
}
