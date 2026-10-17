import PulseCore
import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.network
        let d = model.disk
        VStack(spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Tile(label: "↓ Received", value: Fmt.rate(n.inRate), color: Palette.download)
                        Tile(label: "↑ Sent", value: Fmt.rate(n.outRate), color: Palette.upload)
                    }
                    HStack {
                        CardTitle("Network · last 10 min")
                    }
                    LineChart(series: [
                        ChartSeries(name: "Received", color: Palette.download, points: model.points(.netIn, range: .live)),
                        ChartSeries(name: "Sent", color: Palette.upload, points: model.points(.netOut, range: .live)),
                    ], height: 90, format: ChartFormat.rate)
                    StatRow(label: "Interface", value: n.localIP ?? "not connected", systemImage: "wifi", detail: n.interfaceName)
                    StatRow(label: "Since Pulse started", value: "↓ \(Fmt.bytes(n.totalIn))  ↑ \(Fmt.bytes(n.totalOut))",
                            systemImage: "sum")
                    if n.unavailable {
                        Text("nettop returned no data, so network rates are unavailable.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Who's using the network?", trailing: "↓ + ↑")
                    AppList(apps: Array(n.apps.prefix(6)).map {
                        AppUsage(id: $0.id, name: $0.name, icon: $0.icon, cpu: 0, memory: 0, power: $0.total)
                    }, value: \.power, format: Fmt.rate, color: Palette.download, minimum: 1000)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Disk", trailing: "\(Fmt.bytes(d.available)) free")
                    Meter(fraction: d.usedFraction, color: d.usedFraction > 0.9 ? .red : Palette.network[1], height: 8)
                    Text("\(Fmt.bytes(d.used)) of \(Fmt.bytes(d.total)) used")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Tile(label: "Read", value: Fmt.rate(d.readRate), color: .teal)
                        Tile(label: "Write", value: Fmt.rate(d.writeRate), color: .pink)
                    }
                    LineChart(series: [
                        ChartSeries(name: "Read", color: .teal, points: model.points(.diskRead, range: .live)),
                        ChartSeries(name: "Write", color: .pink, points: model.points(.diskWrite, range: .live)),
                    ], height: 70, format: ChartFormat.rate)
                }
            }
        }
    }
}
