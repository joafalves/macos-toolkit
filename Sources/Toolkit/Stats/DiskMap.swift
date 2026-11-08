import AppKit
import SwiftUI

/// What takes space on the startup disk, on the Disk tab: a scan only when
/// asked for, then the folders as blocks by size, to go into one by one.
struct DiskMapCard: View {
    @ObservedObject var space: DiskSpace

    var body: some View {
        Card(title: "What Takes Space") {
            VStack(alignment: .leading, spacing: 10) {
                switch space.state {
                case .idle: idle
                case .scanning(let share, let items): scanning(share, items)
                case .done(let result): done(result)
                }
            }
            .padding(14)
        }
    }

    private var idle: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Goes through the startup disk's folders in the background and shows them by size. Takes a minute or so, and changes nothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Scan") { space.scan() }
        }
    }

    private func scanning(_ share: Double, _ items: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: share)
                Button("Cancel") { space.cancel() }
            }
            Text("\(items) items looked at")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func done(_ result: DiskSpace.Result) -> some View {
        let current = space.current ?? result.root
        HStack(alignment: .firstTextBaseline) {
            Trail(item: current) { space.current = $0 }
            Spacer(minLength: 8)
            Text(StatsController.bytes(current.size))
                .font(.headline.monospacedDigit())
        }
        Treemap(item: current) { space.current = $0 }
            .frame(height: 300)
        ItemList(item: current) { space.current = $0 }
        HStack(alignment: .firstTextBaseline) {
            Text("Scanned \(result.at, format: .relative(presentation: .named)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Scan Again") { space.scan() }
        }
        if result.unreadable > 0 {
            Banner(text: "\(result.unreadable) folders couldn't be read, such as Mail's and Messages'. To count them, allow MacOS Toolkit in Full Disk Access, then scan again.",
                   button: "Open System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
    }
}

/// The colour of each of a folder's items, in its order: the same in the map and the list.
private func color(_ item: SpaceItem, _ index: Int) -> Color {
    switch item.kind {
    case .smaller: return .gray.opacity(0.55)
    case .other: return .gray.opacity(0.3)
    case .folder, .file:
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .yellow, .mint, .cyan, .red, .brown]
        return palette[index % palette.count]
    }
}

private func describe(_ item: SpaceItem) -> String {
    switch item.kind {
    case .smaller(let count): return String(localized: "\(count) items, each too small to show")
    case .other: return String(localized: "macOS itself, local Time Machine snapshots, and folders that couldn't be read")
    case .folder, .file: return item.path ?? item.name
    }
}

private func reveal(_ item: SpaceItem) {
    guard var path = item.path else { return }
    // The data volume's top folders show at the top of the disk, but not every one of them.
    if !FileManager.default.fileExists(atPath: path) { path = DiskSpace.dataVolume + path }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// From the disk down to the folder shown, each one a way back up.
private struct Trail: View {
    let item: SpaceItem
    let open: (SpaceItem) -> Void

    var body: some View {
        let trail = item.trail
        // A deep folder shows its disk and the last two, so the line fits.
        let shown: [SpaceItem?] = trail.count > 4 ? [trail[0], nil] + trail.suffix(2) : trail
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if let step {
                    if step === item {
                        Text(verbatim: step.name).font(.headline).lineLimit(1)
                    } else {
                        Button { open(step) } label: { Text(verbatim: step.name).lineLimit(1) }
                            .buttonStyle(.link)
                    }
                } else {
                    Text(verbatim: "…").foregroundStyle(.secondary)
                }
            }
        }
        .truncationMode(.middle)
    }
}

/// A folder's items as blocks, each as large as the space it takes, with
/// its own largest items drawn inside it.
private struct Treemap: View {
    let item: SpaceItem
    let open: (SpaceItem) -> Void

