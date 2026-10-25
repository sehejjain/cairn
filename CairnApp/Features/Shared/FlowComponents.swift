import SwiftUI
import SwiftData
import Charts
import CairnCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Flow groups related information with spacing and rules, leaving material
/// backgrounds to navigation, controls, and editing surfaces.
struct FlowSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowLinkRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var subtitle: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(CairnTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct FlowBudgetRuler: View {
    let spent: Int64
    let planned: Int64
    let currency: Currency

    private var fraction: Double {
        guard planned > 0 else { return 0 }
        return min(1, max(0, Double(spent) / Double(planned)))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(CairnTheme.outline)
                    Capsule().fill(CairnTheme.accent)
                        .frame(width: geometry.size.width * fraction)
                    Circle().fill(CairnTheme.accent)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(CairnTheme.canvas, lineWidth: 3))
                        .offset(x: max(0, min(geometry.size.width - 16, geometry.size.width * fraction - 8)))
                }
            }
            .frame(height: 10)
            HStack {
                Text(Money(minorUnits: 0, currency: currency).compactFormatted())
                Spacer()
                Text(Money(minorUnits: planned, currency: currency).compactFormatted())
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Planned category spending")
        .accessibilityValue(Text("\(spentAmount) of \(plannedAmount)"))
    }

    private var spentAmount: String { Money(minorUnits: spent, currency: currency).formatted() }
    private var plannedAmount: String { Money(minorUnits: planned, currency: currency).formatted() }
}

struct FlowChartPoint: Identifiable {
    let date: Date
    let minorUnits: Int64
    var id: Date { date }

