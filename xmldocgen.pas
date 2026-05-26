unit XmlDocGen;

(*
  XmlDocGen  -  Pascal XML Documentation Comment Inserter
  ========================================================

  Scans Free Pascal source files and inserts triple-slash (///) XML
  documentation comment templates before every undocumented routine
  (procedure, function, constructor, destructor), including a <remarks>
  block that lists the routine's local variable declarations.

  Features
  --------
  * Standalone and class-method declarations
  * `class procedure` / `class function`
  * Single-line and multi-line parameter lists
  * All parameter modifiers: var, const, out, constref
  * Multiple names per group  (A, B: Integer)
  * Local var sections emitted inside <remarks>/<list>
  * Block comments { } and (* *), line comments //
  * Pascal string literals with '' escaping
  * Nested routines (inner procedures / functions)

  Skips
  -----
  * Routines already preceded by a /// comment (no double-stamping)
  * `forward` declarations  (configurable)
  * `external` declarations (configurable)

  Usage
  -----
    uses XmlDocGen;
    ProcessPascalFile('MyUnit.pas', 'MyUnit.pas');     // in-place
    ProcessPascalFile('MyUnit.pas', 'MyUnit.doc.pas'); // to new file
    s := ProcessPascalSource(s);                       // string API
*)

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, StrUtils;

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

type
  TXmlDocOptions = record
    SkipForward:    Boolean; // Skip `forward` declarations   (default: True)
    SkipExternal:   Boolean; // Skip `external` declarations  (default: True)
    IncludeLocVars: Boolean; // Add local vars in <remarks>   (default: True)
  end;

function DefaultXmlDocOptions: TXmlDocOptions;

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

// Process a Pascal source string; returns it with XML doc templates added.
function ProcessPascalSource(const ASource: string;
                             const AOptions: TXmlDocOptions): string; overload;
function ProcessPascalSource(const ASource: string): string; overload;

// Process a Pascal source file.
// AOutputPath = '' means overwrite AInputPath in place.
procedure ProcessPascalFile(const AInputPath, AOutputPath: string;
                            const AOptions: TXmlDocOptions); overload;
procedure ProcessPascalFile(const AInputPath, AOutputPath: string); overload;

implementation

// ===========================================================================
// Internal types
// ===========================================================================

type
  TStrArr = array of string;

  TParamInfo = record
    Names:    TStrArr;  // Multiple names allowed: "A, B: Integer"
    TypeStr:  string;
    Modifier: string;   // '', 'var', 'const', 'out', 'constref'
  end;
  TParamArr = array of TParamInfo;

  TVarInfo = record
    Names:   TStrArr;
    TypeStr: string;
  end;
  TVarArr = array of TVarInfo;

  TRoutineKind = (rkProcedure, rkFunction, rkConstructor, rkDestructor);

  TRoutineEntry = record
    LineIndex:    Integer;     // 0-based index of the routine-keyword line
    Kind:         TRoutineKind;
    ClassName:    string;      // 'TFoo' when method; '' otherwise
    MethodName:   string;      // unqualified name
    Params:       TParamArr;
    ReturnType:   string;      // non-empty only for rkFunction
    LocalVars:    TVarArr;
    IsForward:    Boolean;
    IsExternal:   Boolean;
    HasDocAbove:  Boolean;     // already preceded by ///
    Indent:       string;      // leading whitespace of the declaration line
  end;
  TEntryArr = array of TRoutineEntry;

  TScanState = (ssNormal, ssBlockBrace, ssBlockParen, ssStr);

// ===========================================================================
// Low-level string helpers
// ===========================================================================

function IsWordCh(C: Char): Boolean; inline;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

// Leading whitespace of S
function LeadingWS(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] in [' ', #9]) do
    Inc(I);
  Result := Copy(S, 1, I - 1);
end;

// Split S at every occurrence of Delim (no nesting awareness)
function SplitOn(const S: string; Delim: Char): TStrArr;
var
  Start, I: Integer;
begin
  SetLength(Result, 0);
  Start := 1;
  for I := 1 to Length(S) do
    if S[I] = Delim then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(S, Start, I - Start);
      Start := I + 1;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(S, Start, Length(S) - Start + 1);
end;

// Split S at ';', skipping ';' inside parentheses
function SplitBySemi(const S: string): TStrArr;
var
  I, Depth, Start: Integer;
begin
  SetLength(Result, 0);
  Depth := 0;
  Start := 1;
  for I := 1 to Length(S) do
    case S[I] of
      '(': Inc(Depth);
      ')': if Depth > 0 then Dec(Depth);
      ';': if Depth = 0 then
           begin
             SetLength(Result, Length(Result) + 1);
             Result[High(Result)] := Copy(S, Start, I - Start);
             Start := I + 1;
           end;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(S, Start, Length(S) - Start + 1);
end;

// Find keyword Word (lowercase, exact word boundary) in S from StartPos (1-based)
// Returns 1-based position or 0 if not found
function FindWord(const S, Word: string; StartPos: Integer = 1): Integer;
var
  I, WLen: Integer;
begin
  Result := 0;
  WLen := Length(Word);
  if WLen = 0 then Exit;
  for I := StartPos to Length(S) - WLen + 1 do
    if LowerCase(Copy(S, I, WLen)) = Word then
      if ((I = 1) or not IsWordCh(S[I - 1])) and
         ((I + WLen > Length(S)) or not IsWordCh(S[I + WLen])) then
      begin
        Result := I;
        Exit;
      end;
end;

// True when S starts with Word (case-insensitive), not followed by a word char
function StartsWordCI(const S, Word: string): Boolean;
var
  WLen: Integer;
begin
  WLen := Length(Word);
  if Length(S) < WLen then
  begin
    Result := False;
    Exit;
  end;
  Result := LowerCase(Copy(S, 1, WLen)) = LowerCase(Word);
  if Result and (Length(S) > WLen) then
    Result := not IsWordCh(S[WLen + 1]);
end;

// Detect the line-ending style used in S
function DetectLineBreak(const S: string): string;
var
  I: Integer;
begin
  Result := LineEnding; // system default fallback
  for I := 1 to Length(S) do
    if S[I] = #10 then
    begin
      if (I > 1) and (S[I - 1] = #13) then
        Result := #13#10
      else
        Result := #10;
      Exit;
    end
    else if S[I] = #13 then
    begin
      Result := #13;
      Exit;
    end;
end;

// ===========================================================================
// Visible-line builder
//
// Replaces all comment text and string-literal characters with spaces so
// that keyword searches never match inside quoted or commented-out material.
// The State parameter is persistent across consecutive lines, allowing
// multi-line block comments to be handled correctly.
// ===========================================================================

function MakeVisible(const Line: string; var State: TScanState): string;
var
  I: Integer;
  C: Char;
begin
  // Start with a copy of the line; we'll blank out hidden regions
  SetLength(Result, Length(Line));
  if Length(Line) > 0 then
    Move(Line[1], Result[1], Length(Line));

  I := 1;
  while I <= Length(Line) do
  begin
    C := Line[I];
    case State of

      ssNormal:
        if (C = '/') and (I < Length(Line)) and (Line[I + 1] = '/') then
        begin
          // Line comment: blank from here to end of line
          while I <= Length(Line) do
          begin
            Result[I] := ' ';
            Inc(I);
          end;
        end
        else if C = '{' then
        begin
          State := ssBlockBrace;
          Result[I] := ' ';
          Inc(I);
        end
        else if (C = '(') and (I < Length(Line)) and (Line[I + 1] = '*') then
        begin
          State := ssBlockParen;
          Result[I] := ' '; Inc(I);
          Result[I] := ' '; Inc(I);
        end
        else if C = '''' then
        begin
          State := ssStr;
          Result[I] := ' ';
          Inc(I);
        end
        else
          Inc(I);

      ssBlockBrace:
      begin
        if C = '}' then State := ssNormal;
        Result[I] := ' ';
        Inc(I);
      end;

      ssBlockParen:
        if (C = '*') and (I < Length(Line)) and (Line[I + 1] = ')') then
        begin
          State := ssNormal;
          Result[I] := ' '; Inc(I);
          Result[I] := ' '; Inc(I);
        end
        else
        begin
          Result[I] := ' ';
          Inc(I);
        end;

      ssStr:
        if C = '''' then
        begin
          if (I < Length(Line)) and (Line[I + 1] = '''') then
          begin
            // Escaped quote ('') - both chars are part of the string literal
            Result[I] := ' '; Inc(I);
            Result[I] := ' '; Inc(I);
          end
          else
          begin
            State := ssNormal;
            Result[I] := ' ';
            Inc(I);
          end;
        end
        else
        begin
          Result[I] := ' ';
          Inc(I);
        end;

    end; // case State
  end; // while I <= Length(Line)
end;

// ===========================================================================
// Routine-keyword detection
// ===========================================================================

type
  TKwHit = record
    Found:     Boolean;
    Kind:      TRoutineKind;
    IsClassKw: Boolean;  // True when preceded by 'class'
  end;

// Return the first non-whitespace word of S
function FirstWord(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while (I <= Length(S)) and (S[I] in [' ', #9]) do
    Inc(I);
  while (I <= Length(S)) and IsWordCh(S[I]) do
  begin
    Result := Result + S[I];
    Inc(I);
  end;
end;

// Check whether VisLine contains a routine keyword (procedure / function /
// constructor / destructor) as the PRIMARY keyword on the line, optionally
// preceded by the single word 'class'.
//
// This correctly rejects:
//   var F: function(...): T;          (Before = 'F:')
//   type TProc = procedure(...);      (Before = 'TProc =')
//   ACallback: procedure of object;  (Before = 'ACallback:')
function DetectRoutineKw(const VisLine: string): TKwHit;
const
  KWS: array[0..3] of string =
    ('procedure', 'function', 'constructor', 'destructor');
  RKS: array[0..3] of TRoutineKind =
    (rkProcedure, rkFunction, rkConstructor, rkDestructor);
var
  I, P:   Integer;
  Before: string;
begin
  Result.Found := False;
  for I := 0 to 3 do
  begin
    P := FindWord(VisLine, KWS[I]);
    if P > 0 then
    begin
      Before := LowerCase(Trim(Copy(VisLine, 1, P - 1)));
      if (Before = '') or (Before = 'class') then
      begin
        Result.Found     := True;
        Result.Kind      := RKS[I];
        Result.IsClassKw := (Before = 'class');
        Exit;
      end;
    end;
  end;
end;

// ===========================================================================
// Header collector
//
// Assembles the (possibly multi-line) routine header into a single string.
// Stops *before* the first line whose first token is one of:
//   begin  var  const  type  label  procedure  function  constructor  destructor
// provided paren depth has returned to 0 and we are past the starting line.
// ===========================================================================

function CollectHeader(const VisLines: TStrArr; StartLine: Integer;
                       out NextLine: Integer): string;
var
  I, J, Depth: Integer;
  VL, FW:      string;
begin
  Result := '';
  Depth  := 0;
  I      := StartLine;

  while I < Length(VisLines) do
  begin
    VL := VisLines[I];
    FW := LowerCase(FirstWord(VL));

    // Stop before section-boundary keywords (but not on the very first line)
    if (I > StartLine) and (Depth = 0) then
      if (FW = 'begin')       or (FW = 'var')         or
         (FW = 'const')       or (FW = 'type')        or
         (FW = 'label')       or
         (FW = 'procedure')   or (FW = 'function')    or
         (FW = 'constructor') or (FW = 'destructor')  then
        Break;

    if Result <> '' then Result := Result + ' ';
    Result := Result + VL;

    for J := 1 to Length(VL) do
      case VL[J] of
        '(': Inc(Depth);
        ')': if Depth > 0 then Dec(Depth);
      end;

    Inc(I);
  end;

  NextLine := I;
end;

// ===========================================================================
// Parameter-list parser
// Parses the text that appears between the outer ( ) of a routine header.
// ===========================================================================

function ParseParams(const S: string): TParamArr;
const
  MODS: array[0..3] of string = ('constref', 'const', 'var', 'out');
var
  Segs:              TStrArr;
  I, J, ColonPos:   Integer;
  T, Mod_, NStr, TStr: string;
  NP:                TStrArr;
  P:                 TParamInfo;
begin
  SetLength(Result, 0);
  if Trim(S) = '' then Exit;

  Segs := SplitBySemi(S);

  for I := 0 to High(Segs) do
  begin
    T := Trim(Segs[I]);
    if T = '' then Continue;

    // Detect parameter modifier
    Mod_ := '';
    for J := 0 to High(MODS) do
      if StartsWordCI(T, MODS[J]) then
      begin
        Mod_ := MODS[J];
        T    := Trim(Copy(T, Length(MODS[J]) + 1, MaxInt));
        Break;
      end;

    // Split at first ':'
    ColonPos := 0;
    for J := 1 to Length(T) do
      if T[J] = ':' then
      begin
        ColonPos := J;
        Break;
      end;

    if ColonPos > 0 then
    begin
      NStr := Trim(Copy(T, 1, ColonPos - 1));
      TStr := Trim(Copy(T, ColonPos + 1, MaxInt));
    end
    else
    begin
      NStr := T;
      TStr := '';
    end;

    // Split names on ','
    NP         := SplitOn(NStr, ',');
    P.Modifier := Mod_;
    P.TypeStr  := TStr;
    SetLength(P.Names, Length(NP));
    for J := 0 to High(NP) do
      P.Names[J] := Trim(NP[J]);

    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := P;
  end;
end;

// ===========================================================================
// Header parser
// Extracts class name, method name, parameters, return type, and directive
// flags from the collected header text.
// ===========================================================================

// Return the keyword string for a given TRoutineKind
function KindKeyword(Kind: TRoutineKind): string;
begin
  case Kind of
    rkProcedure:   Result := 'procedure';
    rkFunction:    Result := 'function';
    rkConstructor: Result := 'constructor';
    rkDestructor:  Result := 'destructor';
  else
    Result := '';
  end;
end;

procedure ParseHeader(const H: string; Kind: TRoutineKind;
  out CName, MName:  string;
  out Params:        TParamArr;
  out RetType:       string;
  out IsFwd, IsExt:  Boolean);
var
  Pos_, DotPos, Depth, I, ParenEnd: Integer;
  C:                 Char;
  LH, FullName, ParamStr, RetStr: string;
begin
  CName   := '';
  MName   := '';
  SetLength(Params, 0);
  RetType := '';
  IsFwd   := False;
  IsExt   := False;

  LH   := LowerCase(H);
  Pos_ := FindWord(LH, KindKeyword(Kind));
  if Pos_ = 0 then Exit;

  Inc(Pos_, Length(KindKeyword(Kind)));

  // Skip whitespace
  while (Pos_ <= Length(H)) and (H[Pos_] in [' ', #9]) do Inc(Pos_);

  // Extract qualified name (TClass.Method or plain Name)
  FullName := '';
  while (Pos_ <= Length(H)) and
        (H[Pos_] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
  begin
    FullName := FullName + H[Pos_];
    Inc(Pos_);
  end;

  // Split on the last dot to separate class name from method name
  DotPos := 0;
  for I := Length(FullName) downto 1 do
    if FullName[I] = '.' then
    begin
      DotPos := I;
      Break;
    end;

  if DotPos > 0 then
  begin
    CName := Copy(FullName, 1, DotPos - 1);
    MName := Copy(FullName, DotPos + 1, MaxInt);
  end
  else
    MName := FullName;

  // Skip whitespace
  while (Pos_ <= Length(H)) and (H[Pos_] in [' ', #9]) do Inc(Pos_);

  // Parse parameter list enclosed in ( )
  if (Pos_ <= Length(H)) and (H[Pos_] = '(') then
  begin
    Depth    := 0;
    ParenEnd := Pos_;
    I        := Pos_;
    while I <= Length(H) do
    begin
      C := H[I];
      if C = '(' then
        Inc(Depth)
      else if C = ')' then
      begin
        Dec(Depth);
        if Depth = 0 then
        begin
          ParenEnd := I;
          Break;
        end;
      end;
      Inc(I);
    end;

    ParamStr := Copy(H, Pos_ + 1, ParenEnd - Pos_ - 1);
    Params   := ParseParams(ParamStr);
    Pos_     := ParenEnd + 1;
  end;

  // Skip whitespace
  while (Pos_ <= Length(H)) and (H[Pos_] in [' ', #9]) do Inc(Pos_);

  // Return type for functions (after ':')
  if (Kind = rkFunction) and (Pos_ <= Length(H)) and (H[Pos_] = ':') then
  begin
    Inc(Pos_);
    while (Pos_ <= Length(H)) and (H[Pos_] in [' ', #9]) do Inc(Pos_);
    RetStr := '';
    while (Pos_ <= Length(H)) and (H[Pos_] <> ';') do
    begin
      RetStr := RetStr + H[Pos_];
      Inc(Pos_);
    end;
    RetType := Trim(RetStr);
  end;

  // Directive flags
  IsFwd := FindWord(LH, 'forward')  > 0;
  IsExt := FindWord(LH, 'external') > 0;
end;

// ===========================================================================
// Local var-section parser
// Parses the `var` block that follows a routine header (before `begin`).
// ===========================================================================

function ParseVarSection(const VisLines: TStrArr; StartLine: Integer;
                         out NextLine: Integer): TVarArr;
var
  I, J, ColonPos: Integer;
  VL, T, FW, TrimLine, NS, TS: string;
  NP:    TStrArr;
  VI:    TVarInfo;
  InVar: Boolean;
begin
  SetLength(Result, 0);
  InVar := False;
  I     := StartLine;

  while I < Length(VisLines) do
  begin
    VL := VisLines[I];
    T  := Trim(VL);
    FW := LowerCase(FirstWord(T));

    // 'var' keyword enters the var section
    if FW = 'var' then
    begin
      InVar := True;
      Inc(I);
      Continue;
    end;

    // Any of these keywords end the var section
    if (FW = 'begin')       or (FW = 'const')       or
       (FW = 'type')        or (FW = 'label')        or
       (FW = 'procedure')   or (FW = 'function')     or
       (FW = 'constructor') or (FW = 'destructor')   then
      Break;

    if InVar and (T <> '') then
    begin
      // Strip trailing ';' and whitespace
      TrimLine := T;
      while (Length(TrimLine) > 0) and
            (TrimLine[Length(TrimLine)] in [';', ' ', #9]) do
        SetLength(TrimLine, Length(TrimLine) - 1);

      // Find the ':' that separates names from type
      ColonPos := 0;
      for J := 1 to Length(TrimLine) do
        if TrimLine[J] = ':' then
        begin
          ColonPos := J;
          Break;
        end;

      if ColonPos > 0 then
      begin
        NS := Trim(Copy(TrimLine, 1, ColonPos - 1));
        TS := Trim(Copy(TrimLine, ColonPos + 1, MaxInt));

        // Strip default value initialiser (= ...)
        for J := 1 to Length(TS) do
          if TS[J] = '=' then
          begin
            TS := Trim(Copy(TS, 1, J - 1));
            Break;
          end;

        NP := SplitOn(NS, ',');
        VI.TypeStr := TS;
        SetLength(VI.Names, Length(NP));
        for J := 0 to High(NP) do
          VI.Names[J] := Trim(NP[J]);

        if (Length(VI.Names) > 0) and (VI.Names[0] <> '') then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := VI;
        end;
      end;
    end;

    Inc(I);
  end;

  NextLine := I;
end;

// ===========================================================================
// Existing-doc-comment detection
// ===========================================================================

// Returns True when the first non-blank line above LineIdx starts with ///
function HasDocAbove(const Lines: TStringList; LineIdx: Integer): Boolean;
var
  I: Integer;
  T: string;
begin
  Result := False;
  I := LineIdx - 1;
  while I >= 0 do
  begin
    T := Trim(Lines[I]);
    if T = '' then
    begin
      Dec(I);
      Continue;
    end;
    Result := (Length(T) >= 3) and (T[1] = '/') and (T[2] = '/') and (T[3] = '/');
    Exit;
  end;
end;

// ===========================================================================
// Doc-comment generator
// ===========================================================================

procedure BuildDocComment(const E: TRoutineEntry;
                          const AOptions: TXmlDocOptions;
                          Dest: TStringList);
var
  I, J:  Integer;
  Pfx, PName: string;
begin
  Pfx := E.Indent;

  // <summary> block
  Dest.Add(Pfx + '/// <summary>');
  Dest.Add(Pfx + '///   ');
  Dest.Add(Pfx + '/// </summary>');

  // One <param> per parameter name
  for I := 0 to High(E.Params) do
    for J := 0 to High(E.Params[I].Names) do
    begin
      PName := Trim(E.Params[I].Names[J]);
      if PName = '' then Continue;
      Dest.Add(Format('%s/// <param name="%s"></param>', [Pfx, PName]));
    end;

  // <returns> for functions
  if E.Kind = rkFunction then
    Dest.Add(Format('%s/// <returns></returns>', [Pfx]));

  // <remarks> with local variable list
  if AOptions.IncludeLocVars and (Length(E.LocalVars) > 0) then
  begin
    Dest.Add(Pfx + '/// <remarks>');
    Dest.Add(Pfx + '///   <para>Local variables:</para>');
    Dest.Add(Pfx + '///   <list type="bullet">');
    for I := 0 to High(E.LocalVars) do
      for J := 0 to High(E.LocalVars[I].Names) do
      begin
        PName := Trim(E.LocalVars[I].Names[J]);
        if PName = '' then Continue;
        Dest.Add(
          Format('%s///     <item>' +
                 '<term>%s</term>' +
                 '<description>: %s</description>' +
                 '</item>',
                 [Pfx, PName, E.LocalVars[I].TypeStr]));
      end;
    Dest.Add(Pfx + '///   </list>');
    Dest.Add(Pfx + '/// </remarks>');
  end;
end;

// ===========================================================================
// Sort entries by LineIndex descending (insertion sort)
// Descending order lets us insert from bottom to top so earlier line indices
// remain valid as we insert comment lines above later declarations.
// ===========================================================================

procedure SortDesc(var A: TEntryArr);
var
  I, J: Integer;
  T:    TRoutineEntry;
begin
  for I := 1 to High(A) do
  begin
    T := A[I];
    J := I - 1;
    while (J >= 0) and (A[J].LineIndex < T.LineIndex) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := T;
  end;
end;

// ===========================================================================
// Public API  -  core implementation
// ===========================================================================

function DefaultXmlDocOptions: TXmlDocOptions;
begin
  Result.SkipForward    := True;
  Result.SkipExternal   := True;
  Result.IncludeLocVars := True;
end;

function ProcessPascalSource(const ASource: string;
                             const AOptions: TXmlDocOptions): string;
var
  Lines:    TStringList;
  VisLines: TStrArr;
  State:    TScanState;
  I, HEnd, NL, J: Integer;
  KwHit:   TKwHit;
  Entries: TEntryArr;
  E:       TRoutineEntry;
  Header:  string;
  DocLines: TStringList;
begin
  Lines    := TStringList.Create;
  DocLines := TStringList.Create;
  try
    Lines.LineBreak := DetectLineBreak(ASource);
    Lines.Text      := ASource;

    // ------------------------------------------------------------------
    // Build a parallel array of "visible" lines (comments & strings
    // replaced by spaces) for safe keyword matching.
    // ------------------------------------------------------------------
    SetLength(VisLines, Lines.Count);
    State := ssNormal;
    for I := 0 to Lines.Count - 1 do
      VisLines[I] := MakeVisible(Lines[I], State);

    // ------------------------------------------------------------------
    // Pass 1  -  collect all routine declarations
    // ------------------------------------------------------------------
    SetLength(Entries, 0);
    I := 0;
    while I < Lines.Count do
    begin
      KwHit := DetectRoutineKw(VisLines[I]);
      if not KwHit.Found then
      begin
        Inc(I);
        Continue;
      end;

      // Initialise all fields (avoids uninitialized managed-type fields)
      E.LineIndex   := I;
      E.Kind        := KwHit.Kind;
      E.Indent      := LeadingWS(Lines[I]);
      E.HasDocAbove := HasDocAbove(Lines, I);
      E.ClassName   := '';
      E.MethodName  := '';
      SetLength(E.Params, 0);
      E.ReturnType  := '';
      SetLength(E.LocalVars, 0);
      E.IsForward   := False;
      E.IsExternal  := False;

      // Gather the full (possibly multi-line) header into one string
      Header := CollectHeader(VisLines, I, HEnd);

      // Extract name, params, return type, and directive flags
      ParseHeader(Header, E.Kind,
        E.ClassName, E.MethodName, E.Params, E.ReturnType,
        E.IsForward, E.IsExternal);

      // If a var section immediately follows the header, parse it
      if AOptions.IncludeLocVars and (HEnd < Length(VisLines)) then
        if LowerCase(FirstWord(Trim(VisLines[HEnd]))) = 'var' then
          E.LocalVars := ParseVarSection(VisLines, HEnd, NL);

      // Apply skip filters
      if (not E.IsForward  or not AOptions.SkipForward) and
         (not E.IsExternal or not AOptions.SkipExternal) then
      begin
        SetLength(Entries, Length(Entries) + 1);
        Entries[High(Entries)] := E;
      end;

      // Advance past the collected header; the next iteration will pick
      // up whatever follows (begin / var / another routine keyword, etc.)
      I := HEnd;
    end;

    // ------------------------------------------------------------------
    // Pass 2  -  insert doc comments in reverse line order so that
    //            earlier line indices remain valid as we insert.
    // ------------------------------------------------------------------
    SortDesc(Entries);

    for I := 0 to High(Entries) do
    begin
      if Entries[I].HasDocAbove then Continue;

      DocLines.Clear;
      BuildDocComment(Entries[I], AOptions, DocLines);

      // Insert lines in reverse order at the same index so they end up
      // in the correct top-to-bottom order above the routine.
      for J := DocLines.Count - 1 downto 0 do
        Lines.Insert(Entries[I].LineIndex, DocLines[J]);
    end;

    Result := Lines.Text;

  finally
    Lines.Free;
    DocLines.Free;
  end;
end;

function ProcessPascalSource(const ASource: string): string;
begin
  Result := ProcessPascalSource(ASource, DefaultXmlDocOptions);
end;

procedure ProcessPascalFile(const AInputPath, AOutputPath: string;
                            const AOptions: TXmlDocOptions);
var
  SL:      TStringList;
  Src:     string;
  OutPath: string;
begin
  // Load
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AInputPath);
    Src := SL.Text;
  finally
    SL.Free;
  end;

  // Process
  Src := ProcessPascalSource(Src, AOptions);

  // Save
  if AOutputPath = '' then
    OutPath := AInputPath
  else
    OutPath := AOutputPath;

  SL := TStringList.Create;
  try
    SL.Text := Src;
    SL.SaveToFile(OutPath);
  finally
    SL.Free;
  end;
end;

procedure ProcessPascalFile(const AInputPath, AOutputPath: string);
begin
  ProcessPascalFile(AInputPath, AOutputPath, DefaultXmlDocOptions);
end;

end.
