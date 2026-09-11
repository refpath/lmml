# Security considerations for hosts

`lmml` narratives and `.lmmlz` archives are **untrusted input**. They are
produced by people, by tools and by models, and they are routinely handed
from one system to another. This document lists what the library defends
against on its own, and what a host that opens, renders or acts on a
bundle must still do itself.

## What the library enforces

| Threat | Where it is stopped | Behaviour |
|---|---|---|
| Zip bomb (small archive inflating to gigabytes) | central directory, before inflation | `Lmml.Archive.Policy` bounds entry count, per-entry and total declared size and compression ratio; a violation is `{:error, {:compression_ratio_exceeded, name}}` and friends |
| Forged size header | immediately after inflation | an entry whose actual size differs from its declared size is `{:error, {:size_mismatch, name}}` |
| Path traversal, absolute paths, backslashes, dot or empty segments | central directory | `{:error, {:unsafe_entry, name}}` |
| Ambiguous names (invalid UTF-8, control characters, non-NFC) | central directory | `{:error, {:ambiguous_entry_name, name}}` |
| Duplicate names, including names equal after case folding | central directory | `{:error, {:duplicate_entry, name}}`; the previous behaviour let the last entry win silently |
| Directory, symlink or device entries | central directory | `{:error, {:non_regular_entry, name}}` |
| Tampered content | `Lmml.Manifest.verify/1` | every embed's bytes are checked against the SHA-256 the manifest declares; a mismatch names the entry |
| Misread newer documents | `Lmml.Manifest.load/1` | a manifest declaring a major version this library does not know is refused, never partially interpreted |
| Remote dereferencing | by construction | an `@name` reference resolves against the archive's own entries or fails; nothing in the library opens a URI or a second file |

None of these checks require network access. `mix lmml.verify` runs all
of them from the command line and exits non-zero on any issue.

## What a host must still do

**Treat every bundle as data, not instructions.** Parsing a narrative,
verifying its digests or even validating a signature over its manifest
says who produced the bytes and that they are intact. It says nothing
about whether the *content* should be followed. A `:system` turn in an
archive you received is a string someone wrote, not your system prompt.

**Preserve the trust boundary when rendering.** Use `trust=untrusted` on
turns that carry tool output, retrieved documents or any text the author
did not write, and read `Lmml.Narrative.Segment.trust/1` before deciding
what a model may act on. Absence of the attribute is `:unspecified`, not
trust. A renderer that flattens turns into one prompt destroys this
boundary; prefer `render_turns/2` and keep roles distinct.

**Keep tool results as observations.** Record tool calls and results in
the manifest's `tool_events` (see `Lmml.Manifest.ToolEvent`) so their
bytes are digest-bound and their status is explicit. A tool result is
something a tool observed; it grants no authority and must never be
promoted to an instruction because it appears in the narrative.

**Size the archive policy for your own memory budget.** The defaults
(1024 entries, 16 MiB per entry, 64 MiB total, 100:1 ratio, 2048-byte
names) are conservative for a workstation, not a guarantee for a service.
Pass a tighter `Lmml.Archive.Policy` to `Lmml.Bundle.load/3` or
`open/2` when accepting archives from the public.

**Do not confuse identities.** The digest of an archive's bytes, the
digest of its canonical manifest, and the digest of an individual entry
are three different facts. A signature over one does not cover the
others. Bind the one you mean.

**Authorize before packing, not after.** The library will happily pack
whatever bytes you give it. Deciding which sources may enter a bundle,
which readers may open it and how long it may be retained is the host's
policy, made before `Lmml.Pack.pack/2` or `Lmml.Manifest.attach/2` is
called.

**Decompress only what you verified.** `Lmml.Bundle.load/3` keeps every
entry in memory; it does not write files. If your host extracts entries
to disk, apply the same name rules the library applies and never trust a
name to be a safe path on its own.

## Reporting

Report suspected vulnerabilities in the library privately to the
maintainers listed in `mix.exs` before opening a public issue.
