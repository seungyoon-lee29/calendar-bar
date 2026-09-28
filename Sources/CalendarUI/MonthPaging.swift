import SwiftUI
import CalendarCore

/// Visual drag state is separate from the selected month until settling finishes.
struct MonthPagingState {
    private(set) var offset: Double = 0
    private(set) var isSettling = false
    private var revision = 0

    mutating func drag(x: Double, y: Double, width: Double) {
        guard !isSettling else { return }
        offset = abs(x) > abs(y) ? min(width, max(-width, x)) : 0
    }

    mutating func settle(direction: Int?, width: Double) -> Int? {
        guard !isSettling else { return nil }
        revision += 1
        isSettling = true
        offset = direction.map { -Double($0) * width } ?? 0
        return revision
    }

    mutating func finish(_ token: Int) -> Bool {
        guard isSettling, revision == token else { return false }
        reset()
        return true
    }

    mutating func reset() {
        revision += 1
        offset = 0
        isSettling = false
    }
}

/// Equatable pages avoid rebuilding labels and event dots on every pointer movement.
struct MonthGridPage: View, Equatable {
    let state: CalendarState
    let events: [EventOccurrence]
    let onSelect: (Date) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.events == rhs.events
    }

    var body: some View {
        let calendar = state.context.calendar
        let formatter = DateFormatter()
        let _ = {
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy년 M월 d일 EEEE"
        }()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
            ForEach(state.grid.days, id: \.self) { day in
                let today = calendar.isDate(day, inSameDayAs: state.today)
                let selected = calendar.isDate(day, inSameDayAs: state.selectedDate)
                let inMonth = calendar.isDate(day, equalTo: state.displayedMonth, toGranularity: .month)
                let colors = EventIndex.colors(on: day, in: events, context: state.context)
                Button { onSelect(day) } label: {
                    VStack(spacing: 3) {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 13, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.45))
                            .frame(width: 29, height: 29)
                            .background { if today { Circle().fill(Color.blue) } }
                            .overlay { if selected && !today { Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1) } }
                        HStack(spacing: 2) {
                            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                                Circle().fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)).frame(width: 3, height: 3)
                            }
                            if colors.count > 3 { Text("+").font(.system(size: 7)).foregroundStyle(.secondary) }
                        }.frame(height: 5)
                    }.frame(maxWidth: .infinity).frame(height: 38).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(formatter.string(from: day) + (today ? ", 오늘" : "") + (selected ? ", 선택됨" : ""))
            }
        }.padding(.horizontal, 16)
    }
}
