//
//  OpenAITyping.swift
//  KeepTalking
//
//  Migration shim — see MIGRATION_AIPROXY.md.
//  These typealiases let callers keep their current names while we rewrite
//  the rest of the SDK to use AIProxy types directly. Once the migration
//  finishes, this whole file should be deleted and callers should reference
//  AIProxy types directly.
//

import AIProxy

/// Use `String` for model identifiers in new code. AIProxy passes models as plain
/// strings (provider-prefixed when going through OpenRouter, e.g. "openai/gpt-4o-mini").
@available(*, deprecated, message: "Use String directly. AIProxy uses string model IDs.")
public typealias OpenAIModel = String

/// Migration alias for the old MacPaw `Tool` type. New code should use
/// `OpenAIChatCompletionRequestBody.Tool` directly.
@available(*, deprecated, message: "Use OpenAIChatCompletionRequestBody.Tool directly.")
public typealias OpenAITool = OpenAIChatCompletionRequestBody.Tool
