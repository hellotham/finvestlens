//
//  RBAStatistics.swift
//  FinvestLens — Quotes
//
//  The Reserve Bank's statistical tables, as plain CSV with no key: table G1,
//  "Consumer Price Inflation", carries the ABS consumer price index (all
//  groups, Australia) by quarter — the series the capital-gains indexation
//  reads. Opened on 25 October 2026: a title line, then rows headed Title,
//  Description, Frequency, Type, Units ("Index, September 2025 month = 100"
//  — the reference base is immaterial, a factor is a ratio of two readings),
//  Source, Publication date and Series ID, then one row per quarter end,
//  `dd/mm/yyyy,value,…`, from 30/06/1922 on. The CPI column is the series
//  `GCPIAG`.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum RBAStatisticsError: Error, Equatable, Sendable {
    /// The table had no `Series ID` row, or the row named no such series.
    case seriesNotFound(String)
    /// The body was not text.
    case notText
}

/// Reads the RBA's CSV tables.
public enum RBAStatistics {

    /// Table G1 — Consumer Price Inflation.
    public static let cpiTableURL = URL(string: "https://www.rba.gov.au/statistics/tables/csv/g1-data.csv")!

    /// The all-groups CPI by quarter, keyed `"YYYY-Qn"` by the calendar
    /// quarter the row's date falls in (a row dated 30/09/2025 is `2025-Q3`).
    public static func fetchCPI(http: HTTPFetching = URLSessionHTTPClient()) async throws -> [String: Double] {
        let data = try await http.get(cpiTableURL, headers: ["User-Agent": HTTPDefaults.userAgent])
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RBAStatisticsError.notText
        }
        return try parseCPI(text)
    }

    /// Parses a table in the G1 layout for one series.
    static func parseCPI(_ text: String, series: String = "GCPIAG") throws -> [String: Double] {
        let lines = text.split(whereSeparator: \.isNewline).map { line -> [String] in
            fields(of: String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")))
        }
        guard let header = lines.first(where: { $0.first?.caseInsensitiveCompare("Series ID") == .orderedSame }),
              let column = header.firstIndex(of: series) else {
            throw RBAStatisticsError.seriesNotFound(series)
        }
        var readings: [String: Double] = [:]
        for row in lines where row.count > column {
            guard let key = quarterKey(row[0]), let value = Double(row[column]) else { continue }
            readings[key] = value
        }
        return readings
    }

    /// `"30/09/2025"` → `"2025-Q3"`; anything else `nil`.
    static func quarterKey(_ date: String) -> String? {
        let parts = date.split(separator: "/")
        guard parts.count == 3, let month = Int(parts[1]), let year = Int(parts[2]),
              (1...12).contains(month), year > 1900 else { return nil }
        return "\(year)-Q\((month - 1) / 3 + 1)"
    }

    /// One CSV line's fields, honouring double quotes (the Title row's
    /// descriptions carry commas).
    static func fields(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                result.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
