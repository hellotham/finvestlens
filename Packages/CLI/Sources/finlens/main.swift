//
//  main.swift
//  finlens — FinvestLens CLI
//
//  A thin shell around ``CLIDriver``: everything testable lives in the
//  library target.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensCLICore

let driver = CLIDriver()
let result = driver.run(arguments: Array(CommandLine.arguments.dropFirst()))

if !result.text.isEmpty {
    FileHandle.standardOutput.write(Data(result.text.utf8))
}
if !result.errorText.isEmpty {
    FileHandle.standardError.write(Data(result.errorText.utf8))
}
exit(result.status)
