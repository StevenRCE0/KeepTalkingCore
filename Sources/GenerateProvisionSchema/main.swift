import Foundation
import KeepTalkingSDK

// Produces a JSON Schema for `.ktprovision` files directly from
// `KeepTalkingProvisionBundle` — nothing about the schema is hand-maintained,
// and no copy of it is checked into this repo. The docs-deploy workflow runs
// this fresh on every deploy and writes the result straight into the site
// being published, so what's hosted can never drift from the bundle: there is
// no separate "generate, then remember to commit" step to skip.
//
// The approach: build one sample bundle with every field populated, then walk
// it with `Mirror`. A struct's stored properties come straight from its
// children; a property's Swift-side optionality is recoverable at runtime
// because boxing a value into `Any` preserves whether its static type was
// `Optional<T>` (`Mirror(reflecting:).displayStyle == .optional` is true for
// an Optional-typed value whether or not it happens to be nil) — which is
// exactly the distinction that decides "required" here: Swift's synthesized
// `Decodable` requires a key to be present unless the property's type is
// Optional, regardless of any Swift-side initializer default.
//
// What a single sample instance *can't* recover: the full case list of an
// enum (a value only tells you which one case it is), so the three
// provisioning enums are special-cased by concrete type via `CaseIterable`.
// Extend the list in `enumCases(for:)` if a fourth one is added.
//
// Usage: `swift run GenerateProvisionSchema <output-path>` from the package
// root. Omitting the path writes to /tmp for a quick local look — that
// default is not meant to be committed anywhere.

func sampleBundle() -> KeepTalkingProvisionBundle {
    KeepTalkingProvisionBundle(
        version: 1,
        security: .none,
        passKVServerURL: ProvisionedValue("https://passkv.example.com", policies: [.userConfigurable]),
        sfuHost: ProvisionedValue("sfu.example.com", policies: [.userConfigurable]),
        sfuPort: ProvisionedValue(9701, policies: [.userConfigurable]),
        providers: ProvisionedValue(
            [
                ProvisionedProvider(
                    kind: "openRouter", displayName: "Work", apiKey: "sk-x", baseURL: "https://openrouter.ai/api/v1",
                    webSearchEnabled: true, policies: [.userConfigurable])
            ],
            policies: [.userConfigurable, .availableInOtherProfiles]
        ),
        roleAssignments: ProvisionedValue(
            ProvisionedRoleAssignments(
                main: ProvisionedRoleTarget(provider: "Work", model: "openai/gpt-5"),
                act: ProvisionedRoleTarget(provider: "Work", model: "openai/gpt-5-mini"),
                audioInteraction: ProvisionedRoleTarget(provider: "Work", model: "openai/gpt-5-realtime")
            ),
            policies: [.userConfigurable]
        ),
        webSearch: ProvisionedValue(
            ProvisionedWebSearch(kind: "exa", apiKey: "x", isEnabled: true), policies: [.userConfigurable]),
        voiceWakeKeyword: ProvisionedValue("hey talking", policies: [.userConfigurable]),
        responseLanguages: ProvisionedValue(["en", "fr"], policies: [.userConfigurable]),
        // Every `policies` array below must stay non-empty, regardless of what a
        // realistic profile would set — the generator needs at least one element
        // to introspect the array's item type (ProvisionPolicy).
        maxConnectedContexts: ProvisionedValue(4, policies: [.userConfigurable]),
        attachmentSyncLookbackDays: ProvisionedValue(14, policies: [.userConfigurable]),
        analyticsEnabled: ProvisionedValue(true, policies: [.userConfigurable])
    )
}

/// Concrete types this schema cares about that can't enumerate their own
/// cases from a single value. Returns `nil` for anything else, including
/// enums with associated values (none exist in this bundle today).
func enumCases(for value: Any) -> [String]? {
    switch value {
        case is ProvisionSecurity: return ProvisionSecurity.allCases.map(\.rawValue)
        case is ProvisionPolicy: return ProvisionPolicy.allCases.map(\.rawValue)
        case is ProvisionAgentRole: return ProvisionAgentRole.allCases.map(\.rawValue)
        default: return nil
    }
}

func schemaNode(for value: Any, path: String) -> [String: Any] {
    if let cases = enumCases(for: value) {
        return ["type": "string", "enum": cases]
    }

    let mirror = Mirror(reflecting: value)

    switch mirror.displayStyle {
        case .struct, .class:
            var properties: [String: Any] = [:]
            var required: [String] = []
            for child in mirror.children {
                guard let label = child.label else { continue }
                let childPath = "\(path).\(label)"
                let childMirror = Mirror(reflecting: child.value)
                if childMirror.displayStyle == .optional {
                    guard let unwrapped = childMirror.children.first?.value else {
                        fatalError(
                            "\(childPath) is nil in the sample bundle — populate every optional field in "
                                + "sampleBundle() so the generator can introspect the wrapped type.")
                    }
                    properties[label] = schemaNode(for: unwrapped, path: childPath)
                } else {
                    properties[label] = schemaNode(for: child.value, path: childPath)
                    required.append(label)
                }
            }
            return ["type": "object", "required": required.sorted(), "properties": properties]

        case .collection:
            guard let first = mirror.children.first?.value else {
                fatalError("\(path) is empty in the sample bundle — give it at least one element.")
            }
            return ["type": "array", "items": schemaNode(for: first, path: "\(path)[]")]

        case .enum:
            fatalError(
                "\(path) is \(type(of: value)), an enum with no CaseIterable special-case above — "
                    + "add one to enumCases(for:).")

        default:
            switch value {
                case is String: return ["type": "string"]
                case is Int: return ["type": "integer"]
                case is Bool: return ["type": "boolean"]
                default:
                    fatalError("\(path) is an unhandled leaf type: \(type(of: value)).")
            }
    }
}

let bundleSchema = schemaNode(for: sampleBundle(), path: "KeepTalkingProvisionBundle")

var document: [String: Any] = [
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://docs.keeptalking.dev/schema/keeptalking-provision.schema.json",
    "title": "KeepTalkingProvisionBundle",
    "description":
        "A KeepTalking provisioning profile (.ktprovision). Generated from "
        + "Sources/KeepTalking/Models/ProvisionBundle.swift by GenerateProvisionSchema — do not hand-edit; "
        + "run `swift run GenerateProvisionSchema` after changing the bundle and commit the diff. "
        + "See <doc:Provisioning> for the guide. Decoding is via Swift's synthesized Codable, which ignores "
        + "unknown keys at any level (so an instance document may carry \"$schema\" harmlessly) but requires "
        + "every key this schema marks \"required\".",
]
for (key, value) in bundleSchema { document[key] = value }

let data = try JSONSerialization.data(
    withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

// Not a checked-in file: the docs-deploy workflow passes the deploy
// directory directly (`swift run GenerateProvisionSchema <path>`), so the
// schema is produced fresh on every run and never goes stale relative to
// what's actually hosted. Defaulted for ad hoc local inspection only.
let outputPath =
    CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/keeptalking-provision.schema.json"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: outputURL)
FileHandle.standardError.write("Wrote \(outputURL.path) (\(data.count) bytes)\n".data(using: .utf8)!)
