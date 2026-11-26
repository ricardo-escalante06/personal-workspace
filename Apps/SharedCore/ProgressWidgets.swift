import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// How today is going: the small Today widget's ring.
struct TodayProgress {
    var done: Int
    var total: Int

    var left: Int { total - done }
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    init(_ data: DashboardData) {
        self.init(done: data.today.filter(\.isChecked).count, total: data.today.count)
    }

    static let sample = TodayProgress(done: 2, total: 5)
}

/// Small Today widget: one ring, what's left in the middle. Nothing else.
struct TodayRingView: View {
    let progress: TodayProgress

    private let primary = Color(hex: 0xEDEDED)
    private let faint = Color(hex: 0x9B9B9B)
    private let green = Color(hex: 0x3FB950)

    var body: some View {
        let finished = progress.total > 0 && progress.left == 0
        VStack(alignment: .leading, spacing: 0) {
            Text("Today")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 4)
            HStack {
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 11)
                    Circle().trim(from: 0, to: progress.fraction)
                        .stroke(finished ? green : WSColor.action, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -2) {
                        if finished {
                            Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(green)
                        } else if progress.total == 0 {
                            Text("Free").font(.system(size: 20, weight: .bold, design: .rounded))
                        } else {
                            Text("\(progress.left)")
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            Text("left").font(.system(size: 11, weight: .medium)).foregroundStyle(faint)
                        }
                    }
                }
                .frame(width: 96, height: 96)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(primary)
    }
}
