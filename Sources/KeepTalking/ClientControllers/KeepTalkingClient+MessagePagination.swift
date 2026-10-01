//
//  KeepTalkingClient+MessagePagination.swift
//  KeepTalkingSDK
//
//  The direction a page walks. Paging itself is keyed and exact — see
//  `KeepTalkingClient+MessageRanges`: the chat list (docking = bottom)
//  starts from the tail and walks backward; the threads view (docking = top)
//  starts from the head and walks forward.
//

import FluentKit
import Foundation

/// Direction the page extends from the cursor. The ordering of the
/// returned messages is in this same direction — the caller is responsible
/// for re-sorting to display order if needed.
public enum KeepTalkingMessagePageDirection: Sendable {
    /// Walk backward in time from the cursor. Returns messages with
    /// `timestamp < cursor` (or the most recent N when `cursor == nil`),
    /// sorted descending so the first element is the message just before
    /// the cursor.
    case backward
    /// Walk forward in time from the cursor. Returns messages with
    /// `timestamp > cursor` (or the oldest N when `cursor == nil`), sorted
    /// ascending so the first element is the message just after the cursor.
    case forward
}
