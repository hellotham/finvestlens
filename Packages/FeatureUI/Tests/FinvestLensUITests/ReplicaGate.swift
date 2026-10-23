//
//  ReplicaGate.swift
//  FinvestLens — FeatureUI
//
//  Holds work on a replica at its start (`AppModel.replicaWorkWillStart`)
//  until a test lets it go, so a close or an edit "while it runs" lands
//  while it runs every time — not when the scheduler happens to allow. One
//  `Task.yield()` was the old way, and on CI, with tests running in
//  parallel on the one main actor, the work finished first (19 Oct 2026).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Holds each piece of replica work at its start until ``open()``; after
/// that, work passes straight through.
actor ReplicaGate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The hook: counts the arrival, then waits for the gate to open.
    func arrive() async {
        arrived += 1
        let reached = arrived
        let ready = watchers.filter { $0.count <= reached }
        watchers.removeAll { $0.count <= reached }
        for watcher in ready { watcher.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once `count` pieces of work have reached the gate — each with
    /// its replica taken, none of them started.
    func waitForArrivals(_ count: Int) async {
        guard arrived < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    /// Lets everything held go on, and everything after it pass.
    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held.removeAll()
    }
}
