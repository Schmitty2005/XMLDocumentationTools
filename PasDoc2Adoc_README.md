# PasDoc2Adoc

Extract XML documentation comments from a Free Pascal source file and produce
an [AsciiDoctor](https://asciidoctor.org/) `.adoc` document — no external
dependencies, no XML library, just a single self-contained `.pas` file.

```
fpc PasDoc2Adoc.pas
./PasDoc2Adoc MyUnit.pas MyUnit.adoc
asciidoctor MyUnit.adoc          # → MyUnit.html
asciidoctor-pdf MyUnit.adoc      # → MyUnit.pdf
```

-----

## Contents

- [Building](#building)
- [Usage](#usage)
- [Doc-comment styles](#doc-comment-styles)
- [Supported XML tags](#supported-xml-tags)
- [Recognised Pascal declarations](#recognised-pascal-declarations)
- [Output structure](#output-structure)
- [Tips and patterns](#tips-and-patterns)
- [Known limitations](#known-limitations)

-----

## Building

Requires **Free Pascal 3.2** or later.  No extra units beyond the standard RTL.

```bash
fpc -O2 PasDoc2Adoc.pas
```

The compiler will produce a single binary (`PasDoc2Adoc` on Linux/macOS,
`PasDoc2Adoc.exe` on Windows).

-----

## Usage

```
PasDoc2Adoc <source.pas> [output.adoc]
```

|Argument     |Description                                          |
|-------------|-----------------------------------------------------|
|`source.pas` |The Free Pascal source file to document              |
|`output.adoc`|*(optional)* Output file. Omit to write to **stdout**|

### Examples

```bash
# Write to stdout (pipe-friendly)
./PasDoc2Adoc MyUnit.pas

# Write to a file
./PasDoc2Adoc MyUnit.pas docs/MyUnit.adoc

# Render immediately to HTML
./PasDoc2Adoc MyUnit.pas | asciidoctor -o MyUnit.html -

# Batch-document an entire project
for f in src/*.pas; do
    ./PasDoc2Adoc "$f" "docs/$(basename "${f%.pas}").adoc"
done
```

-----

## Doc-comment styles

### Triple-slash `///`

Consecutive lines starting with `///` are merged into a single doc block.
One optional leading space after `///` is stripped.

```pascal
/// <summary>Add two integers.</summary>
/// <param name="A">Left operand.</param>
/// <param name="B">Right operand.</param>
/// <returns>The sum A + B.</returns>
function Add(A, B: Integer): Integer;
```

### Block-doc `(** ... *)`

Matches the FPC/Delphi `(**` opening.  Leading `*` characters on continuation
lines are stripped automatically.

```pascal
(**
  <summary>Add two integers.</summary>
  <param name="A">Left operand.</param>
  <param name="B">Right operand.</param>
  <returns>The sum A + B.</returns>
*)
function Add(A, B: Integer): Integer;
```

Both styles can be used freely in the same file.

### Placement rules

A doc comment attaches to the **next declaration** that follows it (ignoring
blank lines).  It may appear directly before the declaration or before a
section keyword — both forms are equivalent:

```pascal
// ── Form 1: comment before section keyword ──────────────────
/// <summary>Maximum number of bars per section.</summary>
const
  MAX_BARS = 256;

// ── Form 2: comment inside the section ───────────────────────
const
  /// <summary>Maximum number of bars per section.</summary>
  MAX_BARS = 256;
```

A doc comment before the `unit`, `program`, or `library` keyword — or before
the `interface` / `begin` keyword — becomes the **module-level overview**.

-----

## Supported XML tags

All tag names are matched case-insensitively.

|Tag                   |Purpose                |Notes                                                          |
|----------------------|-----------------------|---------------------------------------------------------------|
|`<summary>`           |One-line description   |Used as the lead paragraph                                     |
|`<remarks>`           |Extended description   |Promoted to summary when `<summary>` is absent                 |
|`<param name="N">`    |Parameter *N*          |Multiple allowed; rendered as a table                          |
|`<returns>`           |Return value           |Alias `<return>` also accepted                                 |
|`<exception cref="E">`|Exception *E*          |Multiple allowed; rendered as a table                          |
|`<raises name="E">`   |Alias for `<exception>`|`name=` or `cref=` attribute                                   |
|`<seealso cref="X">`  |Cross-reference        |Self-closing `<seealso cref="X"/>` preferred                   |
|`<example>`           |Code sample            |Internal whitespace **preserved** for code formatting          |
|`<note>`              |Advisory note          |Renders as AsciiDoc `[NOTE]` admonition                        |
|`<deprecated>`        |Deprecation notice     |Renders as AsciiDoc `[WARNING]` admonition; may be self-closing|
|`<since>`             |Version introduced     |                                                               |
|`<author>`            |Author name(s)         |                                                               |

### Full example

```pascal
/// <summary>Convert a MIDI note number to its scientific name.</summary>
/// <remarks>
///   Middle C is note 60 and is named C4.  The returned string uses
///   '#' for sharps; flats are not used.
/// </remarks>
/// <param name="Note">MIDI note number in the range 0–127.</param>
/// <returns>Note name with octave number, e.g. <c>A4</c>, <c>C#3</c>.</returns>
/// <exception cref="ERangeError">When Note is outside 0–127.</exception>
/// <example>
/// WriteLn(MidiNoteToName(69));  { A4 }
/// WriteLn(MidiNoteToName(60));  { C4 }
/// </example>
/// <seealso cref="NameToMidiNote"/>
/// <since>1.0</since>
function MidiNoteToName(Note: TMidiNote): string;
```

Plain text with no XML tags at all is accepted — the entire comment becomes
the summary:

```pascal
/// Releases all resources held by this object.
destructor Destroy; override;
```

-----

## Recognised Pascal declarations

The parser scans the full source file (both `interface` and `implementation`
sections) and extracts everything that carries a doc comment.

|Declaration                          |Emitted section|
|-------------------------------------|---------------|
|`unit` / `program` / `library` header|Overview       |
|`type` … `=` …                       |Types          |
|`const` … `=` …                      |Constants      |
|`var` … `:` …                        |Variables      |
|`procedure`, `function`              |Routines       |
|`constructor`, `destructor`          |Routines       |
|`property`                           |Properties     |

Multi-line declarations (e.g. procedures with long parameter lists) are
collected and flattened onto a single signature line in the output.

-----

## Output structure

The generated AsciiDoc file has the following skeleton:

```asciidoc
= Unit MyUnit
:toc: left
:sectnums:
...

== Overview
(module-level doc)

== Types
=== TMyType
.Declaration
[source,pascal]
----
TMyType = ...;
----
Summary text.

==== Parameters
...

== Constants
== Variables
== Routines
== Properties
```

Sections are omitted entirely when the file contains no documented entities of
that kind.

### AsciiDoc features used

|Feature                            |Used for                          |
|-----------------------------------|----------------------------------|
|`[source,pascal]` code blocks      |Signatures and `<example>` content|
|`[NOTE]` admonition                |`<note>` tags                     |
|`[WARNING]` admonition             |`<deprecated>` tags               |
|`[cols=…]` tables                  |Parameters and exceptions         |
|`:toc: left`                       |Auto-generated table of contents  |
|`:sectnums:`                       |Numbered sections                 |
|`:source-highlighter: highlight.js`|Syntax colouring (when rendered)  |

-----

## Tips and patterns

### Documenting a module

```pascal
(**
  <summary>Audio plugin utilities for the Schmitty Guitars toolchain.</summary>
  <remarks>
    Provides LV2 descriptor helpers, SysEx parsing, and tab rendering.
    Requires FPC 3.2 or later compiled with {$mode objfpc}{$H+}.
  </remarks>
  <author>Your Name</author>
  <since>1.0</since>
*)
unit SchmittyCore;
```

### Documenting a type alias

```pascal
type
  /// <summary>MIDI note number in the range 0–127.</summary>
  TMidiNote = 0..127;
```

### Documenting a callback type

```pascal
/// <summary>Called when the tab parser encounters a syntax error.</summary>
/// <param name="Line">1-based source line number.</param>
/// <param name="Msg">Human-readable error description.</param>
TErrorProc = procedure(Line: Integer; const Msg: string);
```

### Cross-referencing

```pascal
/// <summary>Parse a chord symbol into a TChord record.</summary>
/// <seealso cref="TChord"/>
/// <seealso cref="ChordToSVG"/>
function ParseChord(const Symbol: string; out Chord: TChord): Boolean;
```

### Marking deprecated items

```pascal
/// <summary>Render a chord diagram as SVG.</summary>
/// <deprecated>Use TChordDiagram.ToSVG instead.</deprecated>
function ChordToSVG(const Chord: TChord): string;
```

-----

## Known limitations

- **No cross-file linking.** Each `.pas` file produces a standalone document.
  Run the tool per-unit and link documents manually in AsciiDoc if needed.
- **Class hierarchy not tracked.** Methods inside a `class`/`record` type block
  are extracted as stand-alone routines; they are not nested under their type
  entry in the output.
- **Block comments `{ }` and `(* *)` are not parsed.** Only `///` and `(**`
  introduce doc comments. Regular `{ }` block comments are skipped.
- **Multi-line `{ }` comments** that span structural keywords (`type`,
  `procedure`, etc.) may confuse the section tracker. Well-formatted source
  is assumed.
- **No generic-type awareness.** Generic declarations such as
  `TList<T> = class…` are collected and displayed verbatim but their type
  parameters are not specially handled.