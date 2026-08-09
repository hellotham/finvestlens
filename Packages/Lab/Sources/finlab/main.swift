//
//  main.swift
//  finlab — FinvestLens Lab
//
//  A thin shell around ``Lab``: everything testable lives in the library
//  target, exactly as `finlens` does it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensLabCore

// Top-level code in `main.swift` is main-actor isolated, which is what the
// commands need: they drive `AppModel`, and it is `@MainActor`.
//
// Each line is written and flushed as it arrives rather than buffered into a
// final block — these runs take minutes, and progress that shows up after the
// run has finished is not progress.
let status = await Lab.run(arguments: Array(CommandLine.arguments.dropFirst())) { line in
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

exit(status)
