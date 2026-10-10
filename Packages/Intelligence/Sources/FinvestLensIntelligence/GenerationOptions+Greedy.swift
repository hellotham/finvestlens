//
//  GenerationOptions+Greedy.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

extension GenerationOptions {
    /// Greedy decoding — every extractor and classifier here wants the model's
    /// single most likely answer, not a creative one. One definition for the
    /// seven call sites; `samplingMode:` is the 27 SDK's spelling of what the
    /// 26 SDK called `sampling:`.
    static var greedy: GenerationOptions { GenerationOptions(samplingMode: .greedy) }
}
#endif
