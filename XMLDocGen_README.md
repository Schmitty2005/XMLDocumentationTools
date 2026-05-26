# XmlDocGen — Pascal XML Documentation Comment Inserter

Scans Free Pascal source files and inserts **triple-slash XML doc-comment
templates** before every undocumented `procedure`, `function`, `constructor`,
and `destructor`, including a `<remarks>` block that lists the routine's local
variables.

---

## Files

| File | Purpose |
|------|---------|
| `xmldocgen.pas` | Library unit — the full parsing and insertion API |
| `adddocs.lpr` | Command-line tool that drives the unit |
| `SampleUnit.pas` | Example input file |
| `SampleUnit.out.pas` | What the output looks like after running `adddocs` |

---

## Compilation

```bash
# Compile the CLI tool (FPC automatically compiles the unit dependency)
fpc adddocs.lpr

# Or compile the unit on its own
fpc xmldocgen.pas
```

---

## CLI Usage

```
adddocs [flags] <input.pas> [<output.pas>]
```

If `<output.pas>` is omitted, the input file is **overwritten in place**.

### Flags

| Flag | Effect |
|------|--------|
| `--no-skip-fwd` | Also document `forward` declarations (default: skip) |
| `--no-skip-ext` | Also document `external` declarations (default: skip) |
| `--no-local-vars` | Omit the local variable `<remarks>` block |
| `--help`, `-h` | Print usage and exit |

### Examples

```bash
# Document MyUnit.pas in place
adddocs MyUnit.pas

# Write to a new file
adddocs MyUnit.pas MyUnit.documented.pas

# Include forward decls, omit local var lists
adddocs --no-skip-fwd --no-local-vars Src.pas Out.pas
```

---

## Library API

```pascal
uses XmlDocGen;

// Default options
var Opts := DefaultXmlDocOptions;
// Opts.SkipForward    = True
// Opts.SkipExternal   = True
// Opts.IncludeLocVars = True

// Process a string
var OutSrc := ProcessPascalSource(InSrc);
var OutSrc := ProcessPascalSource(InSrc, Opts);

// Process a file
ProcessPascalFile('MyUnit.pas', 'MyUnit.pas');        // in-place
ProcessPascalFile('MyUnit.pas', 'MyUnit.out.pas');    // new file
ProcessPascalFile('MyUnit.pas', 'MyUnit.out.pas', Opts);
```

---

## What It Generates

Given this input:

```pascal
function TWidget.ComputeHash(const ASalt: string; Rounds: Integer): Cardinal;
var
  Acc:   Cardinal;
  I, J:  Integer;
  Chunk: string;
begin
  ...
end;
```

The tool inserts:

```pascal
/// <summary>
///   
/// </summary>
/// <param name="ASalt"></param>
/// <param name="Rounds"></param>
/// <returns></returns>
/// <remarks>
///   <para>Local variables:</para>
///   <list type="bullet">
///     <item><term>Acc</term><description>: Cardinal</description></item>
///     <item><term>I</term><description>: Integer</description></item>
///     <item><term>J</term><description>: Integer</description></item>
///     <item><term>Chunk</term><description>: string</description></item>
///   </list>
/// </remarks>
function TWidget.ComputeHash(const ASalt: string; Rounds: Integer): Cardinal;
```

---

## Design Notes

### Parser architecture

1. **Visible-line builder** — Each source line is copied; characters inside
   block comments `{ }` / `(* *)`, line comments `//`, and string literals
   `'...'` are replaced with spaces. The substitution preserves column
   positions and tracks multi-line block-comment state across calls.

2. **Routine detection** — Each visible line is scanned for a routine keyword
   (`procedure`, `function`, `constructor`, `destructor`) where the only
   content before the keyword is optional whitespace or the single word
   `class`. This correctly rejects type aliases (`TProc = procedure(...)`),
   variable declarations (`F: function(...)`), and callback parameters.

3. **Header collection** — Lines are accumulated until a depth-0 section
   boundary is encountered (`begin`, `var`, `const`, `type`, `label`, or
   another routine keyword). Parenthesis depth tracks multi-line parameter
   lists.

4. **Header parsing** — Name extraction handles `TClass.Method` notation.
   The parameter list is split by `;` while respecting nested parentheses.
   Each segment is decomposed into modifier, name(s), and type. Functions
   yield a return type from the `:` clause after the closing `)`.

5. **Var-section parsing** — If the line immediately after the header is
   `var`, the following lines are parsed for `Name: Type;` declarations
   (also handling comma-grouped names and stripping `= default` values).

6. **Duplicate detection** — Scanning upward from the routine line, the
   first non-blank line is checked for a `///` prefix. A match means the
   routine is already documented and is skipped.

7. **Insertion** — Collected entries are sorted by line index descending.
   Doc-comment lines are inserted in reverse text order at the routine's
   original line index, so earlier insertions do not disturb the stored
   indices of later ones.

### Known limitations

- **Type-alias false-positive**: A bare `procedure` or `function` keyword
  that starts a line inside a multi-line type or var declaration (with the
  keyword on its own line) may be mistakenly treated as a routine header.
  This is rare in practice.

- **Inline begin**: `procedure Foo; begin ... end;` on one line is handled
  correctly; the single-line body is scanned through normally.

- **Attributes / annotations**: `[SomeAttr]` lines above a routine are not
  treated as part of the routine, so the doc comment is inserted between
  the attribute and the `procedure`/`function` keyword. Move the attribute
  below the generated comment if needed.

- **Line endings**: The detected line-ending style of the input file is
  preserved in the output.
