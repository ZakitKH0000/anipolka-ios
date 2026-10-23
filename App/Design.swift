import SwiftUI
import UIKit

enum ShelfDesign {
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.045,green:0.052,blue:0.064,alpha:1) : UIColor(red:0.96,green:0.965,blue:0.98,alpha:1) })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}
struct NativeGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased { content.background(ShelfDesign.surface,in:shape).overlay(shape.stroke(.secondary.opacity(0.5))) }
        else if #available(iOS 26.0, *) { content.glassEffect(.regular.interactive(),in:shape) }
        else { content.background(.regularMaterial,in:shape) }
    }
}
extension View { func shelfGlass<S: Shape>(in shape: S) -> some View { modifier(NativeGlass(shape:shape)) } }
struct IncrementButton: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        Button { store.increment(entry) } label: {
            Text("+1").font(.title3.bold()).foregroundStyle(.blue).frame(minWidth:48,minHeight:48)
                .padding(.horizontal,4).shelfGlass(in: Capsule())
        }.buttonStyle(.plain).disabled(entry.episode >= 1_000_000)
            .accessibilityLabel("Следующая серия: \(entry.title)").accessibilityHint("Сейчас просмотрена серия \(entry.episode)")
            .accessibilityIdentifier("increment-\(entry.id)")
    }
}