    static func nearest(to date: Date?, in points: [Self]) -> Self? {
        guard let date else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

/// Shared chart anatomy for Today and Wealth: a solid line, quiet currency
/// axes, and a stable readout. No fabricated values are used for empty history.
struct FlowLineChart: View {
    let points: [FlowChartPoint]
    let currency: Currency
    let title: LocalizedStringKey
    var includesZero = false
    var compact = false
    @Binding var selection: Date?
    @ScaledMetric(relativeTo: .body) private var chartHeight = 180.0

    private var selected: FlowChartPoint? {
        FlowChartPoint.nearest(to: selection, in: points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !points.isEmpty {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Amount", value(point.minorUnits)))
                            .foregroundStyle(CairnTheme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                            .accessibilityLabel(Text(point.date, format: .dateTime.month().day()))
                            .accessibilityValue(Text(Money(minorUnits: point.minorUnits, currency: currency).formatted()))
                    }
                    if points.count == 1, let point = points.first {
                        PointMark(x: .value("Date", point.date), y: .value("Amount", value(point.minorUnits)))
                            .foregroundStyle(CairnTheme.accent)
                    }
                    if let selected {
                        RuleMark(x: .value("Date", selected.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                        PointMark(x: .value("Date", selected.date), y: .value("Amount", value(selected.minorUnits)))
                            .foregroundStyle(CairnTheme.accent)
                    }
                }
                .flowChartSelection($selection)
                .chartYScale(domain: .automatic(includesZero: includesZero))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { axis in
                        AxisGridLine().foregroundStyle(CairnTheme.hairline)
                        AxisValueLabel {
                            if let amount = axis.as(Double.self) {
                                Text(currency.isCustom
                                     ? amount.formatted(.number.notation(.compactName))
                                     : amount.formatted(.currency(code: currency.code).notation(.compactName)
                                        .precision(.fractionLength(0...1))))
                            }
                        }
                    }
                }
                .frame(height: chartHeight * (compact ? 0.75 : 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityHint("Drag to update the amount and date above the chart")
                .accessibilityValue(Text(selectionDescription))
                .accessibilityChartDescriptor(chartDescriptor)
                .accessibilityAdjustableAction { direction in
                    let index = selected.flatMap { selected in points.firstIndex { $0.id == selected.id } }
                    switch direction {
                    case .increment: selection = points[min((index ?? -1) + 1, points.count - 1)].date
                    case .decrement: selection = points[max((index ?? points.count) - 1, 0)].date
                    @unknown default: break
                    }
                }
                .sensoryFeedback(.selection, trigger: selected?.id)
            } else {
                Text("History appears as transactions are added.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .onChange(of: points.map(\.id)) { _, _ in selection = nil }
    }

    private func value(_ minorUnits: Int64) -> Double {
        NSDecimalNumber(decimal: Money(minorUnits: minorUnits, currency: currency).decimal).doubleValue
    }

    private var selectionDescription: String {
        guard let point = selected ?? points.last else { return "" }
        let date = point.date.formatted(date: .abbreviated, time: .omitted)
        let amount = Money(minorUnits: point.minorUnits, currency: currency).formatted()
        return "\(date), \(amount)"
    }

    private var chartDescriptor: AccessibleChart {
        AccessibleChart(
            title: String(localized: "Amount by date"), summary: selectionDescription,
            xTitle: String(localized: "Date"), yTitle: String(localized: "Amount"),
            lines: [.init(name: String(localized: "Amount"), isContinuous: true,
                          points: points.map { (x: $0.date.timeIntervalSince1970, y: value($0.minorUnits)) })],
            describesX: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) },
            describesY: { amount in
                currency.isCustom
                    ? "\(amount.formatted()) \(currency.displayLabel)"
                    : amount.formatted(.currency(code: currency.code))
            }
        )
    }
}

extension View {
    /// Inspect horizontal motion while allowing the enclosing page to scroll
    /// vertically. Selection belongs to the headline and persists after release.
    func flowChartSelection<Value: Plottable>(_ selection: Binding<Value?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            FlowChartHorizontalPan { start, location in
                                guard plot.contains(start) else { return }
                                let position = min(max(0, location.x - plot.minX), plot.width)
                                if let value: Value = proxy.value(atX: position) {
                                    selection.wrappedValue = value
                                }
                            }
                        )
                        .simultaneousGesture(SpatialTapGesture().onEnded { event in
                            guard plot.contains(event.location) else { return }
                            if let value: Value = proxy.value(atX: event.location.x - plot.minX) {
                                selection.wrappedValue = value
                            }
                        })
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

#if os(iOS)
/// Rejects vertical movement before it can compete with a containing ScrollView.
private struct FlowChartHorizontalPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let location = context.converter.location(in: .local)
        if recognizer.state == .began { context.coordinator.startLocation = location }
        if let startLocation = context.coordinator.startLocation {
            onChanged(startLocation, location)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var startLocation: CGPoint?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#elseif os(macOS)
/// Rejects vertical movement before it can compete with a containing ScrollView.
private struct FlowChartHorizontalPan: NSGestureRecognizerRepresentable {
    let onChanged: (CGPoint, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeNSGestureRecognizer(context: Context) -> NSPanGestureRecognizer {
        let recognizer = NSPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSPanGestureRecognizer, context: Context) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let location = context.converter.location(in: .local)
        if recognizer.state == .began { context.coordinator.startLocation = location }
        if let startLocation = context.coordinator.startLocation {
            onChanged(startLocation, location)
        }
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var startLocation: CGPoint?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? NSPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            return abs(translation.x) > abs(translation.y)
        }
    }
}
#endif

struct FlowUpcomingPayments: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query private var commitments: [ConfirmedCommitment]
    let currency: Currency
    var limit = 2

    private struct Item: Identifiable {
        let id: String
        let name: String
        let date: Date
        let amount: Int64
        let confirmedID: UUID?
    }

    private var items: [Item] {
        let start = Calendar.current.startOfDay(for: .now)
        let known = Set(commitments.map(\.detectorID))
        let confirmed = commitments.filter {
            $0.currency == currency && $0.state == .active && $0.nextDueDate >= start && $0.amountMinorUnits < 0
        }.map {
            Item(id: $0.uuid.uuidString, name: $0.name, date: $0.nextDueDate,
                 amount: $0.amountMinorUnits, confirmedID: $0.uuid)
        }
        let detected = model.recurringSeries.filter {
            $0.currency == currency && $0.direction == .outgoing && $0.nextExpectedDate >= start && !known.contains($0.id)
        }.map {
            Item(id: $0.id, name: $0.displayName, date: $0.nextExpectedDate,
                 amount: $0.averageAmountMinorUnits, confirmedID: nil)
        }
        return Array((confirmed + detected).sorted { $0.date < $1.date }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenSectionHeader("Coming up") {
                NavigationLink { RecurringView() } label: {
                    Text("See all").font(.subheadline).frame(minHeight: 44)
                }
            }
            if items.isEmpty {
                Text("No upcoming payments found. Confirm recurring bills to build your plan.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items) { item in
                    NavigationLink {
                        RecurringView(initialCommitmentID: item.confirmedID)
                    } label: {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 3) {
                                Text(item.date, format: .dateTime.day()).font(.title3.weight(.medium))
                                Text(item.date, format: .dateTime.month(.abbreviated)).font(.caption)
                                Rectangle().fill(CairnTheme.outline).frame(width: 1, height: 24)
                            }
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32)
                            VStack(alignment: .leading, spacing: 8) {
                                paymentLayout {
                                    Text(item.name).font(.body.weight(.medium))
                                    if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                                    AmountText(money: Money(minorUnits: MinorUnits.absClamped(item.amount), currency: currency))
                                }
                                Text(item.confirmedID == nil ? "Expected · based on past activity" : "Planned · not yet posted")
                                    .font(.caption).foregroundStyle(.secondary)
                                Divider()
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await model.refreshRecurring() }
    }

    private var paymentLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }
}
