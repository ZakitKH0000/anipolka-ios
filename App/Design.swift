import SwiftUI
import UIKit

enum ShelfDesign {
    private static let standard = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.045,green:0.052,blue:0.064,alpha:1) : UIColor(red:0.96,green:0.965,blue:0.98,alpha:1) })
    private static let oled = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : UIColor(red:0.96,green:0.965,blue:0.98,alpha:1) })
    /// Views observe the store, so they redraw when the OLED preference changes.
    @MainActor static var background: Color { ShelfStore.shared.snapshot.preferences.pureBlack ? oled : standard }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var askTarget = false
    @State private var target = ""
    var body: some View {
        Button {
            store.increment(entry)
            guard !reduceMotion else { return }
            withAnimation(.spring(response:0.22,dampingFraction:0.5)) { pulse = true }
            Task { try? await Task.sleep(for:.milliseconds(180)); withAnimation(.spring(response:0.3,dampingFraction:0.7)) { pulse = false } }
        } label: {
            Text("+1").font(.title3.bold()).foregroundStyle(.blue).frame(minWidth:48,minHeight:48)
                .padding(.horizontal,4).shelfGlass(in: Capsule()).scaleEffect(pulse ? 1.18 : 1)
        }.buttonStyle(.plain).disabled(entry.episode >= 1_000_000)
            // Several episodes at once: long press.
            .contextMenu {
                ForEach([2,3,5],id:\.self) { n in Button("+\(n) \(episodesWord(n))") { store.increment(entry,by:n) } }
                Button("До серии…",systemImage:"number") { target = String(entry.episode + 1); askTarget = true }
            }
            .alert("До какой серии отметить?",isPresented:$askTarget) {
                TextField("Номер серии",text:$target).keyboardType(.numberPad)
                Button("Отметить") { if let n = Int(target.trimmingCharacters(in:.whitespaces)), n > entry.episode { store.increment(entry,by:n - entry.episode) } }
                Button("Отмена",role:.cancel) {}
            } message: { Text("Сейчас отмечена серия \(entry.episode). Можно только увеличить номер; уменьшить — в «Изменить».") }
            .accessibilityLabel("Следующая серия: \(entry.title)").accessibilityHint("Сейчас просмотрена серия \(entry.episode)")
            .accessibilityIdentifier("increment-\(entry.id)")
    }
}
