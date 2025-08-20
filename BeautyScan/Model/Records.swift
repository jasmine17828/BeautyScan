import Foundation
import CoreGraphics
import Observation

// MARK: - MetricKind (which metric to show / plot)
enum MetricKind: String, CaseIterable, Identifiable {
    case ipdPx = "瞳距 IPD"
    case noseWidthPx = "鼻寬"
    case noseHeightPx = "鼻長"
    case mouthWidthPx = "嘴寬"
    case jawLengthPx = "下顎長"
    case foreheadWidthPx = "額頭寬"
    case foreheadHeightPx = "額頭高"
    case eyeLeftWidthPx = "左眼寬"
    case eyeLeftHeightPx = "左眼高"
    case eyeRightWidthPx = "右眼寬"
    case eyeRightHeightPx = "右眼高"

    var id: String { rawValue }
    var unit: String { "px" }

    /// Pull the value for this metric from a snapshot
    func value(from m: MetricSnapshot) -> Double? {
        switch self {
        case .ipdPx:                return m.ipdPx
        case .noseWidthPx:          return m.noseWidthPx
        case .noseHeightPx:         return m.noseHeightPx
        case .mouthWidthPx:         return m.mouthWidthPx
        case .jawLengthPx:          return m.jawLengthPx
        case .foreheadWidthPx:      return m.foreheadWidthPx
        case .foreheadHeightPx:     return m.foreheadHeightPx
        case .eyeLeftWidthPx:       return m.eyeLeftWidthPx
        case .eyeLeftHeightPx:      return m.eyeLeftHeightPx
        case .eyeRightWidthPx:      return m.eyeRightWidthPx
        case .eyeRightHeightPx:     return m.eyeRightHeightPx
        }
    }
}

// MARK: - MetricSnapshot (one measurement)
struct MetricSnapshot: Codable, Identifiable {
    var id = UUID()
    var ipdPx: Double?
    var noseWidthPx: Double?
    var noseHeightPx: Double?
    var mouthWidthPx: Double?
    var jawLengthPx: Double?
    var foreheadWidthPx: Double?
    var foreheadHeightPx: Double?
    var eyeLeftWidthPx: Double?
    var eyeLeftHeightPx: Double?
    var eyeRightWidthPx: Double?
    var eyeRightHeightPx: Double?
}

// MARK: - FaceRecord (a saved record)
struct FaceRecord: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var subject: String
    var procedure: String
    var metrics: MetricSnapshot
}

// MARK: - RecordStore (Observation-based)
@Observable
final class RecordStore {
    /// All saved records (newest first)
    var records: [FaceRecord] = []

    // Derived lists for pickers
    var subjects: [String] {
        Array(Set(records.map(\.subject))).sorted()
    }

    var procedures: [String] {
        Array(Set(records.map(\.procedure))).sorted()
    }

    /// Last used subject (for defaulting pickers)
    var lastSubject: String {
        records.first?.subject ?? ""
    }

    // Add from a Vision measure
    func addFromMeasure(_ m: FaceMeasureEngine.Measure,
                        subject: String,
                        procedure: String,
                        date: Date = .now) {
        let snap = MetricSnapshot(
            ipdPx: m.ipdPx.map(Double.init),
            noseWidthPx: m.noseWidthPx.map(Double.init),
            noseHeightPx: nil,
            mouthWidthPx: m.mouthWidthPx.map(Double.init),
            jawLengthPx: m.jawLengthPx.map(Double.init),
            foreheadWidthPx: nil,
            foreheadHeightPx: nil,
            eyeLeftWidthPx: nil,
            eyeLeftHeightPx: nil,
            eyeRightWidthPx: nil,
            eyeRightHeightPx: nil
        )
        let rec = FaceRecord(date: date, subject: subject, procedure: procedure, metrics: snap)
        records.insert(rec, at: 0)
    }

    // Manual add (for testing)
    func addManual(date: Date,
                   subject: String,
                   procedure: String,
                   metrics: MetricSnapshot = .init()) {
        records.insert(.init(date: date, subject: subject, procedure: procedure, metrics: metrics), at: 0)
    }

    // Chart series builder
    /// Build (Date, Double) points filtered by subject/procedure; nil means 'all'
    func chartSeries(subject: String?, procedure: String?, metric: MetricKind) -> [(Date, Double)] {
        records
            .filter { rec in
                let subjectOK = (subject?.isEmpty == false) ? (rec.subject == subject!) : true
                let procOK    = (procedure?.isEmpty == false) ? (rec.procedure == procedure!) : true
                return subjectOK && procOK
            }
            .compactMap { rec in
                guard let v = metric.value(from: rec.metrics) else { return nil }
                return (rec.date, v)
            }
            .sorted { $0.0 < $1.0 }
    }
}