    var body: some View {
        GeometryReader { geometry in
            let children = item.children.filter { $0.size > 0 }
            let rects = Squarify.layout(children.map { Double($0.size) }, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let rect = rects[index]
                    if rect.width >= 2, rect.height >= 2 {
                        Block(item: child, color: color(child, index), size: rect.size, open: open)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct Block: View {
    let item: SpaceItem
    let color: Color
    let size: CGSize
    let open: (SpaceItem) -> Void

    private var coloured: Bool { item.kind == .folder || item.kind == .file }

    var body: some View {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color.opacity(0.7))
            // One level further in, as outlines, so a folder shows what it's made of.
            if item.kind == .folder, frame.width > 24, frame.height > 24 {
                let inner = Array(item.children.filter { $0.size > 0 }.prefix(40))
                let rects = Squarify.layout(inner.map { Double($0.size) }, in: CGRect(origin: .zero, size: frame.size).insetBy(dx: 3, dy: 3))
                ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                    if rect.width >= 3, rect.height >= 3 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            if frame.width > 64, frame.height > 32 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(StatsController.bytes(item.size)).font(.caption2.monospacedDigit()).lineLimit(1)
                }
                // The grey blocks are pale in light mode: the page's own text colour there.
                .foregroundStyle(coloured ? Color.white : Color.primary)
                .shadow(color: .black.opacity(coloured ? 0.35 : 0), radius: 1, y: 0.5)
                .padding(5)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { if item.canOpen { open(item) } }
        .help(Text(verbatim: "\(item.name), \(StatsController.bytes(item.size))\n\(describe(item))"))
        .contextMenu {
            if item.path != nil {
                Button("Show in Finder") { reveal(item) }
            }
        }
    }
}

/// The largest of a folder's items, as a list: the map's colours, names
/// that may be too long for a block, and a way in.
private struct ItemList: View {
    let item: SpaceItem
    let open: (SpaceItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.children.prefix(8).enumerated()), id: \.element.id) { index, child in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color(child, index)).frame(width: 10, height: 10)
                    Image(systemName: symbol(child)).foregroundStyle(.secondary).frame(width: 16)
                    Text(verbatim: child.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(StatsController.bytes(child.size)).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(child.canOpen ? 1 : 0)
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture { if child.canOpen { open(child) } }
                .help(describe(child))
                .contextMenu {
                    if child.path != nil {
                        Button("Show in Finder") { reveal(child) }
                    }
                }
            }
        }
    }

    private func symbol(_ item: SpaceItem) -> String {
        switch item.kind {
        case .folder: return "folder"
        case .file: return "doc"
        case .smaller: return "square.grid.3x3"
        case .other: return "gearshape"
        }
    }
}

/// Blocks whose areas are their values, kept as square as can be (Bruls,
/// Huizing and van Wijk's squarified treemap), from values largest first.
enum Squarify {
    static func layout(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { $0 * scale }
        var rect = bounds
        var start = 0
        while start < areas.count {
            let side = Double(min(rect.width, rect.height))
            var end = start + 1
            var best = worst(areas[start..<end], side)
            // Another block in the row while it leaves them squarer.
            while end < areas.count {
                let next = worst(areas[start...end], side)
                if next > best { break }
                best = next
                end += 1
            }
            let sum = areas[start..<end].reduce(0, +)
            if rect.width >= rect.height {
                // A column down the left.
                let width = rect.height > 0 ? CGFloat(sum / Double(rect.height)) : 0
                var y = rect.minY
                for index in start..<end {
                    let height = width > 0 ? CGFloat(areas[index]) / width : 0
                    result[index] = CGRect(x: rect.minX, y: y, width: width, height: height)
                    y += height
                }
                rect = CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
            } else {
                // A row along the top.
                let height = rect.width > 0 ? CGFloat(sum / Double(rect.width)) : 0
                var x = rect.minX
                for index in start..<end {
                    let width = height > 0 ? CGFloat(areas[index]) / height : 0
                    result[index] = CGRect(x: x, y: rect.minY, width: width, height: height)
                    x += width
                }
                rect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
            }
            start = end
        }
        return result
    }

    /// The most a block in the row is off square, as long side over short.
    private static func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }
}
