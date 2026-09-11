# RFC 0000: Language Model Markup Language (LMML) and Archive Bundle Specification (LMMLZ)

- **Document Version**: 1.1.0
- **Status**: Informational / Specification
- **Authors**: Oeditus Team
- **Date**: September 2026

---

## 1. Abstract

This specification defines **Language Model Markup Language (LMML)**, a Markdown-superset markup format for representing structured, multi-turn artificial intelligence (AI) and Large Language Model (LLM) interaction sessions. It also specifies **LMMLZ**, a portable, single-file zip archive format for packaging an LMML narrative alongside external binary and textual assets.

---

## 2. Terminology and Conformance

The key words "**MUST**", "**MUST NOT**", "**REQUIRED**", "**SHALL**", "**SHALL NOT**", "**SHOULD**", "**SHOULD NOT**", "**RECOMMENDED**", "**MAY**", and "**OPTIONAL**" in this document are to be interpreted as described in [RFC 2119](https://datatracker.ietf.org/doc/html/rfc2119) and [RFC 8174](https://datatracker.ietf.org/doc/html/rfc8174).

- **Narrative**: The underlying UTF-8 text containing human prose, Markdown formatting, and embedded asset references.
- **Embed**: A named entity (inline or external) contained or referenced within a narrative.
- **Bundle**: A container abstraction representing an LMML entity, regardless of whether it is stored as a bare text file (`.lmml`) or an archive bundle (`.lmmlz`).

---

## 3. On-Disk Formats

An LMML document **MUST** be stored in one of two canonical forms:

### 3.1 Plain Text Form (`.lmml`)
A single UTF-8 encoded text file bearing the `.lmml` extension.
- **Constraint**: Because a bare text file carries no secondary file payload streams, every embed referenced within a `.lmml` narrative **MUST** either be inline (`@@@name.ext ... @@@`) or be resolved against an external environment. Unresolved external references (`@name.ext`) in a bare `.lmml` document **MUST** evaluate to an unresolvable reference error upon asset resolution.

### 3.2 Zip Archive Form (`.lmmlz`)
A standard PKZIP archive (magic bytes `0x50 0x4B 0x03 0x04`) bearing the `.lmmlz` extension.
- **Canonical Entry Naming**: An `.lmmlz` archive **MUST** contain exactly one primary narrative entry whose filename is derived by stripping the trailing `z` from the archive file's basename (e.g. archive `session.lmmlz` **MUST** contain primary narrative entry `session.lmml`).
- **Asset Entries**: Any additional file stored within the archive represents a named external asset accessible to `@name.ext` references. An entry named `manifest.json` is the bundle's manifest (§5.1) whether or not the narrative references it.

### 3.3 Entry Names
Every entry name, and every embed name that may become one, **MUST** satisfy all of the following; a reader **MUST** reject the archive otherwise:
- it is non-empty, does not start with `/`, contains no backslash, and has no `..`, `.` or empty path segment (so `a//b` and a trailing `/` are rejected);
- it is valid UTF-8, contains no control character (U+0000–U+001F, U+007F), and is in Unicode Normalization Form C, so a name has exactly one byte representation;
- it is unique within the archive after case folding, so two entries cannot collide on a case-insensitive filesystem or be confused by a reviewer;
- it denotes a regular file. Directory, symbolic link and device entries **MUST** be rejected.

### 3.4 Archive Resource Limits
An archive's central directory declares each entry's compressed and uncompressed size. A reader **MUST** check the directory against its resource policy *before* inflating any entry, and **MUST** reject the archive when the entry count, any entry's declared uncompressed size, the sum of declared uncompressed sizes, any entry's compression ratio (uncompressed ÷ compressed; a non-empty entry declaring zero compressed bytes has an infinite ratio) or any entry name's byte length exceeds the policy. After inflation, an entry whose actual size differs from its declared size **MUST** be rejected. The reference implementation's defaults are 1024 entries, 16 MiB per entry, 64 MiB in total, a 100:1 ratio and 2048-byte names; they are defaults for a workstation, not guarantees, and a host accepting archives from untrusted parties **SHOULD** tighten them.

### 3.5 Deterministic Serialization
A writer **SHOULD** produce identical bytes for identical logical content: entries ordered by the byte order of their names and every entry stamped with the zip epoch (1980-01-01T00:00:00) rather than the wall clock. Modification times belong in a manifest, where a reader can verify them, not in container metadata it cannot.

---

## 4. Narrative Syntax Specification

LMML is designed as a strict superset of standard Markdown (CommonMark/GFM). Any valid Markdown document **MUST** parse as a valid LMML narrative with zero embeds.

### 4.1 External Embed References (`@name.ext`)
- **Syntax**: An `@` symbol followed immediately by an asset identifier matching `[a-zA-Z0-9_.-]+`.
- **Parsing Rules**:
  - The identifier **MUST** begin with an alphanumeric character.
  - Punctuation immediately trailing the identifier (such as periods `.`, commas `,`, or closing parentheses `)`) **MUST NOT** be captured as part of the asset name if it constitutes standard sentence punctuation.
  - References nested inside inline spans (code spans `` `...` ``) or block constructs (fenced code blocks ```` ```...``` ````) **MUST NOT** be interpreted as LMML references.

### 4.2 Inline Embed Blocks (`@@@name.ext ... @@@`)
- **Syntax**:
  ```markdown
  @@@name.ext
  <content>
  @@@
  ```
- **Parsing Rules**:
  - The opening fence line **MUST** start with three `@` symbols (`@@@`), followed immediately by the embed name.
  - The content between the opening and closing `@@@` lines **MUST** be captured verbatim (byte-for-byte), without HTML entity escaping or Markdown modification.
  - The closing fence **MUST** be `@@@` on a line by itself.

---

## 5. Reserved Embeds and Metadata Conventions

LMML defines standard conventions for structural metadata embeds. Implementations **MUST** recognize these reserved names when requested by callers:

### 5.1 `manifest.json`
An embed named `manifest.json` (inline or external), or an archive entry of that name, carries the bundle's manifest.
- **Format**: JSON Object (`{ ... }`).
- **Schema version**: the member `lmml_version` **MUST** be the string `"1"` for documents conforming to this revision. A reader encountering a major version it does not implement **MUST** refuse the manifest rather than interpret it partially. A manifest without `lmml_version` is *legacy metadata*: a reader **MAY** expose it but **MUST NOT** report it as verified.
- **Entries**: the member `entries` **MUST** be an object keyed by embed name. Each value **MUST** carry `sha256` (the SHA-256 of the embed's exact bytes as 64 lowercase hexadecimal characters) and `size` (the byte length), and **MAY** carry `media_type` and `trust` (`"trusted"` or `"untrusted"`). `entries` **MUST NOT** list `manifest.json` itself. A digest names bytes: the same content inline and as an archive entry has the same digest, and renaming an entry does not change it.
- **Tool events**: the optional member `tool_events` is a list of objects each carrying `call_id` (unique within the manifest), `tool` and `status` (`"ok"` or `"error"`), and optionally `arguments` and `result` (embed names bound by `entries`), `error_class` and an opaque `provenance` object. A tool result is an observation; the format assigns it no authority.
- **Extensions**: the optional member `extensions` is an object keyed by reverse-DNS namespace whose values are opaque objects. A reader **MUST** preserve extensions it does not understand.
- **Other members**: any other top-level member is application metadata (model identifiers, session identifiers). A reader **MUST** preserve members it does not understand and **MUST NOT** treat an unknown member as an error.
- **Verification**: a verifier **MUST** report every embed the narrative mentions that has no entry, every entry that names nothing in the bundle, every digest or size mismatch, and every malformed `trust`, `extensions` or `tool_events` member. Verification **MUST NOT** dereference any URI or read any file other than the bundle.

### 5.1.1 Canonical Serialization and Digests
The digest of a manifest is the SHA-256 of its *canonical encoding*: JSON with object members sorted by the UTF-8 bytes of their keys, no insignificant whitespace, strings escaped minimally and numbers in their shortest round-trip form. Two manifests with the same members therefore have the same digest regardless of how their bytes were formatted. A signature over a manifest **SHOULD** be computed over this canonical encoding. The digest of the manifest, the digest of an archive's bytes and the digest of an individual entry are three distinct identities; a signature over one does not cover the others.

### 5.2 `settings.yaml` / `settings.json`
An embed named `settings.yaml` or `settings.json` carries execution configurations (such as model sampling parameters like `temperature`, `top_p`, or custom agent instructions).

---

## 6. Multi-Turn Segmentation Protocol

An LMML narrative **MAY** represent a multi-turn conversation comprising multiple message roles.

### 6.1 Role Delimiters
Implementations **MUST** recognize two delimiter syntaxes for demarcating turn boundaries (case-insensitive):

1. **Markdown Headings**:
   - `## Turn N -- <role>`
   - `# <role>`
   - `### <role>`
   Where `<role>` is one of `:user`, `:assistant`, `:system`, or `:tool`.

2. **HTML Comments**:
   - `<!-- <role> -->`

### 6.2 Turn Structure and Preamble
- Text preceding the first role delimiter **MUST** be assigned to a synthetic `:context` preamble turn.
- Text following a delimiter belongs to that turn until the next delimiter or end-of-file.
- Embeds occurring within a turn's character offset span **MUST** be bound exclusively to that turn.

### 6.3 Turn Attributes and Trust
A comment delimiter **MAY** carry attributes after the role: `<!-- tool trust=untrusted id=call-1 -->`. An attribute is `key=value` where the key matches `[A-Za-z_][A-Za-z0-9_.-]*` and the value is a bare token without whitespace or a double-quoted string. An implementation **MUST** strip attributes before identifying the role token, so a value can never be read as the role, and **MUST** preserve attributes it does not define. Heading delimiters carry no attributes.

Two attribute names are reserved:
- `trust`: `trusted` or `untrusted`. Content the author did not write — a tool result, a retrieved document, another party's message — **SHOULD** be marked `untrusted`. A turn without the attribute has *unspecified* trust, which is not trust; an implementation **MUST NOT** default an unmarked turn to trusted.
- `id`: a stable identifier for the turn, typically the `call_id` of the `tool_events` entry a `tool` turn corresponds to.

A renderer that produces role-labelled messages **MUST** keep the `tool` role distinct from `system` and `user`; flattening turns into one prompt discards the trust boundary the attributes describe.

---

## 7. Extension-Based Asset Handlers and Semantic Resolution

LMML separates asset containment from asset consumption:

1. **Resolution Phase**: An implementation **MUST** resolve every embed name to its underlying raw bytes (`{:inline, binary}` or `{:external, filename}`).
2. **Rendering / Handler Phase**: Resolved assets **MUST** be mapped to typed application structures based on file extension (or manifest metadata):
   - Image extensions (`.png`, `.jpg`, `.jpeg`, `.webp`, `.svg`, `.gif`) **SHOULD** map to `image_url` data URIs.
   - Text and document extensions (`.json`, `.yaml`, `.pdf`, `.csv`, `.log`, `.diff`) **SHOULD** map to structured attachment parts.
   - Implementations **MAY** register custom handlers per extension (e.g. invoking an audio transcriber for `.mp3` or code interpreter for `.py`).

---

## 8. Conformance & Cross-Validation Requirements

An implementation's validator **MUST** report all of the following authoring defects when cross-checking a bundle (`Bundle.validate/1`):

1. `missing_reference`: An external reference `@name` with no corresponding archive entry.
2. `orphaned_entry`: An archive entry not referenced anywhere in the narrative.
3. `malformed_embed_name`: An embed name violating safe filename path boundaries.
4. `conflicting_embed`: Embeds sharing the same name but carrying conflicting content.

---

## 9. Security Considerations

A narrative or archive is untrusted input. Implementations **MUST** enforce the following:
- **Entry name rules and resource limits** (§3.3, §3.4): every check that can be made against the central directory **MUST** be made before any entry is inflated, and declared sizes **MUST** be verified after inflation.
- **No remote dereferencing**: an `@name` reference resolves against the archive's own entries or fails. An implementation **MUST NOT** fetch a URI, open a second file or consult the network while parsing, resolving, rendering or verifying a bundle. A URI appearing in prose or metadata is text.
- **Integrity before use**: a host that relies on a bundle's content **SHOULD** verify it against its manifest (§5.1) before rendering it to a model, and **MUST NOT** treat a manifest-less or unversioned bundle as verified.
- **Trust is not transitive**: parsing, digest verification and signature verification establish origin and integrity, never instruction authority. A `system` turn in a received archive is a string someone wrote. Renderers **MUST** preserve the role and `trust` boundaries of §6.3, and tool results recorded in `tool_events` **MUST** be treated as observations.
- **Distinct identities**: an archive-byte digest, a canonical-manifest digest and an entry digest are different facts (§5.1.1); a consumer **MUST** bind the one it means.
- **Policy before packing**: which sources may enter a bundle, who may open it and how long it is retained are the packing host's decisions, made before packing; the format carries no authorization semantics.

See `docs/SECURITY.md` for the reference implementation's threat model and the obligations that remain with a host.

## 10. Versioning and Compatibility

- The manifest's `lmml_version` is a major version. Within a major version, new optional members and new attribute names **MAY** be added; readers **MUST** ignore and preserve what they do not understand and **MUST NOT** fail on an unknown member.
- A change that alters the meaning of an existing member, the digest recipe or the canonical encoding **MUST** increment the major version. Readers **MUST** refuse a major version they do not implement.
- A manifest without `lmml_version` predates this revision; it loads as legacy metadata and cannot be verified.
- The narrative syntax of §4 and the archive form of §3 are unversioned: a conforming document under this revision is a conforming document under §3–§4 of revision 1.0.0, and the additional rules of §3.3–§3.5 only reject archives that were never safe to open.
