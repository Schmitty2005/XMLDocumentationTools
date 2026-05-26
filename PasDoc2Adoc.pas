{ PasDoc2Adoc.pas
  ──────────────────────────────────────────────────────────────────────────
  Free Pascal  ·  XML doc-comment extractor → AsciiDoctor output

  Supported doc-comment styles
  ────────────────────────────
  · Triple-slash   /// text or /// <tag>...</tag>  (consecutive lines merged)
  · Block-doc      (** ... *)  with optional leading * per line

  Supported XML tags
  ──────────────────
  <summary>             Short description
  <remarks>             Extended description
  <param name="N">      Parameter N
  <returns> / <return>  Return-value description
  <exception cref="E">  Exception that may be raised
  <raises name="E">     Alias for <exception>
  <seealso cref="X">    Cross-reference  (or inner text)
  <example>             Code sample (whitespace preserved)
  <since>               Version introduced
  <author>              Author name(s)
  <note>                Advisory note (AsciiDoc NOTE block)
  <deprecated>          Deprecation notice (AsciiDoc WARNING block)

  Recognised Pascal declarations
  ───────────────────────────────
  unit / program / library header
  procedure / function / constructor / destructor
  type  declarations  (inside  type  section)
  const declarations  (inside  const section)
  var   declarations  (inside  var   section)
  property            (inside  class / record)

  Usage
  ─────
  PasDoc2Adoc  <source.pas>  [output.adoc]

  When the output file is omitted the AsciiDoc is written to stdout.
  ────────────────────────────────────────────────────────────────────────── }

program PasDoc2Adoc;
{$mode objfpc}{$H+}
{$implicitexceptions off}

uses
  SysUtils, Classes, StrUtils;

const
  PROG_NAME    = 'PasDoc2Adoc';
  PROG_VERSION = '1.0';

{ ==============================================================
  Data types
  ============================================================== }

type
  TEntityKind = (
    ekModule,                              { unit / program / library   }
    ekProcedure,  ekFunction,              { routines                   }
    ekConstructor, ekDestructor,           { class lifecycle            }
    ekType,  ekConst,  ekVar,  ekProperty  { declaration sections       }
  );

  TParamEntry = record
    Name : string;
    Text : string;
  end;
  TParamArray = array of TParamEntry;

  TDocBlock = record
    Summary    : string;
    Remarks    : string;
    Returns    : string;
    SeeAlso    : string;
    Example    : string;
    Since      : string;
    Author     : string;
    Note       : string;
    Deprecated : string;
    Params     : TParamArray;
    Raises     : TParamArray;
    HasDoc     : Boolean;
  end;

  TEntity = record
    Kind      : TEntityKind;
    Name      : string;
    Signature : string;
    Doc       : TDocBlock;
  end;
  TEntityArr = array of TEntity;

{ ==============================================================
  Program-wide state
  ============================================================== }

var
  GEntities    : TEntityArr;
  GEntityCount : Integer = 0;
  GModuleName  : string  = '';
  GModuleType  : string  = 'unit';
  GModuleDoc   : TDocBlock;

{ ==============================================================
  Low-level helpers
  ============================================================== }

procedure PushParam(var A: TParamArray; const N, V: string);
var L: Integer;
begin
  L := Length(A);  SetLength(A, L + 1);
  A[L].Name := N;  A[L].Text := V;
end;

procedure PushEntity(const E: TEntity);
begin
  if GEntityCount >= Length(GEntities) then
    SetLength(GEntities, GEntityCount + 64);
  GEntities[GEntityCount] := E;
  Inc(GEntityCount);
end;

{ Collapse all whitespace runs to single spaces and strip margins }
function Squash(const S: string): string;
var
  I   : Integer;
  InWS: Boolean;
  C   : Char;
