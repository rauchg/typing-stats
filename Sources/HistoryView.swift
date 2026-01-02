import SwiftUI
import Charts
import Cocoa

struct DailyData: Identifiable {
    let id = UUID()
    let date: Date
    let dateString: String
    let count: Int
}

struct HistoryView: View {
    let syncData: SyncData
    let dataFileURL: URL?
    @State private var selectedDays = 30

    private var dailyData: [DailyData] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var data: [DailyData] = []
        for i in 0..<selectedDays {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateString = formatter.string(from: date)
            let count = syncData.totalCount(for: dateString)
            data.append(DailyData(date: date, dateString: dateString, count: count))
        }
        return data
    }

    private var chartData: [DailyData] {
        Array(dailyData.reversed())
    }

    private let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Chart section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Keystroke History")
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $selectedDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                Chart(chartData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("Count", item.count)
                    )
                    .foregroundStyle(.blue.gradient)
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, selectedDays / 7))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
            }
            .padding()

            Divider()

            // List section
            List(dailyData) { item in
                HStack {
                    Text(displayFormatter.string(from: item.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatNumber(item.count))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Open Data Folder") {
                    if let url = dataFileURL {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
                .buttonStyle(.link)
                .padding()
            }
        }
        .frame(width: 400, height: 500)
    }

    private func formatNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let frameKey = "HistoryWindowFrame"

    convenience init(syncData: SyncData, dataFileURL: URL?) {
        let hostingController = NSHostingController(rootView: HistoryView(syncData: syncData, dataFileURL: dataFileURL))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Typing Stats History"
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 300, height: 400)

        if let frameString = UserDefaults.standard.string(forKey: HistoryWindowController.frameKey) {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.setContentSize(NSSize(width: 400, height: 500))
            window.center()
        }

        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: HistoryWindowController.frameKey)
        }
    }
}