begin
  Result := '';
  InWS   := False;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in [' ', #9, #10, #13] then
    begin
      if not InWS then begin Result += ' '; InWS := True; end;
    end
    else begin Result += C;  InWS := False; end;
  end;
  Result := Trim(Result);
end;

{ ==============================================================
  Lightweight XML doc-comment parser
  ==============================================================

  The functions below locate XML tags by simple string scanning.
  They are intentionally minimal – the doc XML is never deeply
  nested and no full XML parser is needed. }

{ Locate the next occurrence of <TagName ...>content</TagName>
  in S starting at StartPos (case-insensitive tag matching).

  Out parameters (valid only when Result = True):
    TagStart     – index of the opening '<'
    ContentStart – index of first char AFTER the opening '>'
    ContentEnd   – index of last  char BEFORE the closing '</'
    TagEnd       – index of last  char of '</TagName>'

  Self-closing tags (<tag/>) set ContentEnd < ContentStart. }
function LocateTag(const S, TagName: string; StartPos: Integer;
                   out TagStart, ContentStart, ContentEnd, TagEnd: Integer): Boolean;
var
  SL, TL, OpenPat, ClosePat: string;
  P, Q                      : Integer;
begin
  Result := False;
  SL      := LowerCase(S);
  TL      := LowerCase(TagName);
  OpenPat  := '<'  + TL;
  ClosePat := '</' + TL + '>';

  P := PosEx(OpenPat, SL, StartPos);
  while P > 0 do
  begin
    { Verify it is a true tag boundary – the char after the tag name
      must be a space, '>', '/', or whitespace control char. }
    Q := P + Length(OpenPat);
    if (Q <= Length(S)) and not (S[Q] in [' ', '>', '/', #9, #10, #13]) then
    begin
      P := PosEx(OpenPat, SL, P + 1);
      Continue;
    end;

    TagStart := P;
    Q := PosEx('>', S, P);
    if Q = 0 then Exit;

    { Self-closing tag <tag ... /> }
    if (Q >= 2) and (S[Q - 1] = '/') then
    begin
      ContentStart := Q + 1;
      ContentEnd   := Q;        { CE < CS signals empty content }
      TagEnd       := Q;
      Result := True;  Exit;
    end;

    ContentStart := Q + 1;

    { Find closing tag }
    P := PosEx(ClosePat, SL, ContentStart);
    if P = 0 then
    begin
      { Unclosed tag – treat as having empty content }
      ContentEnd := Q;
      TagEnd     := Q;
      Result := True;  Exit;
    end;

    ContentEnd := P - 1;
    TagEnd     := P + Length(ClosePat) - 1;
    Result := True;  Exit;
  end;
end;

{ Extract the value of an XML attribute (handles " and ' delimiters) }
function XmlAttr(const TagStr, Attr: string): string;
var
  SL, Pattern: string;
  P1, P2     : Integer;
  Delim      : Char;
begin
  Result := '';
  SL      := LowerCase(TagStr);
  Pattern := LowerCase(Attr) + '=';
  P1 := Pos(Pattern, SL);
  if P1 = 0 then Exit;
  Inc(P1, Length(Pattern));
  if P1 > Length(TagStr) then Exit;

  if TagStr[P1] in ['"', #39] then
  begin
    Delim := TagStr[P1];  Inc(P1);
    P2 := P1;
    while (P2 <= Length(TagStr)) and (TagStr[P2] <> Delim) do Inc(P2);
  end
  else
  begin
    P2 := P1;
    while (P2 <= Length(TagStr)) and not (TagStr[P2] in [' ', '>', '/']) do Inc(P2);
  end;

  Result := Copy(TagStr, P1, P2 - P1);
end;

{ Collect every occurrence of <TagName PrimaryAttr="name">text</TagName>
  into Arr (falls back to 'cref' if the primary attribute is absent). }
procedure ExtractTagList(const S, TagName: string;
                         var   Arr        : TParamArray;
                         const PrimaryAttr: string = 'name');
var
  P, TS, CS, CE, TE: Integer;
  OpenStr, AName, Inner: string;
begin
  P := 1;
  while LocateTag(S, TagName, P, TS, CS, CE, TE) do
  begin
    OpenStr := Copy(S, TS, CS - TS);
    AName   := XmlAttr(OpenStr, PrimaryAttr);
    if (AName = '') and (PrimaryAttr <> 'cref') then
      AName := XmlAttr(OpenStr, 'cref');
    Inner := '';
    if CE >= CS then Inner := Squash(Copy(S, CS, CE - CS + 1));
    PushParam(Arr, AName, Inner);
    P := TE + 1;
  end;
end;

{ Parse raw XML doc text into a TDocBlock }
procedure ParseDoc(const Raw: string; out Doc: TDocBlock);
var
  TS, CS, CE, TE: Integer;
  OpenStr       : string;
  HasAnyTag     : Boolean;

  function TagText(const Tag: string): string;
  begin
    Result := '';
    if LocateTag(Raw, Tag, 1, TS, CS, CE, TE) and (CE >= CS) then
      Result := Squash(Copy(Raw, CS, CE - CS + 1));
  end;

begin
  FillChar(Doc, SizeOf(Doc), 0);
  if Trim(Raw) = '' then Exit;
  Doc.HasDoc  := True;
  HasAnyTag   := Pos('<', Raw) > 0;

  Doc.Summary := TagText('summary');
  Doc.Remarks := TagText('remarks');
  Doc.Returns := TagText('returns');
  if Doc.Returns = '' then Doc.Returns := TagText('return');
  Doc.Since   := TagText('since');
  Doc.Author  := TagText('author');
  Doc.Note    := TagText('note');

  { <example> – preserve internal whitespace for code formatting }
  if LocateTag(Raw, 'example', 1, TS, CS, CE, TE) and (CE >= CS) then
    Doc.Example := Trim(Copy(Raw, CS, CE - CS + 1));

  { <deprecated> may be self-closing or carry a message }
  if LocateTag(Raw, 'deprecated', 1, TS, CS, CE, TE) then
  begin
    if CE >= CS then Doc.Deprecated := Squash(Copy(Raw, CS, CE - CS + 1));
    if Doc.Deprecated = '' then Doc.Deprecated := 'This item is deprecated.';
  end;

  { <seealso cref="X"/> or <seealso>X</seealso> }
  if LocateTag(Raw, 'seealso', 1, TS, CS, CE, TE) then
  begin
    OpenStr     := Copy(Raw, TS, CS - TS);
    Doc.SeeAlso := XmlAttr(OpenStr, 'cref');
    if (Doc.SeeAlso = '') and (CE >= CS) then
      Doc.SeeAlso := Squash(Copy(Raw, CS, CE - CS + 1));
  end;

  { Multi-occurrence tags }
  ExtractTagList(Raw, 'param',     Doc.Params, 'name');
  ExtractTagList(Raw, 'exception', Doc.Raises, 'cref');
  ExtractTagList(Raw, 'raises',    Doc.Raises, 'name');

  { No XML tags at all → treat the entire text as the summary }
  if not HasAnyTag then Doc.Summary := Squash(Raw);

  { Promote <remarks> to summary when <summary> is absent }
  if (Doc.Summary = '') and (Doc.Remarks <> '') then
  begin
    Doc.Summary := Doc.Remarks;
    Doc.Remarks := '';
  end;
end;

{ ==============================================================
  Pascal source parser
  ============================================================== }

type
  TSection = (secNone, secType, secConst, secVar);

  TParser = class
  private
    FLines      : TStringList;
    FIdx        : Integer;
    FSection    : TSection;
    FModDocDone : Boolean;

    function  AtEnd   : Boolean; inline;
    function  CurRaw  : string;  inline;
    function  CurLine : string;  inline;   { trimmed }
    procedure Advance; inline;
    procedure SkipBlanks;

    function  IsTripleSlash (const S: string): Boolean;
    function  IsBlockDocOpen(const S: string): Boolean;

    function  ReadTripleSlash: string;
    function  ReadBlockDoc   : string;
    { Read a declaration, tracking paren depth, up to the closing ';'.
      Returns the result flattened onto one line. Capped at MaxDeclLines. }
    function  ReadDecl: string;

    { Classify a declaration string → entity kind + name }
    function  Classify(const Decl: string;
                        out K   : TEntityKind;
                        out Name, Sig: string): Boolean;

    { Attach a collected XML doc to whatever declaration follows }
    procedure ApplyDoc(const XML: string);

    { Skip past the header of an undocumented procedure/function }
    procedure SkipRoutineHeader;

  public
    constructor Create(ALines: TStringList);
    procedure   Execute;
  end;

const
  MaxDeclLines = 24;

constructor TParser.Create(ALines: TStringList);
begin
  FLines      := ALines;
  FIdx        := 0;
  FSection    := secNone;
  FModDocDone := False;
  FillChar(GModuleDoc, SizeOf(GModuleDoc), 0);
end;

function TParser.AtEnd   : Boolean; begin Result := FIdx >= FLines.Count;  end;
function TParser.CurRaw  : string;  begin if AtEnd then Result := '' else Result := FLines[FIdx]; end;
function TParser.CurLine : string;  begin Result := Trim(CurRaw); end;
procedure TParser.Advance;          begin if not AtEnd then Inc(FIdx); end;

procedure TParser.SkipBlanks;
begin
  while not AtEnd and (CurLine = '') do Advance;
end;

function TParser.IsTripleSlash(const S: string): Boolean;
var T: string;
begin
  T := TrimLeft(S);
  Result := (Length(T) >= 3) and (T[1] = '/') and (T[2] = '/') and (T[3] = '/');
end;

function TParser.IsBlockDocOpen(const S: string): Boolean;
var T: string;
begin
  T := TrimLeft(S);
  Result := (Length(T) >= 3) and (T[1] = '(') and (T[2] = '*') and (T[3] = '*');
end;

{ ── Collect consecutive  ///  lines, stripping the prefix ── }
function TParser.ReadTripleSlash: string;
var
  SL : TStringList;
  T  : string;
begin
  SL := TStringList.Create;
  try
    while not AtEnd and IsTripleSlash(CurRaw) do
    begin
      T := TrimLeft(CurRaw);
      Delete(T, 1, 3);                            { strip '///' }
      if (T <> '') and (T[1] = ' ') then Delete(T, 1, 1);   { strip one leading space }
      SL.Add(T);
      Advance;
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ── Collect a  (** ... *)  block comment ── }
function TParser.ReadBlockDoc: string;
var
  SL  : TStringList;
  T   : string;
  P   : Integer;
  Done: Boolean;
begin
  SL := TStringList.Create;
  try
    { First line: strip '(**' }
    T := TrimLeft(CurRaw);
    Delete(T, 1, 3);
    P := Pos('*)', T);
    if P > 0 then
    begin                              { Single-line block comment }
      SL.Add(Trim(Copy(T, 1, P - 1)));
      Advance;
      Result := SL.Text;
      Exit;
    end;
    T := Trim(T);
    if T <> '' then SL.Add(T);
    Advance;

    Done := False;
    while not AtEnd and not Done do
    begin
      T := CurRaw;
      P := Pos('*)', T);
      if P > 0 then
      begin
        T    := TrimLeft(Copy(T, 1, P - 1));
        if (T <> '') and (T[1] = '*') then Delete(T, 1, 1);
        T    := Trim(T);
        if T <> '' then SL.Add(T);
        Done := True;
      end
      else
      begin
        T := TrimLeft(T);
        if (T <> '') and (T[1] = '*') then Delete(T, 1, 1);
        SL.Add(Trim(T));
      end;
      Advance;
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ── Collect a declaration across multiple lines ── }
function TParser.ReadDecl: string;
var
  Parts    : TStringList;
  T, TLow  : string;
  Depth, I : Integer;
  LineCount: Integer;
  C        : Char;
begin
  Parts := TStringList.Create;
  try
    Depth     := 0;
    LineCount := 0;
    while not AtEnd and (LineCount < MaxDeclLines) do
    begin
      T := CurLine;

      { Track parenthesis depth to avoid breaking on ';' inside param lists }
      for I := 1 to Length(T) do
      begin
        C := T[I];
        if C = '(' then Inc(Depth)
        else if C = ')' then Dec(Depth);
      end;

      Parts.Add(T);
      Inc(LineCount);
      Advance;

      if Depth <= 0 then
      begin
        if Pos(';', T) > 0 then Break;   { found end of declaration }

        TLow := LowerCase(T);
        if (TLow = '')              or (TLow = 'begin')
        or (TLow = 'interface')     or (TLow = 'implementation')
        or (TLow = 'type')          or (TLow = 'const')
        or (TLow = 'var') then Break;
      end;
    end;

    { Flatten to a single line }
    Result := Trim(Parts.Text);
    Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10,    ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #13,    ' ', [rfReplaceAll]);
    while Pos('  ', Result) > 0 do
      Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  finally
    Parts.Free;
  end;
end;

{ ── Determine the kind and name of a declaration ── }
function TParser.Classify(const Decl: string;
                            out K   : TEntityKind;
                            out Name, Sig: string): Boolean;
var
  T, TLow, Rest: string;
  P            : Integer;
begin
  Result := False;
  Name := '';  Sig := '';  K := ekModule;
  T    := Trim(Decl);
  TLow := LowerCase(T);
  Sig  := T;

  { Keyword-based classification takes priority over section context }
  if      AnsiStartsText('procedure ',    TLow) then begin K := ekProcedure;   Rest := Copy(T, 11, MaxInt); end
  else if AnsiStartsText('function ',     TLow) then begin K := ekFunction;    Rest := Copy(T, 10, MaxInt); end
  else if AnsiStartsText('constructor ',  TLow) then begin K := ekConstructor; Rest := Copy(T, 13, MaxInt); end
  else if AnsiStartsText('destructor ',   TLow) then begin K := ekDestructor;  Rest := Copy(T, 12, MaxInt); end
  else if AnsiStartsText('property ',     TLow) then begin K := ekProperty;    Rest := Copy(T, 10, MaxInt); end
  else if FSection = secType  then begin K := ekType;  Rest := T; end
  else if FSection = secConst then begin K := ekConst; Rest := T; end
  else if FSection = secVar   then begin K := ekVar;   Rest := T; end
  else Exit;  { Cannot classify }

  { Extract leading identifier (dots allowed for qualified names) }
  Rest := TrimLeft(Rest);
  P    := 1;
  while (P <= Length(Rest))
    and (Rest[P] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
    Inc(P);
  Name := Copy(Rest, 1, P - 1);
  if Name = '' then Exit;

  Result := True;
end;

{ ── Skip the header of an undocumented routine (to ';' at depth 0) ── }
procedure TParser.SkipRoutineHeader;
var
  T    : string;
  Dep,I: Integer;
  C    : Char;
begin
  Dep := 0;
  while not AtEnd do
  begin
    T := CurLine;
    for I := 1 to Length(T) do
    begin
      C := T[I];
      if C = '(' then Inc(Dep) else if C = ')' then Dec(Dep);
    end;
    Advance;
    if (Dep <= 0) and (Pos(';', T) > 0) then Break;
    if (Dep <= 0) and (LowerCase(T) = 'begin') then Break;
  end;
end;

{ ── Apply a collected doc block to the declaration that follows ── }
procedure TParser.ApplyDoc(const XML: string);
var
  E   : TEntity;
  Decl: string;
  K   : TEntityKind;
  N, Sig: string;
begin
  SkipBlanks;
  if AtEnd then Exit;
  Decl := ReadDecl;
  if Decl = '' then Exit;

  if Classify(Decl, K, N, Sig) then
  begin
    FillChar(E, SizeOf(E), 0);
    E.Kind      := K;
    E.Name      := N;
    E.Signature := Sig;
    ParseDoc(XML, E.Doc);
    PushEntity(E);
  end;
end;

{ ── True when the current trimmed line is a module-level anchor ── }
function IsModuleAnchor(const TLow: string): Boolean;
begin
  Result :=
    AnsiStartsText('unit ',    TLow) or
    AnsiStartsText('program ', TLow) or
    AnsiStartsText('library ', TLow) or
    (TLow = 'interface') or
    (TLow = 'begin');
end;

{ ── True when the line is a bare section keyword ── }
function IsSectionKeyword(const TLow: string; out Sec: TSection): Boolean;
begin
  if      TLow = 'type'  then begin Sec := secType;  Result := True; end
  else if TLow = 'const' then begin Sec := secConst; Result := True; end
  else if TLow = 'var'   then begin Sec := secVar;   Result := True; end
  else begin Sec := secNone; Result := False; end;
end;

{ ── Main parse loop ── }
procedure TParser.Execute;
var
  T, TLow, XML: string;
  Sec         : TSection;
begin
  while not AtEnd do
  begin
    T   := CurLine;
    TLow := LowerCase(T);

    { ────── Module keyword ────── }
    if GModuleName = '' then
    begin
      if AnsiStartsText('unit ', TLow) then
      begin
        GModuleName := Trim(StringReplace(Copy(T, 6, MaxInt), ';', '', [rfReplaceAll]));
        GModuleType := 'unit';    Advance; Continue;
      end;
      if AnsiStartsText('program ', TLow) then
      begin
        GModuleName := Trim(StringReplace(Copy(T, 9, MaxInt), ';', '', [rfReplaceAll]));
        GModuleType := 'program'; Advance; Continue;
      end;
      if AnsiStartsText('library ', TLow) then
      begin
        GModuleName := Trim(StringReplace(Copy(T, 9, MaxInt), ';', '', [rfReplaceAll]));
        GModuleType := 'library'; Advance; Continue;
      end;
    end;

    { ────── End of source ────── }
    if TLow = 'end.' then Break;

    { ────── Structural markers ────── }
    if TLow = 'interface' then
    begin
      FSection := secNone; Advance; Continue;
    end;
    if TLow = 'implementation' then
    begin
      FSection := secNone; Advance; Continue;
    end;

    { ────── Section keywords (bare line) ────── }
    if IsSectionKeyword(TLow, Sec) then
    begin
      FSection := Sec; Advance; Continue;
    end;

    { ────── Uses clause ────── }
    if (TLow = 'uses') or AnsiStartsText('uses ', TLow) then
    begin
      while not AtEnd and (Pos(';', CurRaw) = 0) do Advance;
      if not AtEnd then Advance;
      Continue;
    end;

    { ────── Triple-slash doc comment ────── }
    if IsTripleSlash(CurRaw) then
    begin
      XML := ReadTripleSlash;
      SkipBlanks;
      if AtEnd then Break;
      TLow := LowerCase(CurLine);

      if IsModuleAnchor(TLow) and not FModDocDone then
      begin
        ParseDoc(XML, GModuleDoc);
        FModDocDone := True;
        Continue;
      end;

      { Doc before a section keyword: update section, then apply to next decl }
      if IsSectionKeyword(TLow, Sec) then
      begin
        FSection := Sec;
        Advance;          { consume the keyword }
        SkipBlanks;
        if AtEnd then Break;
        ApplyDoc(XML);
        Continue;
      end;

      ApplyDoc(XML);
      Continue;
    end;

    { ────── Block doc comment  (** ... *) ────── }
    if IsBlockDocOpen(CurRaw) then
    begin
      XML := ReadBlockDoc;
      SkipBlanks;
      if AtEnd then Break;
      TLow := LowerCase(CurLine);

      if IsModuleAnchor(TLow) and not FModDocDone then
      begin
        ParseDoc(XML, GModuleDoc);
        FModDocDone := True;
        Continue;
      end;

      if IsSectionKeyword(TLow, Sec) then
      begin
        FSection := Sec;
        Advance;
        SkipBlanks;
        if AtEnd then Break;
        ApplyDoc(XML);
        Continue;
      end;

      ApplyDoc(XML);
      Continue;
    end;

    { ────── Undocumented routine: skip its header ────── }
    if AnsiStartsText('procedure ',   TLow) or
       AnsiStartsText('function ',    TLow) or
       AnsiStartsText('constructor ', TLow) or
       AnsiStartsText('destructor ',  TLow) then
    begin
      SkipRoutineHeader;
      Continue;
    end;

    Advance;
  end;
end;

{ ==============================================================
  AsciiDoctor output
  ============================================================== }

type
  TEntityKindSet = set of TEntityKind;

procedure WriteAdoc(Output: TStringList);

  { Append a line (or blank line when S is omitted) }
  procedure W(const S: string = '');
  begin
    Output.Add(S);
  end;

  { Emit an AsciiDoc table header row followed by a blank separator }
  procedure TableHeader(const Col1, Col2: string);
  begin
    W('[cols="1m,3", options="header"]');
    W('|===');
    W('| ' + Col1 + ' | ' + Col2);
    W('');               { blank line required between header and body }
  end;

  { Render a TDocBlock.  HL is the AsciiDoc heading prefix for sub-sections
    e.g. '=== ' for second-level or '==== ' for third-level. }
  procedure EmitDoc(const Doc: TDocBlock; const HL: string);
  var I: Integer;
  begin
    if Doc.Summary <> '' then begin W(Doc.Summary); W; end;

    if Doc.Deprecated <> '' then
    begin
      W('[WARNING]'); W('====');
      W('*Deprecated:* ' + Doc.Deprecated);
      W('===='); W;
    end;

    if Doc.Remarks <> '' then begin W(Doc.Remarks); W; end;

    if Doc.Note <> '' then
    begin
      W('[NOTE]'); W('====');
      W(Doc.Note);
      W('===='); W;
    end;

    if Length(Doc.Params) > 0 then
    begin
      W(HL + 'Parameters'); W;
      TableHeader('Name', 'Description');
      for I := 0 to High(Doc.Params) do
        W('| ' + Doc.Params[I].Name + ' | ' + Doc.Params[I].Text);
      W('|==='); W;
    end;

    if Doc.Returns <> '' then
    begin
      W(HL + 'Returns'); W;
      W(Doc.Returns); W;
    end;

    if Length(Doc.Raises) > 0 then
    begin
      W(HL + 'Exceptions'); W;
      TableHeader('Exception', 'Condition');
      for I := 0 to High(Doc.Raises) do
        W('| ' + Doc.Raises[I].Name + ' | ' + Doc.Raises[I].Text);
      W('|==='); W;
    end;

    if Doc.Example <> '' then
    begin
      W('.Example');
      W('[source,pascal]');
      W('----');
      W(Doc.Example);
      W('----'); W;
    end;

    if Doc.SeeAlso <> '' then begin W('*See also:* `' + Doc.SeeAlso + '`'); W; end;
    if Doc.Since   <> '' then begin W('*Since:* '     + Doc.Since);          W; end;
    if Doc.Author  <> '' then begin W('*Author:* '    + Doc.Author);         W; end;
  end;

  { Emit one section (== Title) for all entities whose kind is in Kinds }
  procedure EmitSection(const Title: string; Kinds: TEntityKindSet);
  var
    I  : Integer;
    E  : TEntity;
    Any: Boolean;
  begin
    { Skip entirely if there are no entities of this kind }
    Any := False;
    for I := 0 to GEntityCount - 1 do
      if GEntities[I].Kind in Kinds then begin Any := True; Break; end;
    if not Any then Exit;

    W('== ' + Title); W;

    for I := 0 to GEntityCount - 1 do
    begin
      E := GEntities[I];
      if not (E.Kind in Kinds) then Continue;

      W('=== ' + E.Name); W;

      if E.Signature <> '' then
      begin
        W('.Declaration');
        W('[source,pascal]');
        W('----');
        W(E.Signature);
        W('----'); W;
      end;

      if E.Doc.HasDoc then
        EmitDoc(E.Doc, '==== ')
      else
      begin
        W('_No documentation available._'); W;
      end;
    end;
  end;

var
  Cap: string;
begin
  { Capitalise the first letter of the module type }
  Cap := GModuleType;
  if Cap <> '' then Cap[1] := Upcase(Cap[1]);
  if GModuleName = '' then GModuleName := 'Unknown';

  { ── Document header ── }
  W('= ' + Cap + ' ' + GModuleName);
  W(':doctype: article');
  W(':toc: left');
  W(':toclevels: 3');
  W(':sectnums:');
  W(':source-highlighter: highlight.js');
  W(':icons: font');
  W;

  { ── Overview (module-level doc) ── }
  if GModuleDoc.HasDoc then
  begin
    W('== Overview'); W;
    EmitDoc(GModuleDoc, '=== ');
  end;

  { ── Declaration sections ── }
  EmitSection('Types',      [ekType]);
  EmitSection('Constants',  [ekConst]);
  EmitSection('Variables',  [ekVar]);
  EmitSection('Routines',   [ekProcedure, ekFunction, ekConstructor, ekDestructor]);
  EmitSection('Properties', [ekProperty]);
end;

{ ==============================================================
  Main
  ============================================================== }

var
  InFile, OutFile: string;
  Lines, Output  : TStringList;
  Parser         : TParser;
  I              : Integer;

begin
  { ── Help / usage ── }
  if ParamCount < 1 then
  begin
    WriteLn(ErrOutput, PROG_NAME + ' v' + PROG_VERSION);
    WriteLn(ErrOutput, '');
    WriteLn(ErrOutput, 'Usage:');
    WriteLn(ErrOutput, '  ', ExtractFileName(ParamStr(0)), ' <source.pas> [output.adoc]');
    WriteLn(ErrOutput, '');
    WriteLn(ErrOutput, 'Extracts XML documentation comments from a Free Pascal source file');
    WriteLn(ErrOutput, 'and produces an AsciiDoctor (.adoc) document.');
    WriteLn(ErrOutput, '');
    WriteLn(ErrOutput, 'When output.adoc is omitted the result is written to stdout.');
    Halt(1);
  end;

  InFile := ParamStr(1);
  if not FileExists(InFile) then
  begin
    WriteLn(ErrOutput, 'Error: file not found: ', InFile);
    Halt(1);
  end;

  Lines  := TStringList.Create;
  Output := TStringList.Create;
  try
    Lines.LoadFromFile(InFile);

    Parser := TParser.Create(Lines);
    try
      Parser.Execute;
    finally
      Parser.Free;
    end;

    WriteAdoc(Output);

    if ParamCount >= 2 then
    begin
      OutFile := ParamStr(2);
      Output.SaveToFile(OutFile);
      WriteLn('Written: ', OutFile);
    end
    else
    begin
      for I := 0 to Output.Count - 1 do
        WriteLn(Output[I]);
    end;

  finally
    Lines.Free;
    Output.Free;
  end;
end.
